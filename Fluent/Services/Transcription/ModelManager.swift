import Foundation
import WhisperKit

enum ModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case retrying(attempt: Int, maxAttempts: Int)
    case downloaded
    case loading
    case ready
    case error(String)

    static func == (lhs: ModelState, rhs: ModelState) -> Bool {
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
}

enum ModelError: LocalizedError {
    case downloadFailed(String)
    case loadFailed(String)
    case modelNotDownloaded
    case invalidModelFile
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let reason):
            return "Model download failed: \(reason)"
        case .loadFailed(let reason):
            return "Failed to load model: \(reason)"
        case .modelNotDownloaded:
            return "Model not downloaded. Please download the model first."
        case .invalidModelFile:
            return "Invalid or corrupted model file."
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        }
    }
}

@MainActor
class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published private(set) var state: ModelState = .notDownloaded
    @Published private(set) var downloadProgress: Double = 0

    private var whisperKit: WhisperKit?
    private var downloadTask: Task<Void, Error>?

    // WhisperKit model configuration
    private let modelName = "small"  // Options: tiny, base, small, medium, large
    private let modelRepo = "argmaxinc/whisperkit-coreml"

    // Retry configuration
    private let maxRetryAttempts = 3
    private let initialRetryDelay: TimeInterval = 2.0

    private init() {
        checkModelExists()
    }

    // MARK: - Model Directory

    private var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Fluent/WhisperKitModels", isDirectory: true)
    }

    private var modelPath: URL {
        modelsDirectory.appendingPathComponent("openai_whisper-\(modelName)")
    }

    // MARK: - State Check

    private func checkModelExists() {
        // Check if WhisperKit model folder exists with expected files
        let modelFolder = modelPath
        if FileManager.default.fileExists(atPath: modelFolder.path) {
            // Check for key model files (MelSpectrogram and AudioEncoder are required)
            let melPath = modelFolder.appendingPathComponent("MelSpectrogram.mlmodelc")
            let encoderPath = modelFolder.appendingPathComponent("AudioEncoder.mlmodelc")

            if FileManager.default.fileExists(atPath: melPath.path) &&
               FileManager.default.fileExists(atPath: encoderPath.path) {
                state = .downloaded
            } else {
                // Incomplete model - remove and re-download
                try? FileManager.default.removeItem(at: modelFolder)
                state = .notDownloaded
            }
        } else {
            state = .notDownloaded
        }
    }

    // MARK: - Download and Load

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
                let modelFolder = try await WhisperKit.download(
                    variant: modelName,
                    from: modelRepo,
                    progressCallback: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.downloadProgress = progress.fractionCompleted
                            self.state = .downloading(progress: progress.fractionCompleted)
                        }
                    }
                )

                // Check cancellation after download completes
                try Task.checkCancellation()

                // Move to our app's model directory if needed
                let destinationPath = modelPath
                if modelFolder.path != destinationPath.path {
                    try? FileManager.default.removeItem(at: destinationPath)
                    try FileManager.default.createDirectory(
                        at: modelsDirectory,
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(
                        at: modelFolder,
                        to: destinationPath
                    )
                }

                state = .downloaded
                downloadProgress = 1.0
                return // Success - exit retry loop

            } catch is CancellationError {
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
        throw ModelError.downloadFailed(lastError?.localizedDescription ?? "Download failed")
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .notDownloaded
        downloadProgress = 0
    }

    // MARK: - Load Model

    func loadModel() async throws {
        // Already loaded - return immediately
        if whisperKit != nil {
            state = .ready
            return
        }

        // Must be downloaded first
        guard state == .downloaded else {
            throw ModelError.modelNotDownloaded
        }

        state = .loading

        do {
            // Initialize WhisperKit with our downloaded model
            whisperKit = try await WhisperKit(
                modelFolder: modelPath.path,
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                ),
                verbose: false,
                prewarm: true
            )

            state = .ready
        } catch {
            state = .error("Failed to load model: \(error.localizedDescription)")
            throw ModelError.loadFailed(error.localizedDescription)
        }
    }

    func unloadModel() {
        whisperKit = nil
        if state == .ready {
            state = .downloaded
        }
    }

    // MARK: - Transcription

    func transcribe(samples: [Float], language: String?) async throws -> String {
        guard state.isReady, let whisperKit else {
            throw ModelError.modelNotDownloaded
        }

        do {
            let options = DecodingOptions(
                task: .transcribe,
                language: language,
                temperature: 0.0,
                temperatureFallbackCount: 0,
                sampleLength: 224,  // WhisperKit's maximum allowed value (internal array limit)
                usePrefillPrompt: false,
                usePrefillCache: false,
                clipTimestamps: [0],  // Ensure processing starts from beginning
                suppressBlank: true,
                supressTokens: nil,
                compressionRatioThreshold: 2.4,
                logProbThreshold: -1.0,
                firstTokenLogProbThreshold: nil,
                noSpeechThreshold: 0.6
            )

            let results = try await whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: options
            )

            // Combine all segment texts
            let fullText = results.compactMap { $0.text }.joined(separator: " ")
            return fullText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        } catch {
            throw ModelError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Streaming transcription - transcribes audio chunks and provides partial results
    func transcribeStreaming(
        audioStream: AsyncStream<[Float]>,
        onPartialResult: @escaping (String) -> Void
    ) async throws -> String {
        guard state.isReady, let whisperKit else {
            throw ModelError.modelNotDownloaded
        }

        var accumulatedSamples: [Float] = []
        var lastTranscription = ""
        let chunkDuration: Int = 16000 // 1 second of audio at 16kHz

        for await samples in audioStream {
            accumulatedSamples.append(contentsOf: samples)

            // Transcribe every ~1 second of accumulated audio
            if accumulatedSamples.count >= chunkDuration {
                do {
                    let options = DecodingOptions(
                        task: .transcribe,
                        language: nil,  // Auto-detect for streaming
                        temperature: 0.0,
                        suppressBlank: true,
                        noSpeechThreshold: 0.6
                    )

                    let results = try await whisperKit.transcribe(
                        audioArray: accumulatedSamples,
                        decodeOptions: options
                    )

                    let text = results.compactMap { $0.text }.joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if !text.isEmpty && text != lastTranscription {
                        lastTranscription = text
                        await MainActor.run {
                            onPartialResult(text)
                        }
                    }
                } catch {
                    // Continue streaming even if one chunk fails
                }
            }
        }

        // Final transcription with all accumulated audio
        if !accumulatedSamples.isEmpty {
            do {
                let options = DecodingOptions(
                    task: .transcribe,
                    language: nil,
                    temperature: 0.0,
                    suppressBlank: true,
                    noSpeechThreshold: 0.6
                )

                let results = try await whisperKit.transcribe(
                    audioArray: accumulatedSamples,
                    decodeOptions: options
                )

                lastTranscription = results.compactMap { $0.text }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                // Return what we have
            }
        }

        return lastTranscription
    }

    // MARK: - Delete Model

    func deleteModel() {
        unloadModel()
        try? FileManager.default.removeItem(at: modelPath)
        state = .notDownloaded
    }

    // MARK: - Model Info

    var modelSizeDescription: String {
        "~150 MB"  // Core ML optimized model
    }

    var isModelDownloaded: Bool {
        if case .downloaded = state { return true }
        if case .ready = state { return true }
        return false
    }
}
