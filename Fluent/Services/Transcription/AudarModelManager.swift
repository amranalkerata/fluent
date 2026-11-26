import Foundation
import Combine
import CryptoKit

/// One file of the Audar model, pinned to a revision of AudarAI's official repository.
/// The license only allows getting the model from AudarAI's official location, so it is
/// downloaded on the user's Mac and never bundled with the app.
struct AudarModelFile: Sendable {
    let name: String
    let size: Int64
    let sha256: String

    var url: URL {
        URL(string: "\(AudarModelManager.repositoryURL)/resolve/\(AudarModelManager.revision)/\(name)")!
    }
}

enum AudarModelError: LocalizedError {
    case licenseNotAccepted
    case insufficientDiskSpace(needed: Int64)
    case badResponse(Int)
    case sizeMismatch(String)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .licenseNotAccepted:
            return "Accept the AudarAI Community License before downloading the Audar model."
        case .insufficientDiskSpace(let needed):
            let size = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            return "Not enough disk space. The Audar model needs \(size) free."
        case .badResponse(let code):
            return "The download server answered with HTTP \(code)."
        case .sizeMismatch(let name):
            return "\(name) has the wrong size. The download was incomplete."
        case .checksumMismatch(let name):
            return "\(name) failed its integrity check. The file was corrupted."
        }
    }
}

/// Downloads, verifies, loads and runs the offline Audar-ASR-V1-Turbo Arabic model.
/// Same state machine as `ModelManager` (Whisper).
@MainActor
final class AudarModelManager: ObservableObject {
    static let shared = AudarModelManager()

    // MARK: - Model source and license

    static let repositoryURL = "https://huggingface.co/audarai/Audar-ASR-V1-Turbo"
    static let revision = "371428bea487c7aec82b27dc21f8d4324002e98e"

    static let modelFile = AudarModelFile(
        name: "Audar-ASR-V1-Turbo-Q8_0.gguf",
        size: 2_165_034_848,
        sha256: "0a91ab40f6a30db06c4186e2f621f504f4625ba6058e639cc09f1cbefded10d2"
    )
    static let projectorFile = AudarModelFile(
        name: "mmproj-Audar-ASR-V1-Turbo.gguf",
        size: 641_773_856,
        sha256: "190459e806938175711779847eb62ea609cd78b8d2ec06fb96a94d69ab37a9be"
    )
    static let files = [modelFile, projectorFile]
    static let totalBytes: Int64 = files.reduce(0) { $0 + $1.size }

    static let licenseName = "AudarAI Community License"
    static let licenseURL = URL(string: "https://www.audarai.com/license/audarai-community-license-v1.0/")!
    static let licenseSummary = "Free for individuals and small teams: under 50 staff, under $2M annual revenue, under 100k monthly users, and under $250k total revenue from products using the model. Above that, an enterprise license from AudarAI is required."
    static let attribution = "Audar-ASR-V1-Turbo by AudarAI, used under the AudarAI Community License v1.0."

    var modelSizeDescription: String { "~2.8 GB" }

    // MARK: - State

    @Published private(set) var state: ModelState = .notDownloaded
    @Published private(set) var downloadProgress: Double = 0

    private var engine: AudarEngine?
    private var downloadTask: Task<Void, Error>?
    private var loadTask: Task<Void, Error>?
    private var cancellables = Set<AnyCancellable>()

    private let maxRetryAttempts = 3
    private let initialRetryDelay: TimeInterval = 2.0

    private init() {
        removeLeftoverDownloads()
        state = isModelDownloaded ? .downloaded : .notDownloaded

        // Turning the engine off or revoking the license frees its memory; turning it back on
        // loads it again. The startup load itself is started by AppState, after Whisper.
        SettingsService.shared.$settings
            .map { [$0.audarEnabled, $0.audarLicenseAccepted] }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.loadIfConfigured() }
            .store(in: &cancellables)
    }

    // MARK: - Files

    nonisolated static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Fluent/AudarModels", isDirectory: true)
    }

    nonisolated static func installedURL(for file: AudarModelFile) -> URL {
        modelsDirectory.appendingPathComponent(file.name)
    }

    nonisolated static func temporaryURL(for file: AudarModelFile) -> URL {
        modelsDirectory.appendingPathComponent(file.name + ".download")
    }

    /// Files only get their final name after passing the size and SHA-256 check,
    /// so a file under its final name with the right size is a verified file.
    nonisolated static func isInstalled(_ file: AudarModelFile) -> Bool {
        let path = installedURL(for: file).path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value == file.size
    }

    var isModelDownloaded: Bool {
        Self.files.allSatisfy(Self.isInstalled)
    }

    private func removeLeftoverDownloads() {
        for file in Self.files {
            try? FileManager.default.removeItem(at: Self.temporaryURL(for: file))
        }
    }

    // MARK: - Usage

    private var settings: AppSettings { SettingsService.shared.settings }

    /// Downloaded, switched on and licensed (whether or not it is loaded yet).
    var isConfigured: Bool {
        isModelDownloaded && settings.audarEnabled && settings.audarLicenseAccepted
    }

    /// Ready to transcribe right now.
    var isUsable: Bool {
        engine != nil && state.isReady && settings.audarEnabled && settings.audarLicenseAccepted
    }

    /// Loads the engine in the background when it is configured, frees it when it is not.
    /// Never blocks: callers keep using Whisper until the engine is ready.
    func loadIfConfigured() {
        if isConfigured {
            if state == .downloaded {
                Task { try? await loadModel() }
            }
        } else {
            unloadModel()
        }
    }

    // MARK: - Download

    func downloadModel() async throws {
        guard settings.audarLicenseAccepted else { throw AudarModelError.licenseNotAccepted }
        guard !state.isDownloading, downloadTask == nil else { return }
        if isModelDownloaded {
            if case .error = state { state = .downloaded }
            loadIfConfigured()
            return
        }

        let task = Task { try await performDownload() }
        downloadTask = task
        defer { if downloadTask == task { downloadTask = nil } }

        do {
            try await task.value
        } catch is CancellationError {
            return
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        removeLeftoverDownloads()
        state = isModelDownloaded ? .downloaded : .notDownloaded
        downloadProgress = 0
    }

    private func performDownload() async throws {
        do {
            let directory = Self.modelsDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            state = .downloading(progress: 0)
            downloadProgress = 0

            // Files already verified on disk count as done.
            var completedBytes: Int64 = 0
            var pending: [AudarModelFile] = []
            for file in Self.files {
                if Self.isInstalled(file) {
                    completedBytes += file.size
                } else {
                    pending.append(file)
                }
            }
            try Self.checkDiskSpace(needed: pending.reduce(0) { $0 + $1.size }, in: directory)
            updateProgress(bytes: completedBytes)

            for file in pending {
                try await downloadWithRetry(file, completedBytes: completedBytes)
                completedBytes += file.size
                updateProgress(bytes: completedBytes)
            }

            state = .downloaded
            downloadProgress = 1
            loadIfConfigured()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A cancel can surface as another error (e.g. its temp file removed mid-check).
            if Task.isCancelled { throw CancellationError() }
            state = .error(error.localizedDescription)
            throw error
        }
    }

    private func downloadWithRetry(_ file: AudarModelFile, completedBytes: Int64) async throws {
        let temporaryURL = Self.temporaryURL(for: file)
        var resumeData: Data?
        var lastError: Error?

        for attempt in 1...maxRetryAttempts {
            try Task.checkCancellation()
            if attempt > 1 {
                state = .retrying(attempt: attempt, maxAttempts: maxRetryAttempts)
            }

            do {
                try await FileDownload.run(from: file.url, to: temporaryURL, resumeData: resumeData) { [weak self] written in
                    Task { @MainActor [weak self] in
                        self?.updateProgress(bytes: completedBytes + min(written, file.size))
                    }
                }
                try await Self.verifyAndInstall(temporaryURL, as: file)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as FileDownload.Failure {
                lastError = failure.underlying
                resumeData = failure.resumeData
            } catch {
                // Bad HTTP status or a failed integrity check: start this file over.
                lastError = error
                resumeData = nil
            }

            if attempt < maxRetryAttempts {
                // Exponential backoff: 2s, 4s, ...
                let delay = initialRetryDelay * pow(2.0, Double(attempt - 1))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        try? FileManager.default.removeItem(at: temporaryURL)
        throw ModelError.downloadFailed(lastError?.localizedDescription ?? "Download failed after \(maxRetryAttempts) attempts")
    }

    private func updateProgress(bytes: Int64) {
        let progress = min(1, Double(bytes) / Double(Self.totalBytes))
        downloadProgress = progress
        if state.isDownloading {
            state = .downloading(progress: progress)
        }
    }

    nonisolated private static func checkDiskSpace(needed: Int64, in directory: URL) throws {
        guard needed > 0 else { return }
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        // Keep 500 MB of headroom on top of the model itself.
        let required = needed + 500_000_000
        if available < required {
            throw AudarModelError.insufficientDiskSpace(needed: required)
        }
    }

    // MARK: - Verification

    /// Checks size and SHA-256 of `temporaryURL`, then moves it to its final name.
    /// A file that fails the check is deleted.
    nonisolated static func verifyAndInstall(_ temporaryURL: URL, as file: AudarModelFile) async throws {
        do {
            try await verifyOffMainThread(temporaryURL, file: file)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        let destination = installedURL(for: file)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }

    /// Re-checks the installed files (size + SHA-256). Corrupt files are deleted and the
    /// model goes back to "not downloaded". Takes a few seconds for 2.8 GB.
    func verifyInstalledFiles() async throws {
        do {
            for file in Self.files {
                let url = Self.installedURL(for: file)
                do {
                    try await Self.verifyOffMainThread(url, file: file)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            unloadModel()
            state = .notDownloaded
            throw error
        }
    }

    nonisolated private static func verifyOffMainThread(_ url: URL, file: AudarModelFile) async throws {
        let flag = CancellationFlag()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try verify(fileAt: url, file: file, cancellation: flag)
            }.value
        } onCancel: {
            flag.cancel()
        }
    }

    /// Streams the file through SHA-256 in 8 MB chunks (never loads it whole).
    nonisolated static func verify(fileAt url: URL, file: AudarModelFile, cancellation: CancellationFlag? = nil) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == file.size else {
            throw AudarModelError.sizeMismatch(file.name)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if cancellation?.isCancelled == true { throw CancellationError() }
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: 8 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else {
            throw AudarModelError.checksumMismatch(file.name)
        }
    }

    // MARK: - Load

    func loadModel() async throws {
        if engine != nil {
            state = .ready
            return
        }
        if let loadTask {
            try await loadTask.value
            return
        }
        guard isModelDownloaded else { throw ModelError.modelNotDownloaded }

        state = .loading
        let modelPath = Self.installedURL(for: Self.modelFile).path
        let projectorPath = Self.installedURL(for: Self.projectorFile).path

        let task = Task { @MainActor in
            do {
                // ~7 s the first time (one-time Metal shader compile), then ~1-2 s.
                let loaded = try await Task.detached(priority: .utility) {
                    try AudarEngine(modelPath: modelPath, mmprojPath: projectorPath)
                }.value
                // Deleted or switched off while loading: drop the engine.
                guard state == .loading else { return }
                guard isConfigured else {
                    state = .downloaded
                    return
                }
                engine = loaded
                state = .ready
                // Warm-up pass so the user's first dictation doesn't pay for Metal
                // pipeline setup and first-run allocations (~1 s). A soft 220 Hz tone
                // stays above the engine's silence gate; the output is discarded.
                Task.detached(priority: .utility) {
                    let tone = (0..<16_000).map { Float(0.02 * sin(2 * Double.pi * 220 * Double($0) / 16_000)) }
                    _ = try? loaded.transcribe(samples: tone, language: "ar")
                }
            } catch {
                state = .error("Failed to load model: \(error.localizedDescription)")
                throw ModelError.loadFailed(error.localizedDescription)
            }
        }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    /// Load again after a load error (the files are still on disk).
    func retryLoad() {
        guard isModelDownloaded else { return }
        state = .downloaded
        Task { try? await loadModel() }
    }

    func unloadModel() {
        engine = nil
        if state == .ready {
            state = .downloaded
        }
    }

    // MARK: - Transcription

    /// 16 kHz mono samples. `language` "ar" works best; nil lets the model identify the
    /// language (still Arabic-biased). Runs the blocking engine off the main actor.
    func transcribe(samples: [Float], language: String?) async throws -> String {
        guard state.isReady, let engine else {
            throw ModelError.modelNotDownloaded
        }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try engine.transcribe(samples: samples, language: language)
            }.value
        } catch {
            throw ModelError.transcriptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Delete

    func deleteModel() {
        if downloadTask != nil { cancelDownload() }
        unloadModel()
        try? FileManager.default.removeItem(at: Self.modelsDirectory)
        state = .notDownloaded
        downloadProgress = 0
    }

    #if DEBUG
    /// Developer shortcut: installs model files that are already on disk (e.g. a Hugging Face
    /// cache) through the same verify-then-move path as a download. Never used in release builds.
    func installFromLocalDirectory(_ directory: URL) async throws {
        try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
        for file in Self.files where !Self.isInstalled(file) {
            let source = directory.appendingPathComponent(file.name).resolvingSymlinksInPath()
            let temporaryURL = Self.temporaryURL(for: file)
            try? FileManager.default.removeItem(at: temporaryURL)
            try FileManager.default.copyItem(at: source, to: temporaryURL)
            try await Self.verifyAndInstall(temporaryURL, as: file)
        }
        if case .notDownloaded = state { state = .downloaded }
    }
    #endif
}

// MARK: - Helpers

/// Thread-safe cancel flag for work running in a detached task.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// One URLSession download with byte progress, resume data on failure, and cancellation.
/// The finished file is moved to `destination` (replacing anything there).
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Failure: Error {
        let underlying: Error
        let resumeData: Data?
    }

    /// Progress is reported every 4 MB to keep main-actor updates cheap.
    private static let progressStep: Int64 = 4 << 20

    private let destination: URL
    private let onProgress: @Sendable (Int64) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var finishError: Error?
    private var lastReportedBytes: Int64 = 0

    private init(destination: URL, onProgress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    static func run(
        from url: URL,
        to destination: URL,
        resumeData: Data?,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let download = FileDownload(destination: destination, onProgress: onProgress)
        try await download.start(url: url, resumeData: resumeData)
    }

    private func start(url: URL, resumeData: Data?) async throws {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let task = resumeData.map { session.downloadTask(withResumeData: $0) }
                    ?? session.downloadTask(with: url)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let shouldReport = totalBytesWritten - lastReportedBytes >= Self.progressStep
        if shouldReport { lastReportedBytes = totalBytesWritten }
        lock.unlock()
        if shouldReport { onProgress(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this method returns, so move it now.
        let error: Error?
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            error = AudarModelError.badResponse(response.statusCode)
        } else {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                error = nil
            } catch let moveError {
                error = moveError
            }
        }
        lock.lock()
        finishError = error
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let wasCancelled = cancelled
        let finishError = self.finishError
        lock.unlock()
        guard let continuation else { return }

        if let error {
            if wasCancelled || (error as? URLError)?.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                continuation.resume(throwing: Failure(underlying: error, resumeData: resumeData))
            }
        } else if let finishError {
            continuation.resume(throwing: finishError)
        } else {
            onProgress(task.countOfBytesReceived)
            continuation.resume()
        }
    }
}
