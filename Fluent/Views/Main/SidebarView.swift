import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach([SidebarItem.home, .history]) { item in
                    NavigationLink(value: item) {
                        Label(item.rawValue, systemImage: item.icon)
                    }
                }
            }

            Section {
                ForEach([SidebarItem.shortcuts, .settings]) { item in
                    NavigationLink(value: item) {
                        Label(item.rawValue, systemImage: item.icon)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: FluentSpacing.sm) {
                FluentDivider()
                RecordingStatusBar()
                    .padding(.horizontal, FluentSpacing.md)
                    .padding(.bottom, FluentSpacing.sm)
            }
        }
    }
}

struct RecordingStatusBar: View {
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: FluentSpacing.sm) {
            // Recording indicator
            Circle()
                .fill(appState.isRecording ? FluentColors.error : FluentColors.textTertiary.opacity(0.3))
                .frame(width: 8, height: 8)
                .modifier(PulsingModifier(isAnimating: appState.isRecording))

            // Status text
            Group {
                if appState.isRecording {
                    Text(formatDuration(appState.recordingDuration))
                        .font(.Fluent.monoSmall)
                } else if appState.isTranscribing {
                    Text("Transcribing...")
                        .font(.Fluent.caption)
                } else {
                    Text("Ready")
                        .font(.Fluent.caption)
                }
            }
            .foregroundStyle(FluentColors.textSecondary)

            Spacer()

            // Record button
            Button {
                appState.toggleRecording()
            } label: {
                Image(systemName: appState.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title2)
                    .foregroundStyle(appState.isRecording ? FluentColors.error : FluentColors.primary)
                    .scaleEffect(isHovered ? 1.1 : 1.0)
                    .animation(FluentAnimation.spring, value: isHovered)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(appState.isRecording ? "Stop Recording" : "Start Recording")
        }
        .padding(.vertical, FluentSpacing.sm)
        .padding(.horizontal, FluentSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: FluentRadius.md)
                .fill(FluentColors.surface)
        )
        .fluentShadow(.low)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let tenths = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}

#Preview {
    NavigationSplitView {
        SidebarView(selection: .constant(.home))
            .environmentObject(AppState())
    } detail: {
        Text("Detail")
    }
}
