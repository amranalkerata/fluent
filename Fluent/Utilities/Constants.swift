import Foundation

enum Constants {
    static let appName = "Fluent"
    static let bundleIdentifier = "com.fluent.app"

    enum API {
        static let whisperEndpoint = "https://api.openai.com/v1/audio/transcriptions"
        static let chatEndpoint = "https://api.openai.com/v1/chat/completions"
        static let maxAudioFileSize: Int64 = 25 * 1024 * 1024 // 25MB
    }

    enum Audio {
        static let defaultSampleRate: Double = 44100
        static let defaultChannels: UInt32 = 1
        static let bufferSize: UInt32 = 1024
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
