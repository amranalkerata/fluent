import Foundation

enum Constants {
    static let appName = "Fluent"
    static let bundleIdentifier = "com.fluent.app"

    enum Model {
        // Whisper base model from HuggingFace (~142MB)
        static let downloadURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
        static let fileName = "ggml-base.bin"
        static let expectedSize: Int64 = 142_000_000 // ~142MB
    }

    enum Audio {
        static let defaultSampleRate: Double = 44100
        static let defaultChannels: UInt32 = 1
        static let bufferSize: UInt32 = 1024

        // whisper.cpp requirements
        static let whisperSampleRate: Double = 16000
        static let whisperChannels: UInt32 = 1
    }

    enum UI {
        static let overlayWidth: CGFloat = 320
        static let overlayHeight: CGFloat = 140
        static let mainWindowMinWidth: CGFloat = 700
        static let mainWindowMinHeight: CGFloat = 450
        static let sidebarMinWidth: CGFloat = 180
    }

    enum Defaults {
        static let maxWaveformSamples = 100
        static let fnKeyDebounceInterval: TimeInterval = 0.3
    }
}
