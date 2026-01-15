import Foundation
import SwiftData

@Model
final class Recording {
    var id: UUID
    var createdAt: Date
    var duration: TimeInterval
    var audioFileName: String?
    var originalTranscription: String?
    var enhancedTranscription: String?
    var isPasted: Bool
    var targetApplication: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        audioFileName: String? = nil,
        originalTranscription: String? = nil,
        enhancedTranscription: String? = nil,
        isPasted: Bool = false,
        targetApplication: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.originalTranscription = originalTranscription
        self.enhancedTranscription = enhancedTranscription
        self.isPasted = isPasted
        self.targetApplication = targetApplication
    }

    // Get the best available transcription (enhanced if available, otherwise original)
    var transcription: String? {
        enhancedTranscription ?? originalTranscription
    }

    // Format duration as MM:SS
    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // Get audio file URL
    var audioFileURL: URL? {
        guard let fileName = audioFileName else { return nil }
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("Fluent").appendingPathComponent(fileName)
    }

    // Formatted date for display
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }

    // Relative date (e.g., "Today", "Yesterday", "2 days ago")
    var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }
}

// MARK: - Sample Data for Previews

extension Recording {
    static var sampleRecordings: [Recording] {
        [
            Recording(
                createdAt: Date(),
                duration: 45.5,
                originalTranscription: "This is a test transcription from earlier today.",
                enhancedTranscription: "This is a test transcription from earlier today.",
                isPasted: true,
                targetApplication: "Notes"
            ),
            Recording(
                createdAt: Date().addingTimeInterval(-86400),
                duration: 120.0,
                originalTranscription: "Yesterday's meeting notes about the project timeline and deliverables.",
                enhancedTranscription: "Yesterday's meeting notes about the project timeline and deliverables.",
                isPasted: true,
                targetApplication: "TextEdit"
            ),
            Recording(
                createdAt: Date().addingTimeInterval(-172800),
                duration: 30.0,
                originalTranscription: "Quick voice note reminder to check emails.",
                isPasted: false
            )
        ]
    }
}
