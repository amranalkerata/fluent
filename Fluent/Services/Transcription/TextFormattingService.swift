import Foundation

/// Service for formatting transcribed text with punctuation and capitalization
/// Uses the bundled multilingual Core ML punctuation model for every language
class TextFormattingService {
    private let settingsService = SettingsService.shared
    private let listFormattingService = ListFormattingService()

    /// Format text with punctuation and proper capitalization
    /// - Parameter text: Raw transcription text
    /// - Returns: Formatted text with punctuation and capitalization, or original text on failure
    func format(text: String) async -> String {
        // Check if formatting is enabled
        guard settingsService.settings.formatTextEnabled else {
            return text
        }
        return await formatIgnoringSetting(text: text)
    }

    /// Format text regardless of the "Format Text" setting
    /// (used by `format(text:)` and the DEBUG self-test)
    func formatIgnoringSetting(text: String) async -> String {
        let modelManager = await PunctuationModelManager.shared

        // Load the bundled model on first use
        if await !modelManager.state.isReady {
            try? await modelManager.loadModel()
        }

        // Model failed to load - formatting is non-critical, apply list formatting only
        guard await modelManager.state.isReady else {
            return listFormattingService.format(text: text)
        }

        do {
            var formatted = try await modelManager.infer(text: text)
            formatted = formatted.isEmpty ? text : formatted

            // Always apply list formatting (after punctuation)
            return listFormattingService.format(text: formatted)
        } catch {
            // Formatting is non-critical - silently return original text
            // Still apply list formatting even if punctuation fails
            return listFormattingService.format(text: text)
        }
    }

    /// Check if the punctuation model is ready for formatting
    func isModelReady() async -> Bool {
        await PunctuationModelManager.shared.state.isReady
    }

    /// Ensure punctuation model is loaded (call lazily on first format request)
    func ensureModelLoaded() async {
        let modelManager = await PunctuationModelManager.shared
        let state = await modelManager.state

        switch state {
        case .ready, .loading:
            return
        case .notLoaded, .error:
            try? await modelManager.loadModel()
        }
    }
}
