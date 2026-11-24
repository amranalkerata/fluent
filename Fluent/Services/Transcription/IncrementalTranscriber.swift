import Foundation

/// Cuts a live 16 kHz mono stream into speech segments at natural pauses.
///
/// Energy VAD on 30 ms frames against an adaptive noise floor (running minimum that drifts up
/// slowly). A segment closes once it holds enough audio with speech and a pause has lasted
/// `pauseSeconds`; the cut falls in the middle of that pause, and the two neighbouring segments
/// overlap by `padSeconds` of the pause on each side so no word edge is lost. Past
/// `relaxAfterSeconds` a `relaxedPauseSeconds` pause is enough. A segment that
/// reaches `maxSegmentSeconds` without a pause is cut at its quietest 200 ms in the last
/// `forceSearchSeconds`, without overlap (the cut may sit between two words).
struct SpeechSegmenter {
    struct Config {
        var minSegmentSeconds = 2.5
        var minSpeechSeconds = 0.3
        var pauseSeconds = 0.5
        /// Once a segment is this long, a shorter pause is enough (fast talkers rarely pause
        /// for half a second, and everything after the last cut is waited for at stop).
        var relaxAfterSeconds = 8.0
        var relaxedPauseSeconds = 0.3
        var maxSegmentSeconds = 25.0
        var forceSearchSeconds = 5.0
        var padSeconds = 0.15
        /// Silence kept before the first speech of a segment (leading silence beyond it is dropped).
        var leadInSeconds = 0.4
        /// A frame is speech when it is this far above the noise floor.
        var speechMarginDb: Float = 10
    }

    static let sampleRate = 16_000
    static let frameLength = 480 // 30 ms

    /// The noise floor never goes below this (digital silence would otherwise pin it at -inf).
    private static let lowestFloorDb: Float = -70
    /// Upward drift of the noise floor per frame (1 dB/s) so it follows rising background noise.
    private static let floorRiseDb: Float = 0.03

    let config: Config
    private let pauseFrames: Int
    private let relaxedPauseFrames: Int
    private let relaxAfterSamples: Int
    private let minSegmentSamples: Int
    private let minSpeechFrames: Int
    private let maxSegmentSamples: Int
    private let pad: Int
    private let leadIn: Int

    /// Start of the open segment (sample index).
    private(set) var segmentStart = 0
    /// Speech frames in the open segment.
    private(set) var segmentSpeechFrames = 0
    /// Speech frames in the whole recording.
    private(set) var totalSpeechFrames = 0
    /// Frames analysed so far.
    private var frames = 0
    private var noiseFloorDb: Float?
    /// Consecutive non-speech frames (a lone speech frame is treated as a click, not speech).
    private var silenceRun = 0
    private var previousWasSpeech = false

    init(config: Config = Config()) {
        self.config = config
        let rate = Double(Self.sampleRate)
        pauseFrames = Int((config.pauseSeconds * rate / Double(Self.frameLength)).rounded(.up))
        relaxedPauseFrames = Int((config.relaxedPauseSeconds * rate / Double(Self.frameLength)).rounded(.up))
        relaxAfterSamples = Int(config.relaxAfterSeconds * rate)
        minSegmentSamples = Int(config.minSegmentSeconds * rate)
        minSpeechFrames = Int((config.minSpeechSeconds * rate / Double(Self.frameLength)).rounded(.up))
        maxSegmentSamples = Int(config.maxSegmentSeconds * rate)
        pad = Int(config.padSeconds * rate)
        leadIn = Int(config.leadInSeconds * rate)
    }

    var totalSpeechSeconds: Double {
        Double(totalSpeechFrames * Self.frameLength) / Double(Self.sampleRate)
    }

    /// Analyses every complete frame of `samples` not seen yet and returns the segments that
    /// closed, in order. `samples` is the whole recording so far.
    mutating func advance(_ samples: [Float]) -> [Range<Int>] {
        var closed: [Range<Int>] = []
        while (frames + 1) * Self.frameLength <= samples.count {
            let frameStart = frames * Self.frameLength
            let frameEnd = frameStart + Self.frameLength
            let isSpeech = classify(samples[frameStart..<frameEnd])
            frames += 1

            if isSpeech {
                segmentSpeechFrames += 1
                totalSpeechFrames += 1
                if previousWasSpeech { silenceRun = 0 } else { silenceRun += 1 }
            } else {
                silenceRun += 1
            }
            previousWasSpeech = isSpeech

            // Before any speech, keep only a short lead-in of the silence.
            if segmentSpeechFrames == 0 {
                segmentStart = max(segmentStart, frameEnd - leadIn)
                // Silence before the segment's first speech is not a pause inside it.
                silenceRun = 0
                continue
            }

            let length = frameEnd - segmentStart
            let requiredPause = length >= relaxAfterSamples ? relaxedPauseFrames : pauseFrames
            if silenceRun >= requiredPause, length >= minSegmentSamples, segmentSpeechFrames >= minSpeechFrames {
                // Clamp: a pause can never start before the segment itself.
                let pauseStart = max(segmentStart, frameEnd - silenceRun * Self.frameLength)
                let cut = pauseStart + (frameEnd - pauseStart) / 2
                let end = max(segmentStart, min(cut + pad, frameEnd))
                closed.append(segmentStart..<end)
                startSegment(at: max(segmentStart, min(cut - pad, frameEnd)))
            } else if length >= maxSegmentSamples {
                let cut = Self.quietestPoint(samples, in: max(segmentStart, frameEnd - Int(config.forceSearchSeconds * Double(Self.sampleRate)))..<frameEnd)
                closed.append(segmentStart..<cut)
                startSegment(at: cut)
                // The new segment already holds speech between the cut and here.
                segmentSpeechFrames = 1
            }
        }
        return closed
    }

    /// What is left after the last cut, when it holds any speech.
    func tail(of samples: [Float]) -> Range<Int>? {
        guard segmentSpeechFrames > 0, segmentStart < samples.count else { return nil }
        return segmentStart..<samples.count
    }

    private mutating func startSegment(at start: Int) {
        segmentStart = start
        segmentSpeechFrames = 0
        silenceRun = 0
        previousWasSpeech = false
    }

    private mutating func classify(_ frame: ArraySlice<Float>) -> Bool {
        var energy: Float = 0
        for value in frame { energy += value * value }
        let db = 10 * log10(max(energy / Float(frame.count), 1e-12))

        let floor = max(Self.lowestFloorDb, min(db, (noiseFloorDb ?? db) + Self.floorRiseDb))
        noiseFloorDb = floor
        return db > floor + config.speechMarginDb
    }

    /// Centre of the quietest 200 ms window (10 ms hop) inside `range`.
    static func quietestPoint(_ samples: [Float], in range: Range<Int>) -> Int {
        let window = sampleRate / 5
        let hop = sampleRate / 100
        var best = range.upperBound
        var bestEnergy = Float.infinity
        var start = range.lowerBound
        while start + window <= range.upperBound {
            var energy: Float = 0
            for i in start..<(start + window) { energy += samples[i] * samples[i] }
            if energy < bestEnergy {
                bestEnergy = energy
                best = start + window / 2
            }
            start += hop
        }
        return best
    }
}

/// Transcribes a recording with Audar while it is still being recorded: each finished speech
/// segment is queued for Audar as soon as the user pauses, so at stop only the last segment
/// is left. One instance per recording.
///
/// Used only when Audar would handle the recording anyway: language set to Arabic, or auto
/// with Whisper's language detection (run on the first seconds of speech, while recording)
/// pointing to Audar under the same rule as `TranscriptionService`. In every other case, and
/// whenever anything goes wrong, `finish` answers `.fallback` and the caller transcribes the
/// recorded file as before.
actor IncrementalTranscriber {
    enum Outcome {
        /// Raw Audar text of all segments, in order, joined with spaces (not post-processed).
        case transcript(String, Stats)
        /// Use the full-file path instead. The reason is a fixed phrase (never transcript text).
        case fallback(String)
    }

    struct Stats {
        var segments = 0
        /// Audar run time and audio length of each segment, in order (ms, s).
        var segmentMs: [Double] = []
        var segmentSeconds: [Double] = []
        /// From `finish` to the joined text (ms).
        var finishMs: Double = 0
        var audioSeconds: Double = 0
        var detectionMs: Double?
        var reason = ""
    }

    /// Whisper detection starts after this much speech, and once more after the second
    /// threshold when the first answer had low confidence.
    private static let detectionSpeechSeconds = 3.0
    private static let redetectionSpeechSeconds = 8.0
    /// Whisper reads at most the first 30 s.
    private static let detectionMaxSamples = 30 * SpeechSegmenter.sampleRate
    /// The punctuation model's first prediction after ~30-60 s idle takes ~0.8 s instead of
    /// ~50 ms. A throwaway prediction this often during recording keeps the one at stop fast.
    private static let formatterWarmInterval: UInt64 = 10_000_000_000

    /// The language setting this session was started for ("ar", or "" for auto).
    nonisolated let languageSetting: String

    private let audarLanguage: String?
    private let detectsLanguage: Bool
    private var segmenter: SpeechSegmenter
    private var samples: [Float] = []

    /// The recorder's sample stream, until reading it starts.
    private var stream: AsyncStream<[Float]>?
    private var feedTask: Task<Void, Never>?
    /// Last queued segment run; each run awaits the one before, so Audar sees them in order.
    private var lastRun: Task<Void, Never>?
    private var queued = 0
    private var texts: [Int: String] = [:]
    private var segmentMs: [Int: Double] = [:]
    private var segmentSeconds: [Double] = []
    private var failure: String?

    private var detectionTask: Task<Void, Never>?
    private var detectionRuns = 0
    private var detection: (language: String, confidence: Float)?
    private var detectionMs: Double?
    /// Set when the session gives up (non-Arabic speech, detection failure, cancel).
    private var abandoned: String?
    private var lastFormatterWarm: UInt64?

    /// A session for this recording, or nil when the full-file path will handle it
    /// (Audar not usable, or a language other than Arabic/auto).
    /// `stream` is the recorder's 16 kHz mono sample stream (`AudioRecordingService.audioStream`).
    @MainActor
    static func makeIfApplicable(stream: AsyncStream<[Float]>, config: SpeechSegmenter.Config = .init()) -> IncrementalTranscriber? {
        guard AudarModelManager.shared.isUsable else { return nil }
        let language = SettingsService.shared.settings.language.rawValue
        switch language {
        case "ar":
            return IncrementalTranscriber(stream: stream, languageSetting: language, audarLanguage: "ar",
                                          detectsLanguage: false, config: config)
        case "":
            // Same routing as TranscriptionService: without Whisper, Audar identifies the language itself.
            let whisperReady = ModelManager.shared.state.isReady
            return IncrementalTranscriber(stream: stream, languageSetting: language, audarLanguage: whisperReady ? "ar" : nil,
                                          detectsLanguage: whisperReady, config: config)
        default:
            return nil
        }
    }

    private init(stream: AsyncStream<[Float]>, languageSetting: String, audarLanguage: String?,
                 detectsLanguage: Bool, config: SpeechSegmenter.Config) {
        self.stream = stream
        self.languageSetting = languageSetting
        self.audarLanguage = audarLanguage
        self.detectsLanguage = detectsLanguage
        self.segmenter = SpeechSegmenter(config: config)
        samples.reserveCapacity(60 * SpeechSegmenter.sampleRate)
    }

    // MARK: - Input

    /// Starts reading the recorder's sample stream (it ends when the recorder finishes it).
    /// `finish` also starts it, in case the recording stopped before this ran.
    func start() {
        guard let stream, abandoned == nil else { return }
        self.stream = nil
        feedTask = Task { [weak self] in
            for await chunk in stream {
                guard let self else { return }
                await self.append(chunk)
            }
        }
    }

    private func append(_ chunk: [Float]) {
        guard abandoned == nil else { return }
        samples.append(contentsOf: chunk)
        for range in segmenter.advance(samples) {
            enqueue(range)
        }
        if detectsLanguage { maybeDetectLanguage() }
        keepFormatterWarm()
    }

    /// Runs a prediction on a fixed phrase (never transcript text); the result is discarded.
    private func keepFormatterWarm() {
        let now = LatencyLog.now()
        if let last = lastFormatterWarm, now &- last < Self.formatterWarmInterval { return }
        lastFormatterWarm = now
        Task.detached(priority: .utility) {
            let formatter = await PunctuationModelManager.shared
            guard SettingsService.shared.settings.formatTextEnabled, await formatter.state.isReady else { return }
            _ = try? await formatter.infer(text: "مرحبا كيف حالك اليوم")
        }
    }

    // MARK: - Segments

    private func enqueue(_ range: Range<Int>) {
        guard abandoned == nil else { return }
        let index = queued
        queued += 1
        let audio = Array(samples[range])
        segmentSeconds.append(Double(audio.count) / Double(SpeechSegmenter.sampleRate))
        let language = audarLanguage
        let previous = lastRun
        lastRun = Task { [weak self] in
            await previous?.value
            guard let self, await self.shouldRun() else { return }
            let audar = await AudarModelManager.shared
            let start = LatencyLog.now()
            let outcome: Result<String, Error>
            do {
                outcome = .success(try await audar.transcribe(samples: audio, language: language))
            } catch {
                outcome = .failure(error)
            }
            await self.record(index, outcome, ms: LatencyLog.ms(since: start))
        }
    }

    private func shouldRun() -> Bool {
        abandoned == nil && failure == nil
    }

    private func record(_ index: Int, _ outcome: Result<String, Error>, ms: Double) {
        segmentMs[index] = ms
        LatencyLog.log("rec.segment_asr", ms: ms, engine: SpeechEngine.audar.rawValue)
        switch outcome {
        case .success(let text): texts[index] = text
        case .failure: failure = "segment failed"
        }
    }

    // MARK: - Language detection (auto)

    private func maybeDetectLanguage() {
        guard detectionTask == nil, abandoned == nil else { return }
        let speech = segmenter.totalSpeechSeconds
        switch detectionRuns {
        case 0 where speech >= Self.detectionSpeechSeconds:
            break
        case 1 where speech >= Self.redetectionSpeechSeconds && (detection?.confidence ?? 0) < TranscriptionService.minimumDetectionConfidence:
            break
        default:
            return
        }
        startDetection()
    }

    private func startDetection() {
        detectionRuns += 1
        let audio = Array(samples.prefix(Self.detectionMaxSamples))
        detectionTask = Task { [weak self] in
            let whisper = await ModelManager.shared
            let start = LatencyLog.now()
            let result: (language: String, confidence: Float)?
            do {
                result = try await whisper.detectLanguage(samples: audio)
            } catch {
                result = nil
            }
            await self?.recordDetection(result, ms: LatencyLog.ms(since: start))
        }
    }

    private func recordDetection(_ result: (language: String, confidence: Float)?, ms: Double) {
        detectionTask = nil
        detectionMs = ms
        LatencyLog.log("rec.detect", ms: ms)
        guard let result else {
            abandon("detection failed")
            return
        }
        detection = result
        if !TranscriptionService.routesToAudar(language: result.language, confidence: result.confidence) {
            abandon("detected non-Arabic speech")
        }
    }

    private func abandon(_ reason: String) {
        guard abandoned == nil else { return }
        abandoned = reason
        // Queued runs see `abandoned` and skip; a run already inside Audar finishes and is dropped.
    }

    // MARK: - Stop

    /// Call after the recorder has finished the stream. Transcribes what is left, waits for
    /// the queued segments and returns the joined text, or `.fallback` if the full-file path
    /// must be used. `recordedDuration` guards against a stream that lost audio.
    func finish(recordedDuration: TimeInterval) async -> Outcome {
        let start = LatencyLog.now()
        self.start()
        await feedTask?.value
        feedTask = nil

        if let abandoned { return .fallback(abandoned) }

        let audioSeconds = Double(samples.count) / Double(SpeechSegmenter.sampleRate)
        if audioSeconds < recordedDuration - max(0.5, recordedDuration * 0.05) {
            abandon("sample stream incomplete")
            return .fallback("sample stream incomplete")
        }

        if let tail = segmenter.tail(of: samples) {
            enqueue(tail)
        }
        keepFormatterWarm()

        if detectsLanguage {
            // Not enough speech yet for the in-recording detection: detect on everything now,
            // while the last segment is transcribed (as the full-file path does).
            if detectionRuns == 0 && detectionTask == nil { startDetection() }
            while let task = detectionTask { await task.value }
            if let abandoned { return .fallback(abandoned) }
        }

        await lastRun?.value
        if let failure { return .fallback(failure) }

        let joined = (0..<queued)
            .compactMap { texts[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if joined.isEmpty { return .fallback("empty incremental result") }

        var stats = Stats()
        stats.segments = queued
        stats.segmentMs = (0..<queued).map { segmentMs[$0] ?? 0 }
        stats.segmentSeconds = segmentSeconds
        stats.audioSeconds = audioSeconds
        stats.detectionMs = detectionMs
        if let detection {
            stats.reason = "incremental, auto, detected \(detection.language) (\(String(format: "%.2f", detection.confidence)))"
        } else {
            stats.reason = languageSetting == "ar" ? "incremental, language set to Arabic" : "incremental, auto, Whisper not ready"
        }
        stats.finishMs = LatencyLog.ms(since: start)
        return .transcript(joined, stats)
    }

    /// Recording cancelled (or not transcribed): drop everything still queued.
    func cancel() {
        abandon("cancelled")
        stream = nil
        feedTask?.cancel()
        feedTask = nil
        detectionTask?.cancel()
    }
}
