import Foundation

enum TranscriptionError: LocalizedError {
    case modelNotReady
    case audioConversionFailed(String)
    case transcriptionFailed(String)
    case fileNotFound
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .modelNotReady:
            return "Whisper model is not ready. Please download the model first."
        case .audioConversionFailed(let reason):
            return "Failed to convert audio: \(reason)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .fileNotFound:
            return "Audio file not found."
        case .emptyTranscription:
            return "No speech detected in the recording."
        }
    }
}

/// Which speech-to-text engine handled a recording.
enum SpeechEngine: String {
    case whisper = "Whisper"
    case audar = "Audar"
}

class TranscriptionService {
    private let settingsService = SettingsService.shared
    private let textFormattingService = TextFormattingService()

    /// Engine and reason chosen by the last `transcribe(audioURL:)` call (diagnostics).
    private(set) var lastEngine: SpeechEngine?
    private(set) var lastRouteReason: String?

    /// Stage durations of the last `transcribe(audioURL:)` call, in milliseconds (diagnostics).
    struct StageTimings {
        var audioSeconds: Double = 0
        var conversionMs: Double = 0
        /// Whisper language detection (auto mode with Audar only).
        var detectionMs: Double?
        /// Run time of the engine call that produced the text (includes a failed Audar run before a fallback).
        /// Incremental path: the Audar runs still pending at stop (last segment included).
        var asrMs: Double = 0
        /// Incremental path only: number of segments, and Audar time of each (ms).
        var segments: Int?
        var segmentMs: [Double] = []
        var segmentSeconds: [Double] = []
        /// Wall time from samples ready to raw text: detection + transcription, overlapped or not.
        var routeAndAsrMs: Double = 0
        var formattingMs: Double = 0
        var totalMs: Double = 0
    }
    private(set) var lastTimings = StageTimings()

    /// Whisper codes sent to Audar in auto mode: Arabic, plus the languages Whisper
    /// tends to report for Arabic dialects.
    private static let arabicLikeLanguages: Set<String> = ["ar", "fa", "ur", "ps"]
    /// Below this language-detection probability, auto mode prefers Audar.
    static let minimumDetectionConfidence: Float = 0.6

    /// Auto mode with Audar available: Whisper's detection goes to Audar when it reports
    /// Arabic (or a language Whisper confuses with Arabic dialects) or is unsure.
    static func routesToAudar(language: String, confidence: Float) -> Bool {
        isArabicLike(language) || confidence < minimumDetectionConfidence
    }

    /// Arabic, or a language Whisper confuses with Arabic dialects.
    static func isArabicLike(_ language: String) -> Bool {
        arabicLikeLanguages.contains(language)
    }

    // Known Whisper hallucination phrases (lowercased, without brackets for comparison)
    // The isHallucination() method strips brackets/parentheses before comparing.
    // Also the non-speech tags removed from brackets (see SpeechCleanup.unwrapBrackets).
    static let hallucinationPhrases: Set<String> = [
        // YouTube-style phrases
        "thank you for watching",
        "thanks for watching",
        "please subscribe",
        "subscribe",
        "like and subscribe",
        "see you next time",
        "see you in the next video",
        "bye",
        "goodbye",
        "bye bye",
        "thank you",
        "thanks",
        // Ellipsis and short filler
        "...",
        "…",
        "you",
        // Audio markers (stored without brackets - they get stripped)
        "music",
        "music playing",
        "applause",
        "silence",
        // Phone/device sounds
        "phone beeps",
        "phone beeping",
        "phone ringing",
        "phone rings",
        "beep",
        "beeps",
        "ding",
        // Other common hallucinations
        "inaudible",
        "unintelligible",
        "blank audio",
        "no audio",
        "static",
        "background noise",
        "coughing",
        "laughter",
        "laughing",
        "sighing",
        "sigh",
        "breathing",
        "clearing throat",
        // Filler sounds / hesitation markers
        "hmm",
        "hm",
        "uh",
        "um",
        "mhm",
        "mm",
        "mmm",
        "ah",
        "eh",
        "oh",
        // Transcription artifacts
        "indistinct",
        "muffled",
        "foreign language",
        "speaking foreign language",
        "speaking in foreign language",
        "subtitles by",
        "captions by",
        "transcript by"
    ]

    // MARK: - Hallucination Detection Helpers

    /// Check if text contains CJK (Chinese, Japanese, Korean) characters
    private func containsCJK(_ text: String) -> Bool {
        let cjkPattern = "[\\u4E00-\\u9FFF\\u3040-\\u309F\\u30A0-\\u30FF\\uAC00-\\uD7AF]"
        return text.range(of: cjkPattern, options: .regularExpression) != nil
    }

    /// Check for partial brackets followed by CJK text: "(知事) 言いません"
    private func hasPartialBracketWithCJK(_ text: String) -> Bool {
        // Pattern: bracket content followed by CJK outside the brackets
        let patterns = [
            "\\([^)]+\\)\\s*[\\u4E00-\\u9FFF\\u3040-\\u309F\\u30A0-\\u30FF]",
            "\\[[^\\]]+\\]\\s*[\\u4E00-\\u9FFF\\u3040-\\u309F\\u30A0-\\u30FF]"
        ]
        for pattern in patterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// Check for excessive character repetition: "??????", "aaaaaaa"
    private func hasExcessiveRepetition(_ text: String) -> Bool {
        // Runs of 4+ identical characters ("??????", "aaaaaaa", "يااااا…") are a Whisper/Audar
        // loop only when they make up most of the text. Real speech can contain them too —
        // Arabic laughter "ههههه", a hesitation "مممم" before a sentence — and dropping the
        // whole dictation for that loses the user's words.
        guard let regex = try? NSRegularExpression(pattern: "(.)\\1{3,}") else { return false }
        let nsText = text as NSString
        let repeated = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .reduce(0) { $0 + $1.range.length }
        let meaningful = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        return repeated > 0 && Double(repeated) >= 0.5 * Double(max(meaningful, 1))
    }

    /// Check if text is mostly question marks (Whisper hallucination on silence)
    /// Catches both regular ? and inverted ¿ question marks which are different Unicode characters
    private func isQuestionMarkSpam(_ text: String) -> Bool {
        let letters = text.filter { $0.isLetter }
        let questionMarks = text.filter { $0 == "?" || $0 == "¿" }
        // If more question marks than letters and at least 4 question marks, it's spam
        return questionMarks.count > 3 && questionMarks.count > letters.count
    }

    /// Check if text contains unexpected script for English language setting
    private func isUnexpectedScript(_ text: String) -> Bool {
        // When user has English selected, CJK is unexpected
        let language = settingsService.settings.language
        if language == .english || language == .auto {
            return containsCJK(text)
        }
        return false
    }

    /// Checks if the transcription is likely a Whisper hallucination. Internal (not private)
    /// so streaming live typing filters each hypothesis the same way (`IncrementalTranscriber`).
    func isHallucination(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Reject if entire text is wrapped in brackets or parentheses
        //    This catches audio markers: [music], (click), [Light music], (door closes), etc.
        //    Pattern-based detection beats blocklists because Whisper generates endless variations.
        //    Exception: a single bracketed word that is not a sound tag is speech (Audar writes
        //    English words said in Arabic speech in brackets: "[CRM]").
        //    Only one bracket group counts: "[CRM] جاهز قبل ال [deadline]" starts and ends with
        //    brackets but is speech; `cleanTranscriptionArtifacts` drops any tags in it later.
        if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) ||
           (trimmed.hasPrefix("(") && trimmed.hasSuffix(")")) {
            let inner = String(trimmed.dropFirst().dropLast())
            let isSingleGroup = !inner.contains(where: { "[]()".contains($0) })
            let isSingleWord = isSingleGroup && !inner.contains(where: \.isWhitespace)
            if isSingleGroup && (!isSingleWord || SpeechCleanup.isNonSpeechTag(inner, phrases: Self.hallucinationPhrases)) {
                return true
            }
        }

        // 2. Reject very short text (likely not real speech)
        if trimmed.count < 2 {
            return true
        }

        // 3. Check for partial brackets with CJK: "(知事) 言いません"
        if hasPartialBracketWithCJK(trimmed) {
            return true
        }

        // 4. Check for excessive repetition: "??????", "aaaaaaa"
        if hasExcessiveRepetition(trimmed) {
            return true
        }

        // 5. Check for question mark spam (Whisper hallucination on silence)
        if isQuestionMarkSpam(trimmed) {
            return true
        }

        // 6. Check for unexpected script (CJK when English is selected)
        if isUnexpectedScript(trimmed) {
            return true
        }

        // 7. Check blocklist for unbracketed hallucinations (e.g., "Thank you for watching")
        var normalized = trimmed.lowercased()
        normalized = normalized
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespaces)

        return Self.hallucinationPhrases.contains(normalized)
    }

    /// Removes non-speech markers like [inaudible], [BLANK_AUDIO], (click), [ضحك], and
    /// unwraps bracketed speech: Audar writes English words said in Arabic speech as "[CRM]".
    private func cleanTranscriptionArtifacts(_ text: String) -> String {
        SpeechCleanup.unwrapBrackets(text, nonSpeechPhrases: Self.hallucinationPhrases)
    }

    /// Streaming transcription - transcribes audio as it's being recorded
    /// Returns the final transcription and provides partial results via callback
    func transcribeStreaming(
        audioStream: AsyncStream<[Float]>,
        onPartialResult: @escaping (String) -> Void
    ) async throws -> String {
        let modelManager = await ModelManager.shared
        guard await modelManager.state.isReady else {
            throw TranscriptionError.modelNotReady
        }

        // Get language setting - same logic as transcribe(audioURL:)
        let language = settingsService.settings.language.rawValue
        let languageCode: String? = language.isEmpty ? nil : language

        let result = try await modelManager.transcribeStreaming(
            audioStream: audioStream,
            language: languageCode,
            onPartialResult: { partial in
                // Filter out hallucinations from partial results
                if !self.isHallucination(partial) {
                    onPartialResult(partial)
                }
            }
        )

        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Same post-processing as a recorded file
        return await postProcess(trimmedResult)
    }

    func transcribe(audioURL: URL) async throws -> String {
        let startedAt = LatencyLog.now()
        lastTimings = StageTimings()
        // Check a model is ready: Whisper, or Audar for Arabic/auto
        let modelManager = await ModelManager.shared
        let audarManager = await AudarModelManager.shared
        let whisperReady = await modelManager.state.isReady
        let audarUsable = await audarManager.isUsable
        guard whisperReady || audarUsable else {
            throw TranscriptionError.modelNotReady
        }

        // Check file exists
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriptionError.fileNotFound
        }

        // Convert audio to whisper format (16kHz mono PCM)
        let samples: [Float]
        let conversionStart = LatencyLog.now()
        do {
            samples = try await AudioConverter.convertToWhisperSamples(url: audioURL)
        } catch {
            throw TranscriptionError.audioConversionFailed(error.localizedDescription)
        }
        lastTimings.conversionMs = LatencyLog.log("stop.convert", since: conversionStart)

        // Check we have enough audio data
        let durationSeconds = Double(samples.count) / AudioConverter.targetSampleRate
        lastTimings.audioSeconds = durationSeconds
        guard durationSeconds >= 0.5 else {
            throw TranscriptionError.emptyTranscription
        }

        // Get language setting
        let language = settingsService.settings.language.rawValue
        let languageCode: String? = language.isEmpty ? nil : language

        // Pick the engine
        if !audarUsable {
            // Downloaded and switched on but not loaded yet: load it for next time, use Whisper now.
            await audarManager.loadIfConfigured()
        }
        let routeStart = LatencyLog.now()

        // Auto mode with both engines: Audar (Metal, GPU) starts transcribing as Arabic while
        // Whisper (Core ML, ANE/CPU) detects the language, instead of one after the other. The
        // Audar text is used only if detection routes to Audar; otherwise it is discarded (an
        // Audar run cannot be stopped midway, it just finishes in the background).
        let speculativeAudar: Task<(outcome: Result<String, Error>, ms: Double), Never>?
        if languageCode == nil && whisperReady && audarUsable {
            speculativeAudar = Task {
                let start = LatencyLog.now()
                do {
                    let text = try await audarManager.transcribe(samples: samples, language: "ar")
                    return (.success(text), LatencyLog.ms(since: start))
                } catch {
                    return (.failure(error), LatencyLog.ms(since: start))
                }
            }
        } else {
            speculativeAudar = nil
        }

        let route = await chooseEngine(
            samples: samples,
            languageCode: languageCode,
            whisperReady: whisperReady,
            audarUsable: audarUsable
        )
        lastEngine = route.engine
        lastRouteReason = route.reason
        if speculativeAudar != nil && route.engine == .whisper {
            lastRouteReason = route.reason + ", parallel Audar result discarded"
        }

        // Transcribe
        let result: String
        let asrStart = LatencyLog.now()
        var asrMs: Double?
        do {
            switch route.engine {
            case .audar:
                do {
                    if let speculativeAudar {
                        let run = await speculativeAudar.value
                        asrMs = run.ms
                        result = try run.outcome.get()
                    } else {
                        result = try await audarManager.transcribe(samples: samples, language: route.language)
                    }
                } catch {
                    // Any Audar failure falls back to Whisper with the user's language setting.
                    guard whisperReady else { throw error }
                    lastEngine = .whisper
                    lastRouteReason = "Audar failed (\(error.localizedDescription)), fell back to Whisper"
                    asrMs = nil // time the whole failed run + fallback
                    result = try await modelManager.transcribe(samples: samples, language: languageCode)
                }
            case .whisper:
                guard whisperReady else { throw TranscriptionError.modelNotReady }
                result = try await modelManager.transcribe(samples: samples, language: route.language)
            }
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.transcriptionFailed(error.localizedDescription)
        }

        // A parallel Audar run reports its own run time; everything else is timed from here.
        lastTimings.asrMs = asrMs ?? LatencyLog.ms(since: asrStart)
        lastTimings.routeAndAsrMs = LatencyLog.ms(since: routeStart)
        LatencyLog.log("stop.asr", ms: lastTimings.asrMs, engine: lastEngine?.rawValue ?? "none")
        LatencyLog.log("stop.route_and_asr", ms: lastTimings.routeAndAsrMs)

        let text = await postProcess(result)
        lastTimings.totalMs = LatencyLog.log("stop.transcribe_total", since: startedAt)
        return text
    }

    /// Raw engine text to the text that gets pasted: hallucination filter, bracket cleanup
    /// (sound tags removed, bracketed speech kept), speech cleanup (stutters, repeats, filler
    /// sounds), punctuation and list formatting. Returns "" for a hallucination.
    /// Internal (not private) so the DEBUG self-test runs exactly this path. Live typing runs
    /// it on each segment with `timed: false`, so the stop-path timings stay those of the stop.
    func postProcess(_ raw: String, timed: Bool = true) async -> String {
        let trimmedResult = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Filter out known hallucinations
        if isHallucination(trimmedResult) {
            return ""
        }

        let formattingStart = LatencyLog.now()

        // Sound tags out, bracketed words kept, before punctuation so the model sees every word
        var text = cleanTranscriptionArtifacts(trimmedResult)
        if text != trimmedResult && (text.isEmpty || isHallucination(text)) {
            return ""
        }

        // Stutters, repeated words/phrases and hesitation sounds
        if settingsService.settings.cleanupEnabled {
            text = SpeechCleanup.clean(text)
        }

        // Apply text formatting (punctuation + capitalization) if enabled
        let formattedResult = await textFormattingService.format(text: text)
        if timed {
            lastTimings.formattingMs = LatencyLog.log("stop.format", since: formattingStart)
        }
        return formattedResult
    }

    /// Finishes a recording that was transcribed while it was recorded (see
    /// `IncrementalTranscriber`): transcribes the last segment, joins all segments and applies
    /// the same post-processing as `transcribe(audioURL:)`. If the incremental path failed
    /// for any reason, transcribes `audioURL` the usual way instead, so nothing is lost.
    func transcribe(incremental session: IncrementalTranscriber, audioURL: URL, recordedDuration: TimeInterval) async throws -> String {
        let startedAt = LatencyLog.now()
        switch await finish(incremental: session, recordedDuration: recordedDuration) {
        case .fallback(let reason):
            return try await transcribe(audioURL: audioURL, afterIncrementalFallback: reason)

        case .transcript(let raw, _):
            let text = await postProcess(raw)
            lastTimings.totalMs = LatencyLog.log("stop.transcribe_total", since: startedAt)
            return text
        }
    }

    /// The first half of `transcribe(incremental:…)`: finishes the session and records its
    /// route and timings, without post-processing (live typing post-processes each segment
    /// itself). On `.fallback`, follow with `transcribe(audioURL:afterIncrementalFallback:)`.
    func finish(incremental session: IncrementalTranscriber, recordedDuration: TimeInterval) async -> IncrementalTranscriber.Outcome {
        let currentLanguage = settingsService.settings.language.rawValue
        let outcome: IncrementalTranscriber.Outcome
        if currentLanguage != session.languageSetting {
            await session.cancel()
            outcome = .fallback("language setting changed")
        } else {
            outcome = await session.finish(recordedDuration: recordedDuration)
        }

        switch outcome {
        case .fallback(let reason):
            LatencyLog.logger.info("incremental fallback: \(reason, privacy: .public)")

        case .transcript(_, let stats):
            lastTimings = StageTimings()
            lastEngine = .audar
            lastRouteReason = stats.reason
            lastTimings.audioSeconds = stats.audioSeconds
            lastTimings.detectionMs = stats.detectionMs
            lastTimings.asrMs = stats.finishMs
            lastTimings.routeAndAsrMs = stats.finishMs
            lastTimings.segments = stats.segments
            lastTimings.segmentMs = stats.segmentMs
            lastTimings.segmentSeconds = stats.segmentSeconds
            LatencyLog.log("stop.incremental_wait", ms: stats.finishMs)
            LatencyLog.log("stop.incremental_segments", count: stats.segments)
        }
        return outcome
    }

    /// The full-file path after an incremental session answered `.fallback(reason)`.
    func transcribe(audioURL: URL, afterIncrementalFallback reason: String) async throws -> String {
        let text = try await transcribe(audioURL: audioURL)
        lastRouteReason = "incremental fallback (\(reason)); " + (lastRouteReason ?? "")
        return text
    }

    // MARK: - Engine Routing

    private struct EngineRoute {
        let engine: SpeechEngine
        /// Language code handed to the engine (nil = the engine detects it).
        let language: String?
        let reason: String
    }

    /// Arabic goes to Audar (far better on dialects), everything else to Whisper.
    /// Without a usable Audar engine this is exactly the previous Whisper behaviour.
    private func chooseEngine(
        samples: [Float],
        languageCode: String?,
        whisperReady: Bool,
        audarUsable: Bool
    ) async -> EngineRoute {
        guard audarUsable else {
            return EngineRoute(engine: .whisper, language: languageCode, reason: "Audar not available")
        }

        switch languageCode {
        case "ar":
            return EngineRoute(engine: .audar, language: "ar", reason: "language set to Arabic")

        case nil:
            guard whisperReady else {
                return EngineRoute(engine: .audar, language: nil, reason: "auto, Whisper not ready")
            }
            do {
                let detectionStart = LatencyLog.now()
                let detection = try await ModelManager.shared.detectLanguage(samples: samples)
                lastTimings.detectionMs = LatencyLog.log("stop.detect", since: detectionStart)
                let summary = "auto, detected \(detection.language) (\(String(format: "%.2f", detection.confidence)))"
                if Self.arabicLikeLanguages.contains(detection.language) {
                    return EngineRoute(engine: .audar, language: "ar", reason: summary)
                }
                if detection.confidence < Self.minimumDetectionConfidence {
                    // Takes the parallel Audar run, which is prefilled as Arabic.
                    return EngineRoute(engine: .audar, language: "ar", reason: summary + ", low confidence")
                }
                return EngineRoute(engine: .whisper, language: detection.language, reason: summary)
            } catch {
                return EngineRoute(engine: .whisper, language: nil, reason: "auto, detection failed")
            }

        default:
            return EngineRoute(engine: .whisper, language: languageCode, reason: "language set to \(languageCode ?? "")")
        }
    }

    /// Check if the model is ready for transcription
    func isModelReady() async -> Bool {
        await ModelManager.shared.state.isReady
    }

    /// Ensure model is loaded and ready
    func ensureModelLoaded() async throws {
        let modelManager = await ModelManager.shared

        switch await modelManager.state {
        case .ready:
            return
        case .downloaded:
            try await modelManager.loadModel()
        case .notDownloaded, .error:
            throw TranscriptionError.modelNotReady
        case .downloading, .retrying, .loading:
            // Wait a bit and check again
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            try await ensureModelLoaded()
        }
    }
}
