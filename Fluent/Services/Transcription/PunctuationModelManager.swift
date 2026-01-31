import Foundation
import OnnxRuntimeBindings
import SentencepieceTokenizer

/// State machine for punctuation model lifecycle
/// Model is downloaded at runtime during onboarding
enum PunctuationModelState: Equatable {
    case notDownloaded          // Model not present on disk
    case downloading(progress: Double)  // Currently downloading
    case retrying(attempt: Int, maxAttempts: Int)  // Retrying after failure
    case downloaded             // Downloaded but not loaded into memory
    case loading                // Loading into memory
    case ready                  // Loaded and ready for inference
    case error(String)          // Download or load failed

    static func == (lhs: PunctuationModelState, rhs: PunctuationModelState) -> Bool {
        switch (lhs, rhs) {
        case (.notDownloaded, .notDownloaded),
             (.downloaded, .downloaded),
             (.loading, .loading),
             (.ready, .ready):
            return true
        case (.downloading(let p1), .downloading(let p2)):
            return p1 == p2
        case (.retrying(let a1, let m1), .retrying(let a2, let m2)):
            return a1 == a2 && m1 == m2
        case (.error(let e1), .error(let e2)):
            return e1 == e2
        default:
            return false
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        if case .retrying = self { return true }
        return false
    }

    var isDownloaded: Bool {
        switch self {
        case .downloaded, .loading, .ready:
            return true
        default:
            return false
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

/// Manages the punctuation/capitalization ONNX model lifecycle
/// Model: 1-800-BAD-CODE/punctuation_fullstop_truecase_english
/// Downloaded at runtime during onboarding (~200 MB)
@MainActor
class PunctuationModelManager: ObservableObject {
    static let shared = PunctuationModelManager()

    @Published private(set) var state: PunctuationModelState = .notDownloaded
    @Published private(set) var downloadProgress: Double = 0

    // ONNX Runtime session and tokenizer
    private var ortEnv: ORTEnv?
    private var ortSession: ORTSession?
    private var tokenizer: SentencepieceTokenizer?

    // Download task for cancellation
    private var downloadTask: Task<Void, Error>?

    // Model configuration
    private let maxLength = 256
    private let postLabels = ["<NULL>", "<ACRONYM>", ".", ",", "?"]

    // Model file names
    private let onnxModelName = "punct_cap_seg_en"
    private let vocabModelName = "spe_32k_lc_en"

    // Download URL - Hugging Face (original model source)
    private let modelDownloadURL = "https://huggingface.co/1-800-BAD-CODE/punctuation_fullstop_truecase_english/resolve/main/punct_cap_seg_en.onnx"

    // Retry configuration (matches ModelManager)
    private let maxRetryAttempts = 3
    private let initialRetryDelay: TimeInterval = 2.0

    private init() {
        checkModelExists()
    }

    // MARK: - File Paths

    /// Application Support directory for punctuation model
    private var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Fluent/PunctuationModel", isDirectory: true)
    }

    /// Path to downloaded ONNX model
    private var onnxModelPath: URL {
        modelsDirectory.appendingPathComponent("\(onnxModelName).onnx")
    }

    /// Path to bundled vocabulary/tokenizer model (stays in bundle - only 576 KB)
    private var vocabPath: String? {
        Bundle.main.path(forResource: vocabModelName, ofType: "model")
    }

    /// Check if model file exists on disk
    private var modelExistsOnDisk: Bool {
        FileManager.default.fileExists(atPath: onnxModelPath.path)
    }

    /// Check if tokenizer is available in bundle
    private var tokenizerExistsInBundle: Bool {
        vocabPath != nil
    }

    // MARK: - State Check

    private func checkModelExists() {
        if modelExistsOnDisk {
            state = .downloaded
        } else {
            state = .notDownloaded
        }
    }

    // MARK: - Download Model

    /// Download the punctuation model from GitHub Releases
    func downloadModel() async throws {
        guard !state.isDownloading && !state.isReady else { return }

        // Wrap download in a Task so we can cancel it
        downloadTask = Task {
            try await performDownloadWithRetry()
        }

        do {
            try await downloadTask?.value
        } catch is CancellationError {
            // User cancelled - don't throw, just reset state
            return
        } catch {
            throw error
        }
    }

    private func performDownloadWithRetry() async throws {
        var lastError: Error?

        // Create models directory
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        for attempt in 1...maxRetryAttempts {
            // Check for cancellation before each attempt
            try Task.checkCancellation()

            // Only reset progress to 0 on first attempt
            if attempt == 1 {
                state = .downloading(progress: 0)
                downloadProgress = 0
            } else {
                // On retry, show retrying state but preserve last progress
                state = .retrying(attempt: attempt, maxAttempts: maxRetryAttempts)
            }

            do {
                try await downloadModelFile()

                // Check cancellation after download completes
                try Task.checkCancellation()

                state = .downloaded
                downloadProgress = 1.0
                return // Success - exit retry loop

            } catch is CancellationError {
                // Clean up partial download
                try? FileManager.default.removeItem(at: onnxModelPath)
                throw CancellationError()
            } catch {
                lastError = error

                // Don't retry on last attempt
                if attempt < maxRetryAttempts {
                    // Exponential backoff: 2s, 4s, 8s...
                    let delay = initialRetryDelay * pow(2.0, Double(attempt - 1))
                    state = .retrying(attempt: attempt + 1, maxAttempts: maxRetryAttempts)

                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        // All retries exhausted
        state = .error(lastError?.localizedDescription ?? "Download failed after \(maxRetryAttempts) attempts")
        throw NSError(domain: "PunctuationModel", code: -1, userInfo: [NSLocalizedDescriptionKey: lastError?.localizedDescription ?? "Download failed"])
    }

    private func downloadModelFile() async throws {
        guard let url = URL(string: modelDownloadURL) else {
            throw NSError(domain: "PunctuationModel", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid download URL"])
        }

        // Use URLSession with delegate for progress tracking
        let (tempURL, response) = try await URLSession.shared.download(from: url, delegate: DownloadProgressDelegate { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadProgress = progress
                self.state = .downloading(progress: progress)
            }
        })

        // Verify response
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "PunctuationModel", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Download failed with status \(statusCode)"])
        }

        // Move downloaded file to final location
        try? FileManager.default.removeItem(at: onnxModelPath) // Remove any existing file
        try FileManager.default.moveItem(at: tempURL, to: onnxModelPath)
    }

    /// Cancel an in-progress download
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .notDownloaded
        downloadProgress = 0
        // Clean up any partial download
        try? FileManager.default.removeItem(at: onnxModelPath)
    }

    // MARK: - Load Model

    func loadModel() async throws {
        guard ortSession == nil else {
            state = .ready
            return
        }

        guard state.isDownloaded else {
            let error = NSError(domain: "PunctuationModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model not downloaded"])
            state = .error(error.localizedDescription)
            throw error
        }

        guard tokenizerExistsInBundle else {
            let error = NSError(domain: "PunctuationModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Tokenizer not found in bundle"])
            state = .error(error.localizedDescription)
            throw error
        }

        state = .loading

        do {
            guard let vocabModelPath = vocabPath else {
                throw NSError(domain: "PunctuationModel", code: -2, userInfo: [NSLocalizedDescriptionKey: "Could not resolve vocab path"])
            }

            // Initialize ONNX Runtime environment (keep reference to prevent deallocation)
            ortEnv = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)

            // Initialize ONNX Runtime session
            ortSession = try ORTSession(
                env: ortEnv!,
                modelPath: onnxModelPath.path,
                sessionOptions: nil
            )

            // Initialize SentencePiece tokenizer
            tokenizer = try SentencepieceTokenizer(modelPath: vocabModelPath)

            state = .ready
        } catch {
            state = .error("Failed to load model: \(error.localizedDescription)")
            throw error
        }
    }

    func unloadModel() {
        ortSession = nil
        ortEnv = nil
        tokenizer = nil
        if state == .ready || state == .loading {
            // Check if model still exists on disk
            if modelExistsOnDisk {
                state = .downloaded
            } else {
                state = .notDownloaded
            }
        }
    }

    /// Delete the downloaded model file
    func deleteModel() {
        unloadModel()
        try? FileManager.default.removeItem(at: onnxModelPath)
        state = .notDownloaded
        downloadProgress = 0
    }

    // MARK: - Inference

    /// Run punctuation inference on text
    /// - Parameter text: Input text (can be any case, will be lowercased internally)
    /// - Returns: Formatted text with punctuation and proper capitalization
    func infer(text: String) async throws -> String {
        guard state.isReady, let session = ortSession, let tokenizer = tokenizer else {
            throw NSError(domain: "PunctuationModel", code: -4, userInfo: [NSLocalizedDescriptionKey: "Model not ready"])
        }

        // Lowercase input as model expects
        let lowercasedText = text.lowercased()

        // Tokenize - encode returns [Int] token IDs
        let tokens = try tokenizer.encode(lowercasedText)
        guard !tokens.isEmpty else { return text }

        // Handle texts longer than maxLength by chunking
        if tokens.count > maxLength {
            return try await inferLongText(text: lowercasedText, session: session, tokenizer: tokenizer)
        }

        return try await runInference(tokens: tokens, originalWords: extractWords(from: lowercasedText), session: session)
    }

    private func extractWords(from text: String) -> [String] {
        text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    private func inferLongText(text: String, session: ORTSession, tokenizer: SentencepieceTokenizer) async throws -> String {
        // Split into sentences or chunks and process separately
        let words = extractWords(from: text)
        var results: [String] = []
        var currentChunk: [String] = []
        var currentTokenCount = 0

        for word in words {
            let wordTokens = try tokenizer.encode(word)
            if currentTokenCount + wordTokens.count > maxLength - 10 { // Leave buffer
                // Process current chunk
                let chunkText = currentChunk.joined(separator: " ")
                let chunkTokens = try tokenizer.encode(chunkText)
                let formatted = try await runInference(tokens: chunkTokens, originalWords: currentChunk, session: session)
                results.append(formatted)

                currentChunk = [word]
                currentTokenCount = wordTokens.count
            } else {
                currentChunk.append(word)
                currentTokenCount += wordTokens.count
            }
        }

        // Process remaining chunk
        if !currentChunk.isEmpty {
            let chunkText = currentChunk.joined(separator: " ")
            let chunkTokens = try tokenizer.encode(chunkText)
            let formatted = try await runInference(tokens: chunkTokens, originalWords: currentChunk, session: session)
            results.append(formatted)
        }

        return results.joined(separator: " ")
    }

    private func runInference(tokens: [Int], originalWords: [String], session: ORTSession) async throws -> String {
        // Create input data as Int64 array
        let inputData = tokens.map { Int64($0) }
        let inputShape: [NSNumber] = [1, NSNumber(value: tokens.count)]

        // Create input tensor for token IDs
        let inputTensor = try ORTValue(
            tensorData: NSMutableData(data: Data(bytes: inputData, count: tokens.count * MemoryLayout<Int64>.size)),
            elementType: ORTTensorElementDataType.int64,
            shape: inputShape
        )

        // Create attention mask tensor (all 1s)
        let attentionData = [Int64](repeating: 1, count: tokens.count)
        let attentionTensor = try ORTValue(
            tensorData: NSMutableData(data: Data(bytes: attentionData, count: tokens.count * MemoryLayout<Int64>.size)),
            elementType: ORTTensorElementDataType.int64,
            shape: inputShape
        )

        // Run inference
        let outputs = try session.run(
            withInputs: ["input_ids": inputTensor, "attention_mask": attentionTensor],
            outputNames: Set(["logits_pre", "logits_post", "logits_case"]),
            runOptions: nil
        )

        // Decode outputs
        guard let postLogits = outputs["logits_post"],
              let caseLogits = outputs["logits_case"] else {
            throw NSError(domain: "PunctuationModel", code: -5, userInfo: [NSLocalizedDescriptionKey: "Missing model outputs"])
        }

        // Extract predictions
        let postPreds = try extractPredictions(from: postLogits, numClasses: postLabels.count)
        let casePreds = try extractPredictions(from: caseLogits, numClasses: 2) // 0=lower, 1=upper

        // Reconstruct text with punctuation and capitalization
        return reconstructText(words: originalWords, postPreds: postPreds, casePreds: casePreds)
    }

    private func extractPredictions(from tensor: ORTValue, numClasses: Int) throws -> [Int] {
        let data = try tensor.tensorData() as Data
        let shape = try tensor.tensorTypeAndShapeInfo().shape
        let seqLen = shape[1].intValue

        // Logits shape: [batch, seq_len, num_classes]
        var predictions: [Int] = []

        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let floatPtr = ptr.bindMemory(to: Float.self)

            for i in 0..<seqLen {
                var maxIdx = 0
                var maxVal = floatPtr[i * numClasses]

                for c in 1..<numClasses {
                    let val = floatPtr[i * numClasses + c]
                    if val > maxVal {
                        maxVal = val
                        maxIdx = c
                    }
                }
                predictions.append(maxIdx)
            }
        }

        return predictions
    }

    private func reconstructText(words: [String], postPreds: [Int], casePreds: [Int]) -> String {
        guard !words.isEmpty else { return "" }

        var result: [String] = []
        var predIndex = 0
        var capitalizeNext = true // Start of text is always capitalized

        for word in words {
            guard predIndex < postPreds.count && predIndex < casePreds.count else { break }

            var processedWord = word

            // Apply capitalization
            if capitalizeNext || casePreds[predIndex] == 1 {
                processedWord = processedWord.capitalized
                capitalizeNext = false
            }

            // Handle ACRONYM - capitalize all letters with periods
            let postLabel = postPreds[predIndex]
            if postLabel == 1 { // ACRONYM
                processedWord = processedWord.uppercased().map { String($0) }.joined(separator: ".")
                if !processedWord.hasSuffix(".") {
                    processedWord += "."
                }
            }

            result.append(processedWord)

            // Apply punctuation after word
            if postLabel >= 2 && postLabel < postLabels.count {
                let punct = postLabels[postLabel]
                if let last = result.last {
                    result[result.count - 1] = last + punct
                }

                // Capitalize after sentence-ending punctuation
                if punct == "." || punct == "?" {
                    capitalizeNext = true
                }
            }

            predIndex += 1
        }

        return result.joined(separator: " ")
    }

    // MARK: - Model Info

    var modelSizeDescription: String {
        "~200 MB"
    }

    var isModelDownloaded: Bool {
        state.isDownloaded
    }
}

// MARK: - Download Progress Delegate

/// URLSession delegate to track download progress
private class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: (Double) -> Void

    init(progressHandler: @escaping (Double) -> Void) {
        self.progressHandler = progressHandler
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled by the async download call
    }
}
