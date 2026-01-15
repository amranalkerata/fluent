import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @State private var searchText = ""
    @State private var selectedRecording: Recording?

    var filteredRecordings: [Recording] {
        if searchText.isEmpty {
            return recordings
        }
        return recordings.filter { recording in
            recording.transcription?.localizedCaseInsensitiveContains(searchText) ?? false
        }
    }

    var groupedRecordings: [(String, [Recording])] {
        let grouped = Dictionary(grouping: filteredRecordings) { recording -> String in
            if Calendar.current.isDateInToday(recording.createdAt) {
                return "Today"
            } else if Calendar.current.isDateInYesterday(recording.createdAt) {
                return "Yesterday"
            } else if Calendar.current.isDate(recording.createdAt, equalTo: Date(), toGranularity: .weekOfYear) {
                return "This Week"
            } else if Calendar.current.isDate(recording.createdAt, equalTo: Date(), toGranularity: .month) {
                return "This Month"
            } else {
                return "Older"
            }
        }

        let order = ["Today", "Yesterday", "This Week", "This Month", "Older"]
        return order.compactMap { key in
            if let recordings = grouped[key], !recordings.isEmpty {
                return (key, recordings)
            }
            return nil
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left panel - Recording list
            VStack(spacing: 0) {
                if recordings.isEmpty {
                    EmptyHistoryView()
                } else {
                    List(selection: $selectedRecording) {
                        ForEach(groupedRecordings, id: \.0) { section, sectionRecordings in
                            Section(section) {
                                ForEach(sectionRecordings) { recording in
                                    RecordingRow(recording: recording)
                                        .tag(recording)
                                        .contextMenu {
                                            Button("Copy Transcription") {
                                                if let text = recording.transcription {
                                                    NSPasteboard.general.clearContents()
                                                    NSPasteboard.general.setString(text, forType: .string)
                                                }
                                            }
                                            .disabled(recording.transcription == nil)

                                            Divider()

                                            Button("Delete", role: .destructive) {
                                                deleteRecording(recording)
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search transcriptions")
                }
            }
            .frame(width: 320)
            .background(FluentColors.surface)

            Divider()

            // Right panel - Detail view
            if let recording = selectedRecording {
                RecordingDetailView(recording: recording)
            } else {
                VStack(spacing: FluentSpacing.md) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 40))
                        .foregroundStyle(FluentColors.textTertiary)
                    Text("Select a recording")
                        .font(.Fluent.bodyMedium)
                        .foregroundStyle(FluentColors.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("History")
    }

    private func deleteRecording(_ recording: Recording) {
        // Delete audio file if exists
        if let url = recording.audioFileURL {
            try? FileManager.default.removeItem(at: url)
        }

        // Delete from database
        modelContext.delete(recording)

        // Clear selection if deleted
        if selectedRecording == recording {
            selectedRecording = nil
        }
    }
}

struct EmptyHistoryView: View {
    var body: some View {
        VStack(spacing: FluentSpacing.lg) {
            Image(systemName: "clock")
                .font(.system(size: 48))
                .foregroundStyle(FluentColors.textTertiary)

            VStack(spacing: FluentSpacing.xs) {
                Text("No recordings yet")
                    .font(.Fluent.headlineMedium)

                Text("Your transcription history will appear here")
                    .font(.Fluent.bodyMedium)
                    .foregroundStyle(FluentColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecordingRow: View {
    let recording: Recording
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: FluentSpacing.xs) {
            HStack {
                Text(recording.transcription?.prefix(50).description ?? "Untranscribed")
                    .lineLimit(1)
                    .font(.Fluent.bodyLarge)

                Spacer()

                Text(recording.formattedDuration)
                    .font(.Fluent.monoSmall)
                    .foregroundStyle(FluentColors.textSecondary)
            }

            HStack(spacing: FluentSpacing.sm) {
                Text(recording.formattedDate)
                    .font(.Fluent.caption)
                    .foregroundStyle(FluentColors.textSecondary)

                if let app = recording.targetApplication {
                    Text("Pasted to \(app)")
                        .font(.Fluent.caption)
                        .foregroundStyle(FluentColors.textTertiary)
                }
            }
        }
        .padding(.vertical, FluentSpacing.xs)
    }
}

struct RecordingDetailView: View {
    let recording: Recording
    @State private var showCopiedAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FluentSpacing.xl) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: FluentSpacing.xs) {
                        Text(recording.formattedDate)
                            .font(.Fluent.headlineSmall)

                        HStack(spacing: FluentSpacing.lg) {
                            Label(recording.formattedDuration, systemImage: "clock")
                            if let app = recording.targetApplication {
                                Label(app, systemImage: "app")
                            }
                        }
                        .font(.Fluent.bodyMedium)
                        .foregroundStyle(FluentColors.textSecondary)
                    }

                    Spacer()

                    FluentButton(
                        showCopiedAlert ? "Copied" : "Copy",
                        icon: showCopiedAlert ? "checkmark" : "doc.on.doc",
                        variant: .secondary
                    ) {
                        copyTranscription()
                    }
                    .disabled(recording.transcription == nil)
                }

                FluentDivider()

                // Transcription
                if let transcription = recording.transcription {
                    VStack(alignment: .leading, spacing: FluentSpacing.sm) {
                        Text("Transcription")
                            .font(.Fluent.headlineSmall)

                        Text(transcription)
                            .font(.Fluent.bodyLarge)
                            .textSelection(.enabled)
                            .padding(FluentSpacing.cardPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: FluentRadius.md)
                                    .fill(FluentColors.surfaceElevated)
                            )
                    }
                } else {
                    FluentEmptyState(
                        icon: "text.quote",
                        title: "No transcription",
                        message: "This recording hasn't been transcribed yet"
                    )
                }

                // Original vs Enhanced (if different)
                if let original = recording.originalTranscription,
                   let enhanced = recording.enhancedTranscription,
                   original != enhanced {
                    FluentDivider()

                    VStack(alignment: .leading, spacing: FluentSpacing.sm) {
                        HStack {
                            Text("Original Transcription")
                                .font(.Fluent.headlineSmall)

                            FluentBadge("Before AI", variant: .neutral)
                        }

                        Text(original)
                            .font(.Fluent.bodyLarge)
                            .foregroundStyle(FluentColors.textSecondary)
                            .textSelection(.enabled)
                            .padding(FluentSpacing.cardPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: FluentRadius.md)
                                    .fill(FluentColors.surfaceElevated.opacity(0.5))
                            )
                    }
                }
            }
            .padding(FluentSpacing.pagePadding)
        }
        .background(FluentColors.background)
    }

    private func copyTranscription() {
        guard let text = recording.transcription else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        withAnimation(FluentAnimation.fast) {
            showCopiedAlert = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(FluentAnimation.fast) {
                showCopiedAlert = false
            }
        }
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: [Recording.self], inMemory: true)
}
