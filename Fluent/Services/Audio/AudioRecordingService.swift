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
            return "Failed to start audio recording."
        case .fileCreationFailed:
            return "Failed to create audio file for recording."
        case .noInputDevice:
            return "No audio input device found"
        case .recordingTooShort:
            return "Recording too short."
        case .noSpeechDetected:
            return "Couldn't detect anything."
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

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var audioFileCreated = false
    private var recordingURL: URL?

    private var levelPublisher = PassthroughSubject<Float, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var recordingStartTime: Date?
    private var durationTimer: Timer?

    private let maxLevelSamples = 100

    // Track audio levels during recording for silence detection
    private var allLevelSamples: [Float] = []
    private static let silenceThreshold: Float = 0.08
    private static let peakToAverageThreshold: Float = 1.8

    // 16 kHz mono samples of the recording as it happens (read by IncrementalTranscriber).
    private var audioBufferContinuation: AsyncStream<[Float]>.Continuation?
    private(set) var audioStream: AsyncStream<[Float]>?
    /// Used only on the tap thread while recording, then flushed once in `stopRecording()`.
    private var streamResampler: StreamingResampler?

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
                // Build the new array first and publish it once: two mutations would mean two redraws.
                var updated = self.audioLevels
                updated.append(average)
                if updated.count > self.maxLevelSamples {
                    updated.removeFirst(updated.count - self.maxLevelSamples)
                }
                self.audioLevels = updated
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

        do {
            try await startEngine(usePreferredDevice: true)
        } catch RecordingError.audioEngineStartFailed, RecordingError.noInputDevice {
            // The preferred external mic refused to start (e.g. a Bluetooth headset
            // still connecting) — fall back to the system default input.
            try await startEngine(usePreferredDevice: false)
        }
    }

    private func startEngine(usePreferredDevice: Bool) async throws {
        // Create audio engine
        let engine = AVAudioEngine()
        if usePreferredDevice {
            await AudioDeviceManager.shared.configureDevice(on: engine)
        }
        let inputNode = engine.inputNode

        // Check for input device
        guard inputNode.inputFormat(forBus: 0).channelCount > 0 else {
            throw RecordingError.noInputDevice
        }

        // Create recording directory if needed
        let recordingDirectory = getRecordingDirectory()
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)

        // Create recording file
        let fileName = "recording_\(Int(Date().timeIntervalSince1970)).m4a"
        recordingURL = recordingDirectory.appendingPathComponent(fileName)

        // Async stream of 16 kHz mono samples for transcription while recording
        audioStream = AsyncStream { continuation in
            self.audioBufferContinuation = continuation
        }
        let resampler = StreamingResampler()
        streamResampler = resampler

        // Install tap for recording and level monitoring
        // format: nil lets AVAudioEngine use the node's native hardware format,
        // which correctly reflects the actual device (AirPods @ 16kHz or built-in @ 48kHz)
        audioFileCreated = false

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Lazily create audio file on first buffer using actual hardware format
            if self.audioFile == nil && !self.audioFileCreated {
                self.audioFileCreated = true
                if let url = self.recordingURL {
                    let fmt = buffer.format
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: fmt.sampleRate,
                        AVNumberOfChannelsKey: fmt.channelCount,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                        AVEncoderBitRateKey: 128000
                    ]
                    self.audioFile = try? AVAudioFile(
                        forWriting: url,
                        settings: settings,
                        commonFormat: fmt.commonFormat,
                        interleaved: fmt.isInterleaved
                    )
                }
            }

            // Write to file
            do {
                try self.audioFile?.write(from: buffer)
            } catch {}

            // Calculate RMS level for waveform
            let level = self.calculateRMSLevel(buffer: buffer)
            self.levelPublisher.send(level)
            self.allLevelSamples.append(level)

            // Stream 16 kHz mono samples for transcription while recording
            if let samples = resampler.process(buffer), !samples.isEmpty {
                self.audioBufferContinuation?.yield(samples)
            }
        }

        // Start engine
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw RecordingError.audioEngineStartFailed
        }

        self.audioEngine = engine
        // Reset before `isRecording` flips, so the overlay never shows the last recording's time.
        self.recordingDuration = 0
        self.audioLevels.removeAll()
        self.recordingStartTime = Date()
        self.isRecording = true
        self.allLevelSamples.removeAll()
        startDurationTimer()
    }

    func stopRecording() async -> URL? {
        guard isRecording else { return nil }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // Finish the sample stream only now, so it carries every buffer the file got,
        // plus the few ms still inside the resampler.
        if let tail = streamResampler?.flush(), !tail.isEmpty {
            audioBufferContinuation?.yield(tail)
        }
        streamResampler = nil
        audioBufferContinuation?.finish()
        audioBufferContinuation = nil
        audioStream = nil
        audioFile = nil
        audioFileCreated = false

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

    /// Returns the peak audio level from the recording session
    func getPeakLevel() -> Float {
        return allLevelSamples.max() ?? 0
    }

    /// Returns the ratio of peak to average level
    /// Real speech has bursts (peaks 2x+ higher than average)
    /// Ambient noise is uniform (ratio ~1.0-1.5)
    func getPeakToAverageRatio() -> Float {
        let average = getAverageLevel()
        guard average > 0.001 else { return 0 }
        return getPeakLevel() / average
    }

    /// Checks if the recording has sufficient audio activity (not just silence or ambient noise)
    /// Uses OR logic: either good volume OR dynamic range indicates speech
    /// This avoids rejecting soft/continuous speech that may have lower peak-to-average ratio
    func hasSpeechActivity() -> Bool {
        let averageLevel = getAverageLevel()
        let peakRatio = getPeakToAverageRatio()
        // Accept if: good volume alone, OR moderate volume with some dynamic range
        return averageLevel >= Self.silenceThreshold || (averageLevel >= 0.03 && peakRatio >= 1.5)
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
        durationTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            // The timer is on the main run loop, so this already runs on the main actor.
            MainActor.assumeIsolated {
                guard let self = self, let startTime = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)

                // Auto-stop at maximum duration
                if self.recordingDuration >= Self.maximumRecordingDuration {
                    NotificationCenter.default.post(name: .performToggleRecording, object: nil)
                }
            }
        }
        // `.common` keeps the clock ticking while a menu or scroll view is tracking the mouse.
        RunLoop.main.add(timer, forMode: .common)
        durationTimer = timer
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
