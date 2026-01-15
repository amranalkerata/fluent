import SwiftUI

struct RecordingOverlayView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var audioService: AudioRecordingService

    var body: some View {
        HStack(spacing: FluentSpacing.sm) {
            // Pulsing recording indicator
            Circle()
                .fill(FluentColors.error)
                .frame(width: 8, height: 8)
                .modifier(PulsingModifier(isAnimating: appState.isRecording))

            // Timer
            Text(formatDuration(audioService.recordingDuration))
                .font(.Fluent.headlineSmall)
                .foregroundStyle(FluentColors.textPrimary)
                .monospacedDigit()

            // Compact waveform visualization
            CompactWaveformView(levels: audioService.audioLevels, isRecording: appState.isRecording)
                .frame(width: 80, height: 24)
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

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
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
