import SwiftUI
import SwiftData

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]

    @State private var isRecordButtonHovered = false
    @State private var isRecordButtonPressed = false

    var body: some View {
        ScrollView {
            VStack(spacing: FluentSpacing.sectionSpacing) {
                // Compact Stats Bar
                statsBar
                    .fluentAppear(delay: 0)

                // Prominent Record Button
                recordButtonSection
                    .fluentAppear(delay: 0.05)

                // Recent Activity
                recentActivitySection
                    .fluentAppear(delay: 0.1)
            }
            .padding(FluentSpacing.pagePadding)
        }
        .background(FluentColors.background)
        .navigationTitle("Home")
    }

    // MARK: - Stats Cards

    private var statsBar: some View {
        HStack(spacing: FluentSpacing.md) {
            StatCard(
                icon: "waveform",
                value: "\(recordings.count)",
                label: "Recordings",
                color: FluentColors.primary
            )

            StatCard(
                icon: "calendar",
                value: "\(todayRecordingsCount)",
                label: "Today",
                color: FluentColors.success
            )

            StatCard(
                icon: "clock",
                value: formattedTotalDuration,
                label: "Total Time",
                color: FluentColors.warning
            )
        }
    }

    // MARK: - Record Button Section

    private var recordButtonSection: some View {
        VStack(spacing: FluentSpacing.lg) {
            Button {
                appState.toggleRecording()
            } label: {
                VStack(spacing: FluentSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(
                                appState.isModelLoading
                                    ? FluentColors.primary.opacity(0.3).gradient
                                    : appState.isRecording
                                        ? FluentColors.error.gradient
                                        : FluentColors.primary.gradient
                            )
                            .frame(width: 80, height: 80)

                        if appState.isModelLoading {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(1.2)
                                .tint(.white)
                        } else {
                            Image(systemName: appState.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.white)
                        }
                    }

                    Text(appState.isModelLoading ? "Loading Model..." : appState.isRecording ? "Stop Recording" : "Start Recording")
                        .font(.Fluent.titleMedium)
                        .foregroundStyle(appState.isModelLoading ? FluentColors.textSecondary : FluentColors.textPrimary)
                }
                .padding(FluentSpacing.xl)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: FluentRadius.xl)
                        .fill(FluentColors.surface)
                )
                .fluentShadow(appState.isModelLoading ? .low : (isRecordButtonHovered ? .medium : .low))
                .scaleEffect(appState.isModelLoading ? 1.0 : (isRecordButtonPressed ? 0.97 : (isRecordButtonHovered ? 1.01 : 1.0)))
            }
            .buttonStyle(.plain)
            .disabled(appState.isModelLoading)
            .onHover { hovering in
                if !appState.isModelLoading {
                    isRecordButtonHovered = hovering
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !appState.isModelLoading {
                            isRecordButtonPressed = true
                        }
                    }
                    .onEnded { _ in isRecordButtonPressed = false }
            )
            .animation(FluentAnimation.spring, value: isRecordButtonHovered)
            .animation(FluentAnimation.spring, value: isRecordButtonPressed)
            .animation(FluentAnimation.normal, value: appState.isModelLoading)

            Text(appState.isModelLoading ? "Please wait, preparing transcription..." : "Press Fn or ⌥Space to record")
                .font(.Fluent.caption)
                .foregroundStyle(FluentColors.textTertiary)
                .animation(FluentAnimation.normal, value: appState.isModelLoading)
        }
        .padding(.vertical, FluentSpacing.lg)
    }

    private var recentActivitySection: some View {
        FluentSection(
            "Recent Activity",
            icon: "clock",
            action: recordings.isEmpty ? nil : { appState.selectedSidebarItem = .history },
            actionLabel: recordings.isEmpty ? nil : "View All"
        ) {
            if recordings.isEmpty {
                FluentEmptyState(
                    icon: "waveform.path.ecg",
                    title: "No recordings yet",
                    message: "Press Fn or Option+Space to start recording"
                )
            } else {
                VStack(spacing: FluentSpacing.sm) {
                    ForEach(recordings.prefix(3)) { recording in
                        FluentRecordingRow(
                            title: recording.transcription ?? "Untranscribed",
                            subtitle: recording.relativeDate,
                            duration: recording.formattedDuration
                        )
                    }
                }
            }
        }
    }

    private var todayRecordingsCount: Int {
        recordings.filter { Calendar.current.isDateInToday($0.createdAt) }.count
    }

    private var formattedTotalDuration: String {
        let total = recordings.reduce(0) { $0 + $1.duration }
        let minutes = Int(total) / 60
        if minutes < 60 {
            return "\(minutes)m"
        } else {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            return "\(hours)h \(remainingMinutes)m"
        }
    }
}

// MARK: - Stat Card Component

private struct StatCard: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: FluentSpacing.md) {
            // Icon with colored background circle
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 48, height: 48)

                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(color.gradient)
            }

            // Value
            Text(value)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(FluentColors.textPrimary)

            // Label
            Text(label)
                .font(.Fluent.bodySmall)
                .foregroundStyle(FluentColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FluentSpacing.lg)
        .padding(.horizontal, FluentSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: FluentRadius.lg)
                .fill(FluentColors.surface)
        )
        .fluentShadow(isHovered ? .medium : .low)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(FluentAnimation.fast, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
        .modelContainer(for: [Recording.self], inMemory: true)
}
