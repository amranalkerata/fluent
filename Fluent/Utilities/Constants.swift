import Foundation

enum Constants {
    static let appName = "Fluent"
    static let bundleIdentifier = "com.fluent.app"

    enum Model {
        // WhisperKit Core ML model (~150MB)
        static let modelName = "small"
        static let modelRepo = "argmaxinc/whisperkit-coreml"
        static let expectedSize: Int64 = 150_000_000 // ~150MB
    }

    enum Audio {
        static let defaultSampleRate: Double = 44100
        static let defaultChannels: UInt32 = 1
        static let bufferSize: UInt32 = 4096  // Larger buffer for streaming

        // WhisperKit requirements (same as whisper.cpp)
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
