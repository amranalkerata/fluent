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

class TranscriptionService {
    private let settingsService = SettingsService.shared
    private let textFormattingService = TextFormattingService()

    // Known Whisper hallucination phrases (lowercased, without brackets for comparison)
    // The isHallucination() method strips brackets/parentheses before comparing
    private let hallucinationPhrases: Set<String> = [
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
        // 4 or more consecutive identical characters
        let pattern = "(.)\\1{3,}"
        return text.range(of: pattern, options: .regularExpression) != nil
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

    /// Checks if the transcription is likely a Whisper hallucination
    private func isHallucination(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Reject if entire text is wrapped in brackets or parentheses
        //    This catches ALL audio markers: [music], (click), [Light music], etc.
        //    Pattern-based detection beats blocklists because Whisper generates endless variations
        if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) ||
           (trimmed.hasPrefix("(") && trimmed.hasSuffix(")")) {
            return true
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

        return hallucinationPhrases.contains(normalized)
    }

    /// Removes transcription artifacts like [inaudible], [BLANK_AUDIO], (click), etc.
    /// These are Whisper-generated markers that shouldn't appear in the final output
    private func cleanTranscriptionArtifacts(_ text: String) -> String {
        var cleaned = text

        // Remove content in square brackets: [inaudible], [BLANK_AUDIO], [music], etc.
        cleaned = cleaned.replacingOccurrences(
            of: "\\[[^\\]]*\\]",
            with: "",
            options: .regularExpression
        )

        // Remove content in parentheses: (applause), (click), (inaudible), etc.
        cleaned = cleaned.replacingOccurrences(
            of: "\\([^)]*\\)",
            with: "",
            options: .regularExpression
        )

        // Clean up multiple spaces left behind
        cleaned = cleaned.replacingOccurrences(
            of: "\\s{2,}",
            with: " ",
            options: .regularExpression
        )

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
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

        // Filter out hallucinations from final result
        if isHallucination(trimmedResult) {
            return ""
        }

        // Apply text formatting (punctuation + capitalization) if enabled
        let formattedResult = await textFormattingService.format(text: trimmedResult)

        // Remove any remaining transcription artifacts
        let cleanedResult = cleanTranscriptionArtifacts(formattedResult)

        return cleanedResult
    }

    func transcribe(audioURL: URL) async throws -> String {
        // Check model is ready
        let modelManager = await ModelManager.shared
        guard await modelManager.state.isReady else {
            throw TranscriptionError.modelNotReady
        }

        // Check file exists
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriptionError.fileNotFound
        }

        // Convert audio to whisper format (16kHz mono PCM)
        let samples: [Float]
        do {
            samples = try await AudioConverter.convertToWhisperSamples(url: audioURL)
        } catch {
            throw TranscriptionError.audioConversionFailed(error.localizedDescription)
        }

        // Check we have enough audio data
        let durationSeconds = Double(samples.count) / AudioConverter.targetSampleRate
        guard durationSeconds >= 0.5 else {
            throw TranscriptionError.emptyTranscription
        }

        // Get language setting
        let language = settingsService.settings.language.rawValue
        let languageCode: String? = language.isEmpty ? nil : language

        // Transcribe
        let result: String
        do {
            result = try await modelManager.transcribe(samples: samples, language: languageCode)
        } catch {
            throw TranscriptionError.transcriptionFailed(error.localizedDescription)
        }

        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Filter out known hallucinations
        if isHallucination(trimmedResult) {
            return ""
        }

        // Apply text formatting (punctuation + capitalization) if enabled
        let formattedResult = await textFormattingService.format(text: trimmedResult)

        // Remove any remaining transcription artifacts
        let cleanedResult = cleanTranscriptionArtifacts(formattedResult)

        return cleanedResult
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
