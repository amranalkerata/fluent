import SwiftUI

struct RecordingOverlayView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: FluentSpacing.xs) {
            if appState.isShowingLoadingOverlay {
                // Model loading state - shown when user presses hotkey before model is ready
                HStack(spacing: FluentSpacing.sm) {
                    ProgressView()
                        .scaleEffect(0.8)

                    Text(appState.transcriptionError ?? "Loading model, please wait...")
                        .font(.Fluent.caption)
                        .foregroundStyle(FluentColors.textSecondary)
                        .lineLimit(1)
                }
                .fixedSize()
            } else if appState.isRecording {
                // Recording UI
                RecordingMeterRow()

                // Real-time transcription preview
                if let partial = appState.partialTranscription, !partial.isEmpty {
                    Text(partial)
                        .font(.Fluent.caption)
                        .foregroundStyle(FluentColors.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.head)
                        .frame(maxWidth: 250)
                        .multilineTextAlignment(.center)
                        .animation(.easeInOut(duration: 0.15), value: partial)
                }
            } else if appState.isTranscribing {
                // Processing UI
                HStack(spacing: FluentSpacing.sm) {
                    ProgressView()
                        .scaleEffect(0.8)

                    Text("Finalizing...")
                        .font(.Fluent.caption)
                        .foregroundStyle(FluentColors.textSecondary)
                }
                .fixedSize()
            } else if let error = appState.transcriptionError {
                // Error UI - shows briefly before overlay hides
                HStack(spacing: FluentSpacing.sm) {
                    Image(systemName: "waveform.slash")
                        .foregroundStyle(FluentColors.textSecondary)

                    Text(error)
                        .font(.Fluent.caption)
                        .foregroundStyle(FluentColors.textSecondary)
                        .lineLimit(1)
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, FluentSpacing.md)
        .padding(.vertical, FluentSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: FluentRadius.lg)
                .fill(.ultraThinMaterial)
        )
        .fluentShadow(.medium)
        .overlay(
            RoundedRectangle(cornerRadius: FluentRadius.lg)
                .stroke(FluentColors.borderLight, lineWidth: 1)
        )
    }
}

/// Dot, clock and waveform. It is the only part of the overlay that changes many times a
/// second, so it alone observes the audio service and the rest of the pill is not redrawn.
private struct RecordingMeterRow: View {
    @EnvironmentObject var audioService: AudioRecordingService

    var body: some View {
        HStack(spacing: FluentSpacing.sm) {
            Circle()
                .fill(FluentColors.error)
                .frame(width: 8, height: 8)
                .modifier(PulsingModifier(isAnimating: true))

            Text(RecordingDurationText.format(audioService.recordingDuration, showsTenths: true))
                .font(.Fluent.headlineSmall)
                .foregroundStyle(FluentColors.textPrimary)
                .monospacedDigit()

            CompactWaveformView(levels: audioService.audioLevels, isRecording: audioService.isRecording)
                .frame(width: 80, height: 24)
        }
        // Never let the row be squeezed: a Text's minimum width is zero, so any tighter
        // proposal hides the clock entirely while the fixed-width waveform survives.
        .fixedSize()
    }
}

/// The recording clock for views outside the overlay (menu bar, sidebar). Observes the audio
/// service directly, so the clock ticking does not redraw everything that observes `AppState`.
struct RecordingDurationText: View {
    @ObservedObject var audioService: AudioRecordingService
    var showsTenths = true

    var body: some View {
        Text(Self.format(audioService.recordingDuration, showsTenths: showsTenths))
    }

    static func format(_ duration: TimeInterval, showsTenths: Bool) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        guard showsTenths else { return String(format: "%d:%02d", minutes, seconds) }
        let tenths = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}

struct PulsingModifier: ViewModifier {
    let isAnimating: Bool
    @State private var opacity: Double = 1.0

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .onAppear {
                if isAnimating {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        opacity = 0.3
                    }
                }
            }
            .onChange(of: isAnimating) { _, newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        opacity = 0.3
                    }
                } else {
                    withAnimation {
                        opacity = 1.0
                    }
                }
            }
    }
}

#Preview {
    RecordingOverlayView()
        .environmentObject(AppState())
        .environmentObject(AudioRecordingService())
        .padding()
        .background(Color.gray)
}
