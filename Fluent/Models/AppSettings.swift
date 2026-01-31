import Foundation

struct AppSettings: Codable, Equatable {
    // MARK: - Transcription Settings
    var language: TranscriptionLanguage = .auto
    var formatTextEnabled: Bool = true
    var formatListsEnabled: Bool = true

    // MARK: - Behavior Settings
    var autoPasteEnabled: Bool = true
    var showRecordingOverlay: Bool = true
    var launchAtLogin: Bool = false
    var removeFromDockOnClose: Bool = false

    // MARK: - Overlay Settings
    var overlayPosition: OverlayPosition = .bottomCenter

    // MARK: - Audio Settings
    var audioQuality: AudioQuality = .high

    enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable {
        case auto = ""
        case english = "en"
        case spanish = "es"
        case french = "fr"
        case german = "de"
        case italian = "it"
        case portuguese = "pt"
        case dutch = "nl"
        case russian = "ru"
        case japanese = "ja"
        case korean = "ko"
        case chinese = "zh"
        case arabic = "ar"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto: return "Auto-detect"
            case .english: return "English"
            case .spanish: return "Spanish"
            case .french: return "French"
            case .german: return "German"
            case .italian: return "Italian"
            case .portuguese: return "Portuguese"
            case .dutch: return "Dutch"
            case .russian: return "Russian"
            case .japanese: return "Japanese"
            case .korean: return "Korean"
            case .chinese: return "Chinese"
            case .arabic: return "Arabic"
            }
        }
    }

    enum OverlayPosition: String, Codable, CaseIterable, Identifiable {
        case topCenter = "top_center"
        case topLeft = "top_left"
        case topRight = "top_right"
        case bottomCenter = "bottom_center"
        case bottomLeft = "bottom_left"
        case bottomRight = "bottom_right"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .topCenter: return "Top Center"
            case .topLeft: return "Top Left"
            case .topRight: return "Top Right"
            case .bottomCenter: return "Bottom Center"
            case .bottomLeft: return "Bottom Left"
            case .bottomRight: return "Bottom Right"
            }
        }
    }

    enum AudioQuality: String, Codable, CaseIterable, Identifiable {
        case low = "low"
        case medium = "medium"
        case high = "high"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .low: return "Low (smaller files)"
            case .medium: return "Medium"
            case .high: return "High (best quality)"
            }
        }

        var sampleRate: Double {
            switch self {
            case .low: return 16000
            case .medium: return 22050
            case .high: return 44100
            }
        }

        var bitRate: Int {
            switch self {
            case .low: return 64000
            case .medium: return 128000
            case .high: return 192000
            }
        }
    }

    static var `default`: AppSettings {
        AppSettings()
    }
}
