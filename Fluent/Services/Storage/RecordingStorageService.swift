import Foundation
import SwiftData

@MainActor
final class RecordingStorageService {

    private let modelContext: ModelContext
    private let maxHistoryCount = 100

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Saves a new recording and enforces the history limit
    func saveRecording(
        duration: TimeInterval,
        audioFileName: String?,
        originalTranscription: String?,
        enhancedTranscription: String?,
        isPasted: Bool,
        targetApplication: String?
    ) throws {
        let recording = Recording(
            createdAt: Date(),
            duration: duration,
            audioFileName: audioFileName,
            originalTranscription: originalTranscription,
            enhancedTranscription: enhancedTranscription,
            isPasted: isPasted,
            targetApplication: targetApplication
        )

        modelContext.insert(recording)

        // Enforce history limit after inserting
        try enforceHistoryLimit()
    }

    /// Deletes oldest recordings if count exceeds the maximum limit
    private func enforceHistoryLimit() throws {
        // Fetch all recordings sorted by createdAt descending (newest first)
        var descriptor = FetchDescriptor<Recording>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        let allRecordings = try modelContext.fetch(descriptor)

        // If we're over the limit, delete the oldest ones
        if allRecordings.count > maxHistoryCount {
            let recordingsToDelete = allRecordings.suffix(from: maxHistoryCount)

            for recording in recordingsToDelete {
                deleteRecordingWithFile(recording)
            }
        }
    }

    /// Deletes a recording and its associated audio file
    func deleteRecordingWithFile(_ recording: Recording) {
        // Delete audio file first
        if let audioURL = recording.audioFileURL {
            try? FileManager.default.removeItem(at: audioURL)
        }

        // Delete from database
        modelContext.delete(recording)
    }
}
