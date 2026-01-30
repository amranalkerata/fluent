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

    // Known Whisper hallucination phrases (lowercased for comparison)
    private let hallucinationPhrases: Set<String> = [
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
        "...",
        "…",
        "you",
        "[music]",
        "[applause]",
        "(music)",
        "(applause)",
        "[silence]",
        "(silence)"
    ]

    /// Checks if the transcription is likely a Whisper hallucination
    private func isHallucination(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Check for known hallucination phrases or very short text
        return hallucinationPhrases.contains(normalized) || normalized.count < 2
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

        return trimmedResult
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
        case .downloading, .loading:
            // Wait a bit and check again
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            try await ensureModelLoaded()
        }
    }
}
