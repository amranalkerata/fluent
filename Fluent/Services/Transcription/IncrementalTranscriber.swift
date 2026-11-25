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

/// Releases a session's live items in segment order, holding them back until the session's
/// language is settled (see `IncrementalTranscriber.liveEvents`). A segment can release items
/// while it is open (words committed as they are spoken) and one last item when it is done;
/// nothing of a later segment comes out before an earlier one is done. Pure, for the self-test.
struct LiveSegmentGate<Item> {
    /// True once the session can no longer be abandoned for a language reason.
    private(set) var isSettled: Bool
    /// True once nothing more may be released (session finished, abandoned or failed).
    private(set) var isClosed = false
    /// Items not released yet, by segment index.
    private var held: [Int: [Item]] = [:]
    /// Segments that are done but not released yet.
    private var done: Set<Int> = []
    /// Index of the next segment to release.
    private(set) var nextIndex = 0

    init(settled: Bool) {
        isSettled = settled
    }

    /// An item of segment `index` while it is still open. Returns what can be released now.
    mutating func add(_ index: Int, _ item: Item) -> [Item] {
        guard !isClosed, index >= nextIndex else { return [] }
        held[index, default: []].append(item)
        return release()
    }

    /// Segment `index` is done; `item` (if any) is its last. Returns what can be released now,
    /// in order.
    mutating func complete(_ index: Int, _ item: Item?) -> [Item] {
        guard !isClosed, index >= nextIndex else { return [] }
        if let item { held[index, default: []].append(item) }
        done.insert(index)
        return release()
    }

    /// The language is settled: returns every held item that is now in order.
    mutating func settle() -> [Item] {
        guard !isClosed, !isSettled else { return [] }
        isSettled = true
        return release()
    }

    /// Nothing more is released; held items are dropped.
    mutating func close() {
        isClosed = true
        held.removeAll()
        done.removeAll()
    }

    private mutating func release() -> [Item] {
        guard isSettled else { return [] }
        var ready: [Item] = []
        while true {
            if let items = held.removeValue(forKey: nextIndex) { ready += items }
            guard done.remove(nextIndex) != nil else { break }
            nextIndex += 1
        }
        return ready
    }
}

/// What live typing receives from a session, in order.
enum LiveEvent: Equatable, Sendable {
    /// Words of the open segment committed now (brackets unwrapped, cleanup applied), and the
    /// rest of the latest hypothesis after them: not committed, only context for punctuation.
    case words([String], lookahead: [String])
    /// The segment is transcribed: the words of its final text that follow the committed ones
    /// (all of them when nothing was committed; none for a hallucination).
    case segmentEnd([String])
}

/// Streaming live typing: while a segment is still open, Audar re-reads its audio so far
/// ("partial pass") and the committer types the words that are stable enough.
struct StreamingConfig {
    /// Measured with `--streaming-selftest` (6 Casablanca clips + a 43 s own-voice clip, real
    /// time): local agreement at 0.5 s typed words ~1 s after they were heard with 12% of
    /// early words differing from the final text and no loss against references; HOLD-1 was
    /// ~0.5 s faster but 20% of its early words differed.
    var policy: StreamingCommitter.Policy = .localAgreement
    /// A partial pass needs at least this much new audio since the previous one.
    var partialInterval = 0.5
    /// First partial pass of a segment once it holds this much audio.
    var minPartialSeconds = 1.0
    /// Two partial passes in a row slower than this (a long segment) end partial passes for
    /// that segment; its words are then typed when it closes, as without streaming. One slow
    /// pass alone (the GPU busy with language detection, a cold start) does not.
    var maxPartialMs = 1500.0
}

/// Transcribes a recording with Audar while it is still being recorded: each finished speech
/// segment is queued for Audar as soon as the user pauses, so at stop only the last segment
/// is left. One instance per recording.
///
/// With `streaming` (live typing on), Audar also re-reads the open segment whenever it is idle
/// and enough new audio has come in, so words can be typed while they are spoken. Finished
/// segments always go first: a partial pass only starts when no Audar run is queued or running.
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
        /// The engine that transcribed the recording.
        var engine: SpeechEngine = .audar
    }

    /// One Audar run on a segment, for the DEBUG streaming self-test.
    struct HypothesisRecord: Sendable {
        var segment: Int
        /// False for a partial pass on the open segment.
        var isFinal: Bool
        var text: String
        /// End of the audio the run read, in seconds from the start of the recording.
        var windowEnd: Double
        var startedAt: UInt64
        var finishedAt: UInt64
        var ms: Double
        /// A partial pass whose segment was still open when it finished (its words count).
        var segmentOpen = false
    }

    /// Whisper detection starts after this much speech, and once more after the second
    /// threshold when the first answer settled nothing. Live typing waits for the language, so
    /// the first detection is early. Measured with `--detect-prefix-selftest` (17 Arabic dialect
    /// clips, 6 English): after 1 s of speech English came back ≥ 0.98 sure every time, while
    /// Arabic misread as another language never passed 0.77 (one of the user's own clips read
    /// as English at 0.62, above `minimumDetectionConfidence`).
    private static let detectionSpeechSeconds = 1.0
    private static let redetectionSpeechSeconds = 2.5
    /// A detection moves the recording from Audar to Whisper only when it is this sure the
    /// speech is another language.
    static let otherLanguageConfidence: Float = 0.9
    /// Whisper reads at most the first 30 s.
    private static let detectionMaxSamples = 30 * SpeechSegmenter.sampleRate
    /// The punctuation model's first prediction after ~30-60 s idle takes ~0.8 s instead of
    /// ~50 ms. A throwaway prediction this often during recording keeps the one at stop fast.
    private static let formatterWarmInterval: UInt64 = 10_000_000_000

    /// The language setting this session was started for ("ar", or "" for auto).
    nonisolated let languageSetting: String

    /// What live typing types, in order, as soon as the language is settled: at once for
    /// Arabic (or auto without Whisper, where nothing can abandon the session for a language
    /// reason); in auto mode with Whisper, held back until a detection routes to Audar with
    /// enough confidence, the second detection routes to Audar, or `finish` has run the last
    /// detection. Without `streaming` only `.segmentEnd` events come. Finishes when the
    /// session finishes, abandons, fails or is cancelled; `finish` still returns the whole
    /// text either way.
    nonisolated let liveEvents: AsyncStream<LiveEvent>
    private let liveContinuation: AsyncStream<LiveEvent>.Continuation
    private var liveGate: LiveSegmentGate<LiveEvent>

    /// The engine that transcribes the recording and the language it is given.
    enum Engine: Equatable, Sendable {
        /// Arabic (the language is nil when Audar identifies it itself).
        case audar(language: String?)
        /// Any other language, Whisper's code ("en", "fr"…).
        case whisper(language: String)

        var speechEngine: SpeechEngine {
            switch self {
            case .audar: return .audar
            case .whisper: return .whisper
            }
        }
    }

    /// Audar for Arabic; auto mode moves to Whisper when a detection is sure the speech is
    /// another language (`otherLanguageConfidence`).
    private var engine: Engine
    /// Bumped when the engine changes: runs queued for the previous engine are dropped.
    private var generation = 0
    /// Audio of every closed segment, in order, read again after an engine change.
    private var closedRanges: [Range<Int>] = []
    private let detectsLanguage: Bool
    private let streaming: StreamingConfig?
    private var segmenter: SpeechSegmenter
    private var samples: [Float] = []

    /// The recorder's sample stream, until reading it starts.
    private var stream: AsyncStream<[Float]>?
    private var feedTask: Task<Void, Never>?
    /// Last queued engine run; each run awaits the one before, so the engine sees them in order.
    private var lastRun: Task<Void, Never>?
    /// Engine runs queued or running (partial passes included).
    private var runsInFlight = 0
    private var queued = 0
    private var texts: [Int: String] = [:]
    private var segmentMs: [Int: Double] = [:]
    private var segmentSeconds: [Double] = []
    private var failure: String?
    /// Set by `finish`: no partial pass starts after the stop.
    private var finishing = false

    /// Commits words of the open segment (index `queued`); handed over when the segment closes.
    private var openCommitter: StreamingCommitter
    private var closedCommitters: [Int: StreamingCommitter] = [:]
    /// Sample count read by the open segment's last partial pass.
    private var lastPartialEnd: Int?
    /// Partial passes of the open segment were too slow: no more for it.
    private var partialsStopped = false
    /// Slow partial passes in a row on the open segment.
    private var slowPartials = 0
    /// Hallucination filter, the same one the stop path uses.
    private let filter = TranscriptionService()

    private var detectionTask: Task<Void, Never>?
    private var detectionRuns = 0
    private var detection: (language: String, confidence: Float)?
    private var detectionMs: Double?
    /// Set when the session gives up (non-Arabic speech, detection failure, cancel).
    private var abandoned: String?
    private var lastFormatterWarm: UInt64?

    #if DEBUG
    private var hypothesisObserver: (@Sendable (HypothesisRecord) -> Void)?

    /// DEBUG self-test: called with every Audar run of this session (partial and final).
    func observeHypotheses(_ observer: @escaping @Sendable (HypothesisRecord) -> Void) {
        hypothesisObserver = observer
    }
    #endif

    /// A session for this recording, or nil when the full-file path will handle it: Arabic or
    /// auto without Audar, or another language without Whisper loaded.
    /// `stream` is the recorder's 16 kHz mono sample stream (`AudioRecordingService.audioStream`).
    /// `streaming` turns on partial passes; only for a recording that is typed live.
    @MainActor
    static func makeIfApplicable(stream: AsyncStream<[Float]>, config: SpeechSegmenter.Config = .init(),
                                 streaming: StreamingConfig? = nil) -> IncrementalTranscriber? {
        let audarUsable = AudarModelManager.shared.isUsable
        let whisperReady = ModelManager.shared.state.isReady
        let language = SettingsService.shared.settings.language.rawValue
        switch language {
        case "ar":
            guard audarUsable else { return nil }
            return IncrementalTranscriber(stream: stream, languageSetting: language, engine: .audar(language: "ar"),
                                          detectsLanguage: false, config: config, streaming: streaming)
        case "":
            // Same routing as TranscriptionService: without Whisper, Audar identifies the language itself.
            guard audarUsable else { return nil }
            return IncrementalTranscriber(stream: stream, languageSetting: language,
                                          engine: .audar(language: whisperReady ? "ar" : nil),
                                          detectsLanguage: whisperReady, config: config, streaming: streaming)
        default:
            // English or another language set explicitly: Whisper in that language, as the
            // full-file path does.
            guard whisperReady else { return nil }
            return IncrementalTranscriber(stream: stream, languageSetting: language, engine: .whisper(language: language),
                                          detectsLanguage: false, config: config, streaming: streaming)
        }
    }

    private init(stream: AsyncStream<[Float]>, languageSetting: String, engine: Engine,
                 detectsLanguage: Bool, config: SpeechSegmenter.Config, streaming: StreamingConfig?) {
        self.stream = stream
        self.languageSetting = languageSetting
        self.engine = engine
        self.detectsLanguage = detectsLanguage
        self.streaming = streaming
        self.segmenter = SpeechSegmenter(config: config)
        openCommitter = StreamingCommitter(policy: streaming?.policy ?? .localAgreement)
        samples.reserveCapacity(60 * SpeechSegmenter.sampleRate)
        var continuation: AsyncStream<LiveEvent>.Continuation!
        liveEvents = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        liveContinuation = continuation
        liveGate = LiveSegmentGate(settled: !detectsLanguage)
    }

    // MARK: - Live stream

    private func releaseLive(_ events: [LiveEvent]) {
        for event in events { liveContinuation.yield(event) }
    }

    private func settleLanguage() {
        releaseLive(liveGate.settle())
    }

    private func closeLive() {
        liveGate.close()
        liveContinuation.finish()
    }

    /// The words a raw Audar text contributes, processed as the stop path does before
    /// punctuation (sound tags out, bracketed words unwrapped, speech cleanup), and false for
    /// a hallucination (no words then).
    static func hypothesisWords(_ raw: String, filter: TranscriptionService, cleanup: Bool) -> (words: [String], acceptable: Bool) {
        // Whisper sometimes quotes a whole utterance ("Hey, can you…"); the quotes are not speech.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        if filter.isHallucination(trimmed) { return ([], false) }
        var text = SpeechCleanup.unwrapBrackets(trimmed, nonSpeechPhrases: TranscriptionService.hallucinationPhrases)
        if text != trimmed && (text.isEmpty || filter.isHallucination(text)) { return ([], false) }
        if cleanup { text = SpeechCleanup.clean(text) }
        return (StreamingText.words(text), true)
    }

    private func hypothesisWords(_ raw: String) -> (words: [String], acceptable: Bool) {
        Self.hypothesisWords(raw, filter: filter, cleanup: SettingsService.shared.settings.cleanupEnabled)
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
        maybeRunPartial()
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
        // The open segment's committer goes with it; the next segment starts fresh.
        closedCommitters[index] = openCommitter
        openCommitter = StreamingCommitter(policy: openCommitter.policy)
        lastPartialEnd = nil
        partialsStopped = false
        slowPartials = 0
        closedRanges.append(range)

        let audio = Array(samples[range])
        let windowEnd = Double(range.upperBound) / Double(SpeechSegmenter.sampleRate)
        segmentSeconds.append(Double(audio.count) / Double(SpeechSegmenter.sampleRate))
        let engine = self.engine
        let generation = self.generation
        let previous = lastRun
        runsInFlight += 1
        lastRun = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard await self.shouldRun(generation) else {
                await self.runSkipped()
                return
            }
            let start = LatencyLog.now()
            let outcome: Result<String, Error>
            do {
                outcome = .success(try await Self.transcribe(audio, with: engine))
            } catch {
                outcome = .failure(error)
            }
            await self.record(index, outcome, generation: generation, startedAt: start, windowEnd: windowEnd)
        }
    }

    /// One run of `engine` on `audio`. Whisper reads nothing from less than a second of audio,
    /// so a shorter window is padded with silence.
    nonisolated private static func transcribe(_ audio: [Float], with engine: Engine) async throws -> String {
        switch engine {
        case .audar(let language):
            return try await AudarModelManager.shared.transcribe(samples: audio, language: language)
        case .whisper(let language):
            let minimum = Self.whisperMinimumSamples
            let padded = audio.count < minimum ? audio + [Float](repeating: 0, count: minimum - audio.count) : audio
            return try await ModelManager.shared.transcribe(samples: padded, language: language)
        }
    }

    private static let whisperMinimumSamples = 3 * SpeechSegmenter.sampleRate / 2

    private func shouldRun(_ generation: Int) -> Bool {
        abandoned == nil && failure == nil && generation == self.generation
    }

    private func runSkipped() {
        runsInFlight -= 1
        maybeRunPartial()
    }

    private func record(_ index: Int, _ outcome: Result<String, Error>, generation: Int, startedAt: UInt64, windowEnd: Double) {
        runsInFlight -= 1
        // Queued before an engine change: the segment is read again by the new engine.
        guard generation == self.generation else {
            maybeRunPartial()
            return
        }
        let ms = LatencyLog.ms(since: startedAt)
        segmentMs[index] = ms
        LatencyLog.log("rec.segment_asr", ms: ms, engine: engine.speechEngine.rawValue)
        switch outcome {
        case .success(let text):
            texts[index] = text
            #if DEBUG
            hypothesisObserver?(HypothesisRecord(segment: index, isFinal: true, text: text, windowEnd: windowEnd,
                                                 startedAt: startedAt, finishedAt: LatencyLog.now(), ms: ms))
            #endif
            let hypothesis = hypothesisWords(text)
            var committer = closedCommitters.removeValue(forKey: index) ?? StreamingCommitter(policy: openCommitter.policy)
            // A hallucination adds nothing; words typed before it stay (they cannot be taken back).
            let rest = hypothesis.acceptable ? committer.finish(hypothesis.words) : []
            releaseLive(liveGate.complete(index, .segmentEnd(rest)))
        case .failure:
            failure = "segment failed"
            closeLive()
        }
        maybeRunPartial()
    }

    // MARK: - Partial passes (streaming)

    /// Starts a partial pass on the open segment when Audar is idle, the segment holds speech
    /// and enough audio has come in since the last pass.
    private func maybeRunPartial() {
        guard let streaming, !finishing, !partialsStopped, abandoned == nil, failure == nil,
              runsInFlight == 0, segmenter.segmentSpeechFrames > 0 else { return }
        let start = segmenter.segmentStart
        let end = samples.count
        let rate = Double(SpeechSegmenter.sampleRate)
        guard end - start >= Int(streaming.minPartialSeconds * rate),
              end - (lastPartialEnd ?? start) >= Int(streaming.partialInterval * rate) else { return }
        lastPartialEnd = end

        let index = queued
        let audio = Array(samples[start..<end])
        let windowEnd = Double(end) / rate
        let engine = self.engine
        let generation = self.generation
        let previous = lastRun
        runsInFlight += 1
        lastRun = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard await self.shouldRun(generation) else {
                await self.runSkipped()
                return
            }
            let start = LatencyLog.now()
            let text = try? await Self.transcribe(audio, with: engine)
            await self.recordPartial(index, text, generation: generation, startedAt: start, windowEnd: windowEnd)
        }
    }

    private func recordPartial(_ index: Int, _ text: String?, generation: Int, startedAt: UInt64, windowEnd: Double) {
        runsInFlight -= 1
        guard generation == self.generation else {
            maybeRunPartial()
            return
        }
        let ms = LatencyLog.ms(since: startedAt)
        LatencyLog.log("rec.partial_asr", ms: ms)
        #if DEBUG
        if let text {
            hypothesisObserver?(HypothesisRecord(segment: index, isFinal: false, text: text, windowEnd: windowEnd,
                                                 startedAt: startedAt, finishedAt: LatencyLog.now(), ms: ms,
                                                 segmentOpen: index == queued))
        }
        #endif
        // Only while the segment is still open: once it closed, its final pass decides.
        if index == queued, abandoned == nil, failure == nil {
            if let streaming {
                slowPartials = ms > streaming.maxPartialMs ? slowPartials + 1 : 0
                if slowPartials >= 2 { partialsStopped = true }
            }
            if let text {
                let hypothesis = hypothesisWords(text)
                let update = openCommitter.update(hypothesis.words, acceptable: hypothesis.acceptable)
                if !update.words.isEmpty {
                    releaseLive(liveGate.add(index, .words(update.words, lookahead: update.lookahead)))
                }
            } else {
                partialsStopped = true
            }
        }
        maybeRunPartial()
    }

    // MARK: - Language detection (auto)

    private func maybeDetectLanguage() {
        guard detectionTask == nil, abandoned == nil else { return }
        let speech = segmenter.totalSpeechSeconds
        switch detectionRuns {
        case 0 where speech >= Self.detectionSpeechSeconds:
            break
        case 1 where speech >= Self.redetectionSpeechSeconds && !liveGate.isSettled:
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
        let arabic = TranscriptionService.isArabicLike(result.language)
        if !arabic && result.confidence >= Self.otherLanguageConfidence {
            switchToWhisper(language: result.language)
        } else if (arabic && result.confidence >= TranscriptionService.minimumDetectionConfidence) || detectionRuns >= 2 {
            // No later detection can run (see maybeDetectLanguage), so Audar keeps this recording.
            settleLanguage()
        }
    }

    /// The speech is another language: Whisper transcribes the recording from the start, in
    /// that language. Nothing has been typed yet (the language was not settled), so the closed
    /// segments are read again and the words Audar committed are dropped with their gate.
    private func switchToWhisper(language: String) {
        guard abandoned == nil, failure == nil else { return }
        LatencyLog.logger.info("incremental: switching to Whisper (\(language, privacy: .public))")
        engine = .whisper(language: language)
        generation += 1
        let ranges = closedRanges
        closedRanges = []
        queued = 0
        texts.removeAll()
        segmentMs.removeAll()
        segmentSeconds.removeAll()
        closedCommitters.removeAll()
        openCommitter = StreamingCommitter(policy: openCommitter.policy)
        lastPartialEnd = nil
        partialsStopped = false
        slowPartials = 0
        liveGate = LiveSegmentGate(settled: true)
        for range in ranges {
            enqueue(range)
        }
        maybeRunPartial()
    }

    private func abandon(_ reason: String) {
        guard abandoned == nil else { return }
        abandoned = reason
        // Queued runs see `abandoned` and skip; a run already inside Audar finishes and is dropped.
        closeLive()
    }

    // MARK: - Stop

    /// Call after the recorder has finished the stream. Transcribes what is left, waits for
    /// the queued segments and returns the joined text, or `.fallback` if the full-file path
    /// must be used. `recordedDuration` guards against a stream that lost audio.
    func finish(recordedDuration: TimeInterval) async -> Outcome {
        let start = LatencyLog.now()
        finishing = true
        // Every segment has been released (or dropped) by the time this returns.
        defer { closeLive() }
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
            // No detection runs after this point: the recording stays on Audar.
            settleLanguage()
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
            switch languageSetting {
            case "ar": stats.reason = "incremental, language set to Arabic"
            case "": stats.reason = "incremental, auto, Whisper not ready"
            default: stats.reason = "incremental, language set to \(languageSetting)"
            }
        }
        stats.engine = engine.speechEngine
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
