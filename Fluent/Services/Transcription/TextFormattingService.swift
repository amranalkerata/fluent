import Foundation

/// Service for formatting transcribed text with punctuation and capitalization
/// Uses an ONNX-based punctuation model for ML inference
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

        // Check if model is downloaded and ready
        let modelManager = await PunctuationModelManager.shared

        // If model not downloaded (user deleted it), gracefully degrade
        guard await modelManager.isModelDownloaded else {
            // Apply list formatting only, skip punctuation
            return listFormattingService.format(text: text)
        }

        // If model downloaded but not loaded, try to load it
        if await !modelManager.state.isReady {
            try? await modelManager.loadModel()
        }

        // Check again if model is ready after potential load
        guard await modelManager.state.isReady else {
            // Model not ready - silently return with list formatting only
            return listFormattingService.format(text: text)
        }

        do {
            var formatted = try await modelManager.infer(text: text)
            formatted = formatted.isEmpty ? text : formatted

            // Always apply list formatting (after punctuation)
            formatted = listFormattingService.format(text: formatted)

            return formatted
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

    /// Check if the punctuation model is downloaded
    func isModelDownloaded() async -> Bool {
        await PunctuationModelManager.shared.isModelDownloaded
    }

    /// Ensure punctuation model is loaded (call lazily on first format request)
    func ensureModelLoaded() async {
        let modelManager = await PunctuationModelManager.shared
        let state = await modelManager.state

        switch state {
        case .ready:
            return
        case .downloaded:
            // Model is downloaded - load it into memory
            try? await modelManager.loadModel()
        case .notDownloaded, .downloading, .retrying, .loading, .error:
            // Model not available or already loading - don't block
            return
        }
    }
}
