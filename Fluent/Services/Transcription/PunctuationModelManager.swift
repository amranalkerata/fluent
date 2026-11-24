import Foundation
import CoreML
import NaturalLanguage
import SentencepieceTokenizer

/// Lifecycle of the bundled punctuation model.
/// The model ships inside the app bundle, so there is no download step.
enum PunctuationModelState: Equatable {
    case notLoaded              // Bundled, not loaded into memory yet
    case loading                // Loading into memory
    case ready                  // Loaded and ready for inference
    case error(String)          // Load failed

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

/// Manages the bundled punctuation / true-casing / sentence-boundary model.
/// Model: 1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase (Apache-2.0),
/// converted to Core ML (see scripts/convert_punctuation_model.py). 47 languages including Arabic.
@MainActor
class PunctuationModelManager: ObservableObject {
    static let shared = PunctuationModelManager()

    @Published private(set) var state: PunctuationModelState = .notLoaded

    private var engine: PunctuationEngine?
    private var loadTask: Task<PunctuationEngine, Error>?

    private init() {}

    // MARK: - Load Model

    func loadModel() async throws {
        if engine != nil {
            state = .ready
            return
        }

        if let loadTask {
            _ = try await loadTask.value
            return
        }

        state = .loading
        let task = Task.detached(priority: .userInitiated) {
            try PunctuationEngine.loadFromBundle()
        }
        loadTask = task

        do {
            let loaded = try await task.value
            engine = loaded
            state = .ready
            loadTask = nil
        } catch {
            loadTask = nil
            state = .error("Failed to load model: \(error.localizedDescription)")
            throw error
        }
    }

    func unloadModel() {
        loadTask?.cancel()
        loadTask = nil
        engine = nil
        state = .notLoaded
    }

    // MARK: - Inference

    /// Add punctuation, casing and sentence boundaries to text.
    /// - Parameter text: Input text in any case; existing sentence punctuation is replaced.
    /// - Returns: Formatted text.
    func infer(text: String) async throws -> String {
        guard state.isReady, let engine else {
            throw PunctuationEngine.EngineError.notReady
        }
        // Tokenizing, prediction and decoding all run off the main actor.
        return try await Task.detached(priority: .userInitiated) {
            try engine.format(text)
        }.value
    }

    // MARK: - Model Info

    /// Short, read-only description for the UI.
    var modelSummary: String {
        "Built-in · 47 languages including Arabic"
    }

    var modelSizeDescription: String {
        "Built-in"
    }

    /// The model is bundled with the app, so it is always available.
    var isModelDownloaded: Bool {
        true
    }
}

// MARK: - Engine

/// Holds the Core ML model and tokenizer and does the actual work.
/// Thread-safe: all access to the model and tokenizer goes through `lock`.
final class PunctuationEngine: @unchecked Sendable {
    enum EngineError: LocalizedError {
        case notReady
        case resourceMissing(String)
        case missingOutput(String)

        var errorDescription: String? {
            switch self {
            case .notReady: return "Model not ready"
            case .resourceMissing(let name): return "\(name) not found in app bundle"
            case .missingOutput(let name): return "Model output \(name) missing"
            }
        }
    }

    // Model contract (fixed input length, raw SentencePiece ids)
    private static let maxLength = 256
    private static let maxContentTokens = maxLength - 2   // BOS + EOS
    private static let bosId: Int32 = 0
    private static let padId: Int32 = 1
    private static let eosId: Int32 = 2
    private static let unkId = 3
    private static let maxCharsPerPiece = 16

    private static let nullLabel = 0
    private static let acronymLabel = 1
    private static let postLabels = ["<NULL>", "<ACRONYM>", ".", ",", "?", "？", "，", "。", "、", "・", "।", "؟", "،", ";", "።", "፣", "፧"]
    private static let spanishQuestionPreLabel = 1

    /// Sentence punctuation stripped from word ends before inference ("!" is kept).
    private static let trailingPunctuation: Set<Character> = [".", ",", "?", ";", ":", "…", "؟", "،", "؛"]

    private static let wordMarker: Character = "\u{2581}"   // "▁"

    private let model: MLModel
    private let tokenizer: SentencepieceTokenizer
    private let lock = NSLock()

    private init(model: MLModel, tokenizer: SentencepieceTokenizer) {
        self.model = model
        self.tokenizer = tokenizer
    }

    static func loadFromBundle() throws -> PunctuationEngine {
        guard let modelURL = Bundle.main.url(forResource: "PunctCapSeg", withExtension: "mlmodelc") else {
            throw EngineError.resourceMissing("PunctCapSeg.mlmodelc")
        }
        guard let tokenizerPath = Bundle.main.path(forResource: "xlmr_punct_sp", ofType: "model") else {
            throw EngineError.resourceMissing("xlmr_punct_sp.model")
        }

        let configuration = MLModelConfiguration()
        // The model computes in FP32; the Neural Engine is FP16-only and flips the cap/seg heads.
        // CPU only: ~50 ms per call from the first prediction. With the GPU the first prediction
        // of every launch spends ~16 s specializing shaders (then ~15 ms per call).
        configuration.computeUnits = .cpuOnly

        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        // This model uses raw SentencePiece ids (bos 0, pad 1, eos 2, unk 3).
        let tokenizer = try SentencepieceTokenizer(modelPath: tokenizerPath, tokenOffset: 0)
        return PunctuationEngine(model: model, tokenizer: tokenizer)
    }

    // MARK: - Formatting

    private struct Word {
        /// Lower-cased input word (what the model sees).
        let text: String
        /// Text emitted instead of rebuilding the word from pieces when `useOriginalText` is set.
        let original: String
        var tokens: [Int]
        /// Emit `original` as-is instead of rebuilding it from pieces
        /// (unknown token, truncated word, or a Latin word inside Arabic text).
        var useOriginalText: Bool
    }

    private struct Options {
        let isSpanish: Bool
        let isArabic: Bool
    }

    func format(_ text: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let stripped = Self.stripTrailingSentencePunctuation(text)
        let cleaned = stripped.lowercased()
        let originalTexts = stripped.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !originalTexts.isEmpty else { return text }

        let options = Options(
            isSpanish: Self.isSpanish(cleaned),
            isArabic: Self.isMainlyArabic(cleaned)
        )

        var words: [Word] = []
        for originalText in originalTexts {
            let wordText = originalText.lowercased()
            var tokens = try tokenizer.encode(wordText)
            var useOriginal = tokens.contains(Self.unkId)
            // In Arabic text, English words stay exactly as spoken: no re-casing, no acronym
            // dots ("CRM" not "C.R.M."); only punctuation after them.
            let keepLatin = options.isArabic && originalText.unicodeScalars.contains(where: Self.isLatinScalar)
            if keepLatin { useOriginal = true }
            if tokens.count > Self.maxContentTokens {
                tokens = Array(tokens.prefix(Self.maxContentTokens))
                useOriginal = true
            }
            if tokens.isEmpty {
                useOriginal = true
            }
            // Outside Arabic text, unknown/truncated words keep today's lower-cased output.
            words.append(Word(text: wordText, original: keepLatin ? originalText : wordText,
                              tokens: tokens, useOriginalText: useOriginal))
        }

        // Split on word boundaries into chunks that fit the fixed model length.
        var chunks: [[Word]] = []
        var current: [Word] = []
        var currentCount = 0
        for word in words {
            if !current.isEmpty && currentCount + word.tokens.count > Self.maxContentTokens {
                chunks.append(current)
                current = []
                currentCount = 0
            }
            current.append(word)
            currentCount += word.tokens.count
        }
        if !current.isEmpty { chunks.append(current) }

        var results: [String] = []
        for chunk in chunks {
            // A chunk that continues an unfinished sentence keeps the model's own casing for its first word.
            let continuesSentence = results.last.map { !Self.endsSentence($0) } ?? false
            let formatted = try formatChunk(chunk, options: options, capitalizeStart: !continuesSentence)
            if !formatted.isEmpty { results.append(formatted) }
        }
        let joined = results.joined(separator: " ")
        return joined.isEmpty ? text : joined
    }

    private func formatChunk(_ words: [Word], options: Options, capitalizeStart: Bool) throws -> String {
        let contentIds = words.flatMap { $0.tokens }
        let n = contentIds.count + 2

        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.maxLength)], dataType: .int32)
        let pointer = input.dataPointer.bindMemory(to: Int32.self, capacity: Self.maxLength)
        let stride = input.strides[1].intValue
        for i in 0..<Self.maxLength {
            let value: Int32
            if i == 0 {
                value = Self.bosId
            } else if i <= contentIds.count {
                value = Int32(contentIds[i - 1])
            } else if i == n - 1 {
                value = Self.eosId
            } else {
                value = Self.padId
            }
            pointer[i * stride] = value
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["input_ids": MLFeatureValue(multiArray: input)])
        let output = try model.prediction(from: provider)

        let pre = try Self.output(output, "pre_preds")
        let post = try Self.output(output, "post_preds")
        let cap = try Self.output(output, "cap_preds")
        let seg = try Self.output(output, "seg_preds")

        func value(_ array: MLMultiArray, _ i: Int) -> Int {
            array[[0, NSNumber(value: i)] as [NSNumber]].intValue
        }
        func capValue(_ i: Int, _ j: Int) -> Int {
            cap[[0, NSNumber(value: i), NSNumber(value: j)] as [NSNumber]].intValue
        }

        var sentences: [String] = []
        var currentSentence = ""
        var position = 1  // model position of the next token (0 is BOS)

        for word in words {
            let wordStart = position
            position += word.tokens.count
            let lastPosition = position - 1

            if !currentSentence.isEmpty { currentSentence += " " }

            if word.useOriginalText {
                currentSentence += word.original
                let postLabel = value(post, lastPosition)
                if let label = postLabelText(postLabel, after: word.original, options: options) {
                    currentSentence += label
                }
                if value(seg, lastPosition) == 1 && Self.endsSentence(currentSentence) {
                    sentences.append(currentSentence)
                    currentSentence = ""
                }
                continue
            }

            for (offset, tokenId) in word.tokens.enumerated() {
                let i = wordStart + offset
                let isWordEnd = i == lastPosition
                let piece = try tokenizer.idToToken(tokenId)

                let hasMarker = piece.first == Self.wordMarker
                let start = hasMarker ? 1 : 0
                let body = hasMarker ? String(piece.dropFirst()) : piece

                // A bare "▁" piece carries no characters: ignore its labels.
                if body.isEmpty { continue }

                let preLabel = value(pre, i)
                let postLabel = value(post, i)

                if preLabel == Self.spanishQuestionPreLabel && options.isSpanish {
                    currentSentence += "¿"
                }

                let applyAcronym = postLabel == Self.acronymLabel && Self.isLatinScript(body)

                // Cap index counts characters including the leading "▁".
                for (k, scalar) in body.unicodeScalars.enumerated() {
                    let j = start + k
                    if j < Self.maxCharsPerPiece && capValue(i, j) == 1 {
                        currentSentence += String(scalar).uppercased()
                    } else {
                        currentSentence.unicodeScalars.append(scalar)
                    }
                    if applyAcronym {
                        currentSentence += "."
                    }
                }

                // Punctuation and sentence breaks only at word ends, never inside a word.
                guard isWordEnd else { continue }

                if !applyAcronym, let label = postLabelText(postLabel, after: body, options: options) {
                    currentSentence += label
                }

                // Only break where the sentence really ends (not after "," or no punctuation).
                if value(seg, i) == 1 && Self.endsSentence(currentSentence) {
                    sentences.append(currentSentence)
                    currentSentence = ""
                }
            }
        }

        if !currentSentence.isEmpty {
            sentences.append(currentSentence)
        }

        return sentences
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, sentence in
                // Arabic has no case: capitalizing would only re-case an English word as spoken.
                index == 0 && !capitalizeStart || options.isArabic ? sentence : Self.capitalizingFirstLetter(sentence)
            }
            .joined(separator: " ")
    }

    private func postLabelText(_ label: Int, after text: String, options: Options) -> String? {
        guard label != Self.nullLabel,
              label != Self.acronymLabel,
              label < Self.postLabels.count else { return nil }
        // Don't stack a label on top of existing punctuation such as "!".
        if let last = text.last, last.isPunctuation { return nil }

        let punctuation = Self.postLabels[label]
        guard options.isArabic else { return punctuation }
        switch punctuation {
        case ",": return "،"
        case "?": return "؟"
        case ";": return "؛"
        default: return punctuation
        }
    }

    private static func output(_ provider: MLFeatureProvider, _ name: String) throws -> MLMultiArray {
        guard let array = provider.featureValue(for: name)?.multiArrayValue else {
            throw EngineError.missingOutput(name)
        }
        return array
    }

    // MARK: - Text Helpers

    /// Remove sentence punctuation at the end of words (followed by whitespace or end of text).
    /// Punctuation inside tokens is kept (3.5, 10:30, URLs, emails), and so is "!".
    static func stripTrailingSentencePunctuation(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(text.count)
        var i = 0
        while i < characters.count {
            let ch = characters[i]
            if trailingPunctuation.contains(ch) {
                var j = i
                while j < characters.count && trailingPunctuation.contains(characters[j]) { j += 1 }
                if j == characters.count || characters[j].isWhitespace {
                    i = j
                    continue
                }
                result.append(contentsOf: characters[i..<j])
                i = j
                continue
            }
            result.append(ch)
            i += 1
        }
        return result
    }

    private static func isSpanish(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage == .spanish
    }

    private static func isMainlyArabic(_ text: String) -> Bool {
        var arabic = 0
        var letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if isArabicScalar(scalar) { arabic += 1 }
        }
        return letters > 0 && arabic * 2 > letters
    }

    private static func isArabicScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF,
             0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return true
        default:
            return false
        }
    }

    private static func isLatinScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF:
            return scalar.value != 0xD7 && scalar.value != 0xF7
        default:
            return false
        }
    }

    /// True when the piece has letters and all of them are Latin.
    private static func isLatinScript(_ text: String) -> Bool {
        var hasLetter = false
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            guard isLatinScalar(scalar) else { return false }
            hasLetter = true
        }
        return hasLetter
    }

    private static let sentenceEndings: Set<Character> = [".", "?", "!", "؟", "？", "。", "।", "።", "፧", "…"]

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return true }
        return sentenceEndings.contains(last)
    }

    /// Upper-case the first letter of a sentence (skipping leading punctuation such as "¿" or quotes).
    private static func capitalizingFirstLetter(_ sentence: String) -> String {
        guard let index = sentence.firstIndex(where: { !$0.isPunctuation }) else { return sentence }
        let ch = sentence[index]
        guard ch.isLetter else { return sentence }
        return sentence.replacingCharacters(in: index...index, with: ch.uppercased())
    }
}
