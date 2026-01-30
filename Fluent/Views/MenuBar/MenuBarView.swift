import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Status Header
            VStack(spacing: 8) {
                HStack {
                    Circle()
                        .fill(appState.isRecording ? Color.red : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)

                    Text(statusText)
                        .font(.headline)

                    Spacer()

                    if appState.isRecording {
                        Text(formatDuration(appState.recordingDuration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                // Mini waveform when recording
                if appState.isRecording {
                    MiniWaveformView(levels: appState.audioService.audioLevels)
                        .frame(height: 24)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Quick Actions
            VStack(spacing: 0) {
                MenuBarButton(
                    title: appState.isRecording ? "Stop Recording" : "Start Recording",
                    icon: appState.isRecording ? "stop.fill" : "mic.fill",
                    shortcut: "fn",
                    isDestructive: appState.isRecording
                ) {
                    appState.toggleRecording()
                }

                if appState.isRecording {
                    MenuBarButton(
                        title: "Cancel Recording",
                        icon: "xmark",
                        shortcut: "esc"
                    ) {
                        appState.cancelRecording()
                    }
                }

                if appState.lastTranscription != nil {
                    MenuBarButton(
                        title: "Paste Last Transcript",
                        icon: "doc.on.clipboard",
                        shortcut: "⌥⇧V"
                    ) {
                        appState.pasteLastTranscript()
                    }
                }

                Divider()
                    .padding(.vertical, 4)

                MenuBarButton(
                    title: "Open Fluent",
                    icon: "rectangle.on.rectangle",
                    shortcut: "^O"
                ) {
                    appState.openMainWindow()
                }

                MenuBarButton(
                    title: "History",
                    icon: "clock"
                ) {
                    appState.selectedSidebarItem = .history
                    appState.openMainWindow()
                }

                MenuBarButton(
                    title: "Settings",
                    icon: "gear"
                ) {
                    appState.selectedSidebarItem = .settings
                    appState.openMainWindow()
                }

                Divider()
                    .padding(.vertical, 4)

                MenuBarButton(
                    title: "Quit Fluent",
                    icon: "power",
                    shortcut: "^Q"
                ) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 260)
    }

    private var statusText: String {
        if appState.isRecording {
            return "Recording..."
        } else if appState.isTranscribing {
            return "Transcribing..."
        } else {
            return "Ready"
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct MenuBarButton: View {
    let title: String
    let icon: String
    var shortcut: String? = nil
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 20)
                    .foregroundStyle(isDestructive ? .red : .primary)

                Text(title)
                    .foregroundStyle(isDestructive ? .red : .primary)

                Spacer()

                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovering ? Color.accentColor.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

struct MiniWaveformView: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Array(displayLevels.enumerated()), id: \.offset) { index, level in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.red.opacity(0.8))
                        .frame(width: 3, height: max(2, CGFloat(level) * geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var displayLevels: [Float] {
        // Take last 30 samples, or pad with zeros
        let targetCount = 30
        if levels.count >= targetCount {
            return Array(levels.suffix(targetCount))
        } else {
            return Array(repeating: Float(0), count: targetCount - levels.count) + levels
        }
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
