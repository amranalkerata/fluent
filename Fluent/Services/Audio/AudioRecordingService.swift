import AVFoundation
import Combine
import AppKit

enum RecordingError: LocalizedError {
    case microphonePermissionDenied
    case audioEngineStartFailed
    case fileCreationFailed
    case noInputDevice
    case recordingTooShort
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access was denied. Please enable it in System Settings > Privacy & Security > Microphone."
        case .audioEngineStartFailed:
            return "Failed to start audio recording. Please check your audio input device."
        case .fileCreationFailed:
            return "Failed to create audio file for recording."
        case .noInputDevice:
            return "No audio input device found. Please connect a microphone."
        case .recordingTooShort:
            return "Recording too short. Please hold for at least one second."
        case .noSpeechDetected:
            return "Couldn't detect anything. Please try again."
        }
    }
}

@MainActor
class AudioRecordingService: ObservableObject {
    // Duration limits
    static let minimumRecordingDuration: TimeInterval = 1.0  // 1 second
    static let maximumRecordingDuration: TimeInterval = 300  // 5 minutes

    @Published var isRecording = false
    @Published var audioLevels: [Float] = []
    @Published var recordingDuration: TimeInterval = 0
    @Published var currentLevel: Float = 0

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?

    private var levelPublisher = PassthroughSubject<Float, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var recordingStartTime: Date?
    private var durationTimer: Timer?

    private let maxLevelSamples = 100

    // Track audio levels during recording for silence detection
    private var allLevelSamples: [Float] = []
    private static let silenceThreshold: Float = 0.05

    init() {
        setupLevelSmoothing()
    }

    private func setupLevelSmoothing() {
        levelPublisher
            .collect(.byTime(DispatchQueue.main, .milliseconds(50)))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] levels in
                guard let self = self, !levels.isEmpty else { return }
                let average = levels.reduce(0, +) / Float(levels.count)
                self.currentLevel = average
                self.audioLevels.append(average)
                if self.audioLevels.count > self.maxLevelSamples {
                    self.audioLevels.removeFirst()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Recording Control

    func startRecording() async throws {
        // Check microphone permission
        let permission = await requestMicrophonePermission()
        guard permission else {
            throw RecordingError.microphonePermissionDenied
        }

        // Create audio engine
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Check for input device
        guard inputNode.inputFormat(forBus: 0).channelCount > 0 else {
            throw RecordingError.noInputDevice
        }

        let format = inputNode.outputFormat(forBus: 0)

        // Create recording directory if needed
        let recordingDirectory = getRecordingDirectory()
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)

        // Create recording file
        let fileName = "recording_\(Int(Date().timeIntervalSince1970)).m4a"
        recordingURL = recordingDirectory.appendingPathComponent(fileName)

        guard let url = recordingURL else {
            throw RecordingError.fileCreationFailed
        }

        // Audio settings for M4A (AAC)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128000
        ]

        do {
            audioFile = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            throw RecordingError.fileCreationFailed
        }

        // Install tap for recording and level monitoring
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Write to file
            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                // Silently handle buffer write errors
            }

            // Calculate RMS level for waveform
            let level = self.calculateRMSLevel(buffer: buffer)
            self.levelPublisher.send(level)

            // Collect levels for silence detection
            self.allLevelSamples.append(level)
        }

        // Start engine
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw RecordingError.audioEngineStartFailed
        }

        self.audioEngine = engine
        self.isRecording = true
        self.recordingStartTime = Date()
        self.audioLevels.removeAll()
        self.allLevelSamples.removeAll()
        startDurationTimer()
    }

    func stopRecording() async -> URL? {
        guard isRecording else { return nil }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil

        isRecording = false
        durationTimer?.invalidate()
        durationTimer = nil

        return recordingURL
    }

    // MARK: - Microphone Permission

    private func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    static func checkMicrophonePermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Silence Detection

    /// Returns the average audio level from the recording session
    func getAverageLevel() -> Float {
        guard !allLevelSamples.isEmpty else { return 0 }
        return allLevelSamples.reduce(0, +) / Float(allLevelSamples.count)
    }

    /// Checks if the recording has sufficient audio activity (not just silence)
    func hasSpeechActivity() -> Bool {
        return getAverageLevel() >= Self.silenceThreshold
    }

    // MARK: - Audio Level Calculation

    private func calculateRMSLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frameLength {
            sum += channelData[i] * channelData[i]
        }

        let rms = sqrt(sum / Float(frameLength))

        // Convert to normalized value (0 to 1)
        // Using a reference level of -60dB as silence
        let db = 20 * log10(max(rms, 0.0001))
        let normalized = (db + 60) / 60
        return min(max(normalized, 0), 1)
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let startTime = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)

                // Auto-stop at maximum duration
                if self.recordingDuration >= Self.maximumRecordingDuration {
                    NotificationCenter.default.post(name: .performToggleRecording, object: nil)
                }
            }
        }
    }

    // MARK: - File Management

    private func getRecordingDirectory() -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("Fluent", isDirectory: true)
    }

    func deleteRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func getRecordingFileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.size] as? Int64
    }
}
