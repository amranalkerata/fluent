import Foundation
import whisper

enum ModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
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
        return false
    }
}

enum ModelError: LocalizedError {
    case downloadFailed(String)
    case loadFailed(String)
    case modelNotDownloaded
    case invalidModelFile

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
        }
    }
}

@MainActor
class ModelManager: NSObject, ObservableObject {
    static let shared = ModelManager()

    @Published private(set) var state: ModelState = .notDownloaded
    @Published private(set) var downloadProgress: Double = 0

    private var whisperContext: OpaquePointer?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private var downloadContinuation: CheckedContinuation<Void, Error>?
    private var isLoading = false  // Guard against concurrent/re-entrant loads

    private let modelFileName = "ggml-base.bin"
    private let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!
    private let expectedModelSize: Int64 = 142_000_000 // ~142MB
    private let minimumValidModelSize: Int64 = 140_000_000 // ~140MB minimum for valid base model

    private override init() {
        super.init()
        checkModelExists()
    }

    // MARK: - Model Directory

    private var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Fluent/Models", isDirectory: true)
    }

    private var modelPath: URL {
        modelsDirectory.appendingPathComponent(modelFileName)
    }

    // MARK: - State Check

    private func checkModelExists() {
        if FileManager.default.fileExists(atPath: modelPath.path) {
            // Verify file size is reasonable - use stricter threshold to catch incomplete downloads
            if let attrs = try? FileManager.default.attributesOfItem(atPath: modelPath.path),
               let size = attrs[.size] as? Int64,
               size > minimumValidModelSize { // ~140MB minimum for valid base model
                state = .downloaded
            } else {
                // File exists but is invalid/incomplete - remove it
                try? FileManager.default.removeItem(at: modelPath)
                state = .notDownloaded
            }
        } else {
            state = .notDownloaded
        }
    }

    // MARK: - Download

    func downloadModel() async throws {
        guard !state.isDownloading && !state.isReady else { return }

        // Create models directory
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        state = .downloading(progress: 0)
        downloadProgress = 0

        // Create optimized download session
        // Using ephemeral config avoids disk caching overhead during download
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600 // 10 minutes max for full download
        config.httpShouldUsePipelining = true

        // Using nil for delegateQueue lets callbacks run on URLSession's background queue
        // The Task { @MainActor in } pattern in delegate methods properly hops to main actor
        downloadSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.downloadContinuation = continuation
            self.downloadTask = self.downloadSession?.downloadTask(with: self.modelURL)
            self.downloadTask?.resume()
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        downloadContinuation?.resume(throwing: CancellationError())
        downloadContinuation = nil
        state = .notDownloaded
        downloadProgress = 0
    }

    // MARK: - Load Model

    func loadModel() async throws {
        // Already loaded - return immediately
        if whisperContext != nil {
            state = .ready
            return
        }

        // Must be downloaded first
        guard state == .downloaded else {
            throw ModelError.modelNotDownloaded
        }

        // Prevent concurrent loads
        guard !isLoading else { return }
        isLoading = true

        state = .loading

        // Load model on background thread
        let path = modelPath.path

        do {
            let context = try await Task.detached(priority: .userInitiated) {
                var params = whisper_context_default_params()
                params.use_gpu = true // Enable Metal acceleration
                guard let ctx = whisper_init_from_file_with_params(path, params) else {
                    throw ModelError.loadFailed("whisper_init_from_file returned nil")
                }
                return ctx
            }.value

            whisperContext = context
            state = .ready
            isLoading = false
        } catch {
            state = .error("Failed to load model")
            isLoading = false
            throw error
        }
    }

    func unloadModel() {
        if let ctx = whisperContext {
            whisper_free(ctx)
            whisperContext = nil
        }
        if state == .ready {
            state = .downloaded
        }
    }

    // MARK: - Transcription

    func transcribe(samples: [Float], language: String?) async throws -> String {
        guard state.isReady, let ctx = whisperContext else {
            throw ModelError.modelNotDownloaded
        }

        // Configure whisper parameters - optimized for speed
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.temperature = 0.0 // More deterministic output

        // Speed optimizations
        params.n_threads = Int32(min(ProcessInfo.processInfo.activeProcessorCount, 8))  // Use available cores (max 8)
        params.audio_ctx = 0  // Auto audio context (let Whisper optimize)
        params.suppress_blank = true  // Skip blank segments faster

        // Set language if specified (avoids auto-detection overhead)
        var languagePtr: UnsafePointer<CChar>?
        if let lang = language, !lang.isEmpty {
            languagePtr = (lang as NSString).utf8String
            params.language = languagePtr
        } else {
            params.language = nil // Auto-detect
        }

        // Run transcription on background thread
        let result: String = try await Task.detached(priority: .userInitiated) {
            let status = samples.withUnsafeBufferPointer { ptr in
                whisper_full(ctx, params, ptr.baseAddress, Int32(samples.count))
            }

            guard status == 0 else {
                throw ModelError.loadFailed("Transcription failed with status \(status)")
            }

            // Collect segments
            let nSegments = whisper_full_n_segments(ctx)
            var fullText = ""

            for i in 0..<nSegments {
                if let text = whisper_full_get_segment_text(ctx, i) {
                    fullText += String(cString: text)
                }
            }

            return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value

        return result
    }

    // MARK: - Delete Model

    func deleteModel() {
        unloadModel()
        try? FileManager.default.removeItem(at: modelPath)
        state = .notDownloaded
    }

    // MARK: - Model Info

    var modelSizeDescription: String {
        "~142 MB"
    }

    var isModelDownloaded: Bool {
        if case .downloaded = state { return true }
        if case .ready = state { return true }
        return false
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // CRITICAL: URLSession deletes the temp file immediately after this callback returns.
        // We MUST move the file synchronously here - not inside a Task or async block.
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let destinationDir = appSupport.appendingPathComponent("Fluent/Models", isDirectory: true)
        let destinationPath = destinationDir.appendingPathComponent("ggml-base.bin")

        do {
            // Ensure directory exists
            try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)

            // Remove existing file if present
            if fileManager.fileExists(atPath: destinationPath.path) {
                try fileManager.removeItem(at: destinationPath)
            }

            // Move file synchronously (before URLSession deletes it)
            try fileManager.moveItem(at: location, to: destinationPath)

            // Now dispatch UI/state updates to MainActor
            Task { @MainActor in
                self.state = .downloaded
                self.downloadProgress = 1.0
                self.downloadContinuation?.resume()
                self.downloadContinuation = nil
            }
        } catch {
            Task { @MainActor in
                self.state = .error(error.localizedDescription)
                self.downloadContinuation?.resume(throwing: ModelError.downloadFailed(error.localizedDescription))
                self.downloadContinuation = nil
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedModelSize
            let progress = Double(totalBytesWritten) / Double(expected)
            downloadProgress = min(progress, 1.0)
            state = .downloading(progress: downloadProgress)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            if let error = error {
                if (error as NSError).code == NSURLErrorCancelled {
                    // Cancelled - already handled
                    return
                }
                state = .error(error.localizedDescription)
                downloadContinuation?.resume(throwing: ModelError.downloadFailed(error.localizedDescription))
                downloadContinuation = nil
            }
        }
    }
}
