import Foundation
import llama

enum AudarEngineError: LocalizedError {
    case modelLoadFailed(String)
    case contextInitFailed
    case projectorLoadFailed(String)
    case audioNotSupported
    case unexpectedSampleRate(Int32)
    case audioInputFailed
    case tokenizeFailed(Int32)
    case promptEvalFailed(Int32)
    case decodeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path): return "Could not load the Audar model at \(path)"
        case .contextInitFailed: return "Could not create the Audar inference context"
        case .projectorLoadFailed(let path): return "Could not load the Audar audio projector at \(path)"
        case .audioNotSupported: return "The Audar projector has no audio encoder"
        case .unexpectedSampleRate(let rate): return "The Audar audio encoder expects \(rate) Hz audio, not 16000 Hz"
        case .audioInputFailed: return "Could not hand the audio to the Audar encoder"
        case .tokenizeFailed(let code): return "Could not build the Audar prompt (code \(code))"
        case .promptEvalFailed(let code): return "Audar failed while reading the audio (code \(code))"
        case .decodeFailed(let code): return "Audar failed while writing the transcript (code \(code))"
        }
    }
}

/// Offline speech-to-text with Audar-ASR-V1-Turbo (Qwen3-ASR architecture: audio encoder +
/// Qwen3 decoder) on the vendored llama.cpp runtime, Metal for both the decoder and the projector.
///
/// The prompt matches the model's chat template:
///
///     <|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{AUDIO}<|im_end|>\n<|im_start|>assistant\n{prefill}
///
/// where mtmd expands `{AUDIO}` to `<|audio_start|>` + audio embeddings + `<|audio_end|>`.
/// The model answers `language <Name><asr_text><transcript>`. When the language is known the
/// prefix is prefilled (as the vendor's own package does) so the model never free-runs language
/// identification; in auto mode `language None` is the model's no-speech verdict and maps to "".
///
/// Thread-safe: every call is serialized by a lock. Load and transcribe are blocking and must
/// run off the main thread.
final class AudarEngine: @unchecked Sendable {
    static let sampleRate = 16_000
    /// Longest stretch handed to the model in one pass; longer audio is cut at quiet points.
    static let maxSegmentSeconds = 30
    static let maxNewTokens = 256

    private static let contextSize: UInt32 = 4096
    private static let batchSize: UInt32 = 2048

    private let lock = NSLock()
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let projector: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private let tokenBatch: OpaquePointer

    init(modelPath: String, mmprojPath: String) throws {
        assert(!Thread.isMainThread, "AudarEngine loads a 2 GB model; call it off the main thread")
        LlamaRuntime.ensureInitialized()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1 // every layer on Metal
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw AudarEngineError.modelLoadFailed(modelPath)
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = Self.contextSize
        contextParams.n_batch = Self.batchSize
        contextParams.n_seq_max = 1
        contextParams.no_perf = true
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw AudarEngineError.contextInitFailed
        }

        var projectorParams = mtmd_context_params_default()
        projectorParams.use_gpu = true
        projectorParams.print_timings = false
        guard let projector = mtmd_init_from_file(mmprojPath, model, projectorParams) else {
            llama_free(context)
            llama_model_free(model)
            throw AudarEngineError.projectorLoadFailed(mmprojPath)
        }

        let failure: AudarEngineError?
        if !mtmd_support_audio(projector) {
            failure = .audioNotSupported
        } else if mtmd_get_audio_sample_rate(projector) != Int32(Self.sampleRate) {
            failure = .unexpectedSampleRate(mtmd_get_audio_sample_rate(projector))
        } else {
            failure = nil
        }
        if let failure {
            mtmd_free(projector)
            llama_free(context)
            llama_model_free(model)
            throw failure
        }

        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.projector = projector
        self.sampler = llama_sampler_init_greedy()
        self.tokenBatch = llama_batch_ext_init(context)
    }

    deinit {
        llama_batch_ext_free(tokenBatch)
        llama_sampler_free(sampler)
        mtmd_free(projector)
        llama_free(context)
        llama_model_free(model)
    }

    /// Transcribes 16 kHz mono Float32 samples.
    /// - Parameter language: "ar", "en", or nil for automatic language detection.
    func transcribe(samples: [Float], language: String?) throws -> String {
        assert(!Thread.isMainThread, "AudarEngine.transcribe blocks; call it off the main thread")
        guard !samples.isEmpty else { return "" }

        lock.lock()
        defer { lock.unlock() }

        let plan = PromptPlan(language: language)
        var pieces: [String] = []
        for range in Self.segmentRanges(for: samples) {
            guard var segment = Self.levelled(samples[range]) else { continue }
            // The encoder needs a minimum amount of audio; pad very short clips with silence.
            let minimumSamples = Self.sampleRate / 2
            if segment.count < minimumSamples {
                segment.append(contentsOf: repeatElement(0, count: minimumSamples - segment.count))
            }
            let text = try transcribeSegment(segment, plan: plan)
            if !text.isEmpty { pieces.append(text) }
        }
        return pieces.joined(separator: " ")
    }

    // MARK: - Input level

    /// Below this peak (about -60 dBFS) the audio is treated as silence and never reaches the model.
    static let silencePeak: Float = 0.001
    /// Quieter audio is raised to this peak (-20 dBFS).
    static let quietTargetPeak: Float = 0.1

    /// Near-silent input makes the model invent text (subtitle credits such as «النهاية»), while
    /// the same noise at a normal level gets its no-speech tag. So: drop digital silence, and
    /// raise quiet audio to a normal level. Speech at normal levels passes through unchanged.
    static func levelled(_ samples: ArraySlice<Float>) -> [Float]? {
        var peak: Float = 0
        for value in samples { peak = max(peak, abs(value)) }
        guard peak >= silencePeak else { return nil }
        guard peak < quietTargetPeak else { return Array(samples) }
        let gain = quietTargetPeak / peak
        return samples.map { $0 * gain }
    }

    // MARK: - One pass

    private func transcribeSegment(_ samples: [Float], plan: PromptPlan) throws -> String {
        // Fresh state for every pass: no KV cache or sampler history carries over.
        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_reset(sampler)

        guard let bitmap = samples.withUnsafeBufferPointer({
            mtmd_bitmap_init_from_audio($0.count, $0.baseAddress)
        }) else {
            throw AudarEngineError.audioInputFailed
        }
        defer { mtmd_bitmap_free(bitmap) }

        guard let chunks = mtmd_input_chunks_init() else { throw AudarEngineError.audioInputFailed }
        defer { mtmd_input_chunks_free(chunks) }

        let marker = String(cString: mtmd_default_marker())
        let prompt = "<|im_start|>system\n\(plan.systemPrompt)<|im_end|>\n"
            + "<|im_start|>user\n\(marker)<|im_end|>\n"
            + "<|im_start|>assistant\n\(plan.prefill ?? "")"

        let tokenizeResult: Int32 = prompt.withCString { cPrompt in
            var text = mtmd_input_text(text: cPrompt, text_len: strlen(cPrompt), add_special: true, parse_special: true)
            var bitmaps: [OpaquePointer?] = [bitmap]
            return bitmaps.withUnsafeMutableBufferPointer { buffer in
                mtmd_tokenize(projector, chunks, &text, buffer.baseAddress, 1)
            }
        }
        guard tokenizeResult == 0 else { throw AudarEngineError.tokenizeFailed(tokenizeResult) }

        var position: llama_pos = 0
        let evalResult = mtmd_helper_eval_chunks(
            projector, context, chunks,
            0,                        // n_past
            0,                        // seq_id
            Int32(Self.batchSize),
            true,                     // logits for the last prompt token
            &position
        )
        guard evalResult == 0 else { throw AudarEngineError.promptEvalFailed(evalResult) }

        let tokens = try generate(startingAt: position)
        return Self.cleanOutput(detokenize(tokens), prefilled: plan.prefill != nil)
    }

    /// Greedy decoding until end of generation, the token budget, the context end, or a loop.
    private func generate(startingAt start: llama_pos) throws -> [llama_token] {
        var tokens: [llama_token] = []
        var position = start
        let contextLimit = llama_pos(llama_n_ctx(context))

        while tokens.count < Self.maxNewTokens, position < contextLimit {
            let token = llama_sampler_sample(sampler, context, -1) // also accepts the token
            if llama_vocab_is_eog(vocab, token) { break }
            tokens.append(token)

            if let keep = RepetitionGuard.loopCutoff(tokens) {
                tokens.removeSubrange(keep...)
                break
            }

            llama_batch_ext_clear(tokenBatch)
            let index = llama_batch_ext_add_token(tokenBatch, 0, token)
            guard index >= 0 else { throw AudarEngineError.decodeFailed(index) }
            var tokenPosition = position
            llama_batch_ext_set_pos(tokenBatch, index, &tokenPosition)
            llama_batch_ext_set_output_logits(tokenBatch, index, true)
            let result = llama_process(context, LLAMA_PROCESS_TYPE_DECODE, tokenBatch)
            guard result == 0 else { throw AudarEngineError.decodeFailed(result) }
            position += 1
        }
        return tokens
    }

    /// Tokens to UTF-8 text in one go (a single Arabic letter can span two tokens).
    /// Special tokens such as `<asr_text>` are rendered so the prefix can be parsed.
    private func detokenize(_ tokens: [llama_token]) -> String {
        guard !tokens.isEmpty else { return "" }
        var buffer = [CChar](repeating: 0, count: tokens.count * 16 + 64)
        var length = llama_detokenize(vocab, tokens, Int32(tokens.count), &buffer, Int32(buffer.count), false, true)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length) + 1)
            length = llama_detokenize(vocab, tokens, Int32(tokens.count), &buffer, Int32(buffer.count), false, true)
        }
        guard length > 0 else { return "" }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Prompt and output

    struct PromptPlan {
        let systemPrompt: String
        /// Text placed right after the assistant header; nil lets the model identify the language.
        let prefill: String?

        init(language: String?) {
            let code = language?.lowercased().split(separator: "-").first.map(String.init)
            switch code {
            case "ar":
                systemPrompt = "فرّغ الكلام العربي التالي."
                prefill = "language Arabic<asr_text>"
            case "en":
                systemPrompt = "Transcribe the following English speech."
                prefill = "language English<asr_text>"
            default:
                systemPrompt = "فرّغ الكلام العربي التالي."
                prefill = nil
            }
        }
    }

    private static let languagePrefix = try! NSRegularExpression(
        pattern: #"^\s*language\s+([A-Za-z]+)\s*(?:<asr_text>)?"#
    )

    private static let nonSpeechTag = try! NSRegularExpression(pattern: #"@@@\S*"#)

    /// Strips the `language <Name><asr_text>` prefix; `language None` (no speech) becomes "".
    static func cleanOutput(_ raw: String, prefilled: Bool) -> String {
        var text = raw
        let range = NSRange(text.startIndex..., in: text)
        if let match = languagePrefix.firstMatch(in: text, range: range),
           let whole = Range(match.range, in: text),
           let name = Range(match.range(at: 1), in: text) {
            if text[name].lowercased() == "none" { return "" }
            text.removeSubrange(whole)
        } else if !prefilled, text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("language") {
            // An unfinished prefix (e.g. cut by the token budget) carries no transcript.
            return ""
        }
        text = text.replacingOccurrences(of: "<asr_text>", with: " ")
        // Non-speech tags: the model answers noise or silence with «@@@ضوضاء» / «@@@فراغ»,
        // and sometimes opens a transcript with «###».
        text = nonSpeechTag.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " "
        )
        text = text.replacingOccurrences(of: "###", with: " ")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Long audio

    /// Splits audio longer than `maxSegmentSeconds` at the quietest 200 ms in the last
    /// five seconds before each boundary.
    static func segmentRanges(for samples: [Float]) -> [Range<Int>] {
        let maxLength = maxSegmentSeconds * sampleRate
        guard samples.count > maxLength else { return [0..<samples.count] }

        let searchSpan = 5 * sampleRate
        let window = sampleRate / 5   // 200 ms
        let hop = sampleRate / 100    // 10 ms
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxLength {
            let searchEnd = start + maxLength
            let searchStart = searchEnd - searchSpan
            var bestCut = searchEnd
            var bestEnergy = Double.infinity
            var windowStart = searchStart
            while windowStart + window <= searchEnd {
                var energy = 0.0
                for i in windowStart..<(windowStart + window) {
                    let value = Double(samples[i])
                    energy += value * value
                }
                if energy < bestEnergy {
                    bestEnergy = energy
                    bestCut = windowStart + window / 2
                }
                windowStart += hop
            }
            ranges.append(start..<bestCut)
            start = bestCut
        }
        ranges.append(start..<samples.count)
        return ranges
    }
}

/// Detects decoding loops such as one token repeated ("يااااا…") or a short phrase cycling.
enum RepetitionGuard {
    /// Same token more than this many times in a row is a loop.
    static let maxSameTokenRun = 8
    /// A pattern of 2…6 tokens repeated this many times in a row is a loop.
    static let maxPatternRepeats = 8

    /// Returns the index to truncate `tokens` at (keeping one copy of the repeated unit),
    /// or nil when the tail is not looping.
    static func loopCutoff(_ tokens: [llama_token]) -> Int? {
        let count = tokens.count
        guard let last = tokens.last else { return nil }

        var run = 0
        for token in tokens.reversed() {
            guard token == last else { break }
            run += 1
        }
        if run > maxSameTokenRun { return count - run + 1 }

        for period in 2...6 {
            let span = period * maxPatternRepeats
            guard count >= span else { break }
            let tail = tokens[(count - span)...]
            let base = tail.startIndex
            let isPeriodic = (period..<span).allSatisfy { tail[base + $0] == tail[base + $0 - period] }
            if isPeriodic { return count - span + period }
        }
        return nil
    }
}
