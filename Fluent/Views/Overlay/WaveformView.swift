import SwiftUI
import Charts

// Compact waveform for minimal recording overlay
struct CompactWaveformView: View {
    let levels: [Float]
    let isRecording: Bool

    private let barCount = 20

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Array(displayLevels.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barColor(for: level))
                        .frame(
                            width: barWidth(in: geometry),
                            height: max(3, CGFloat(level) * geometry.size.height)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .animation(.easeOut(duration: 0.1), value: levels)
    }

    private var displayLevels: [Float] {
        if levels.count >= barCount {
            return sampleLevels(levels, targetCount: barCount)
        } else if levels.isEmpty {
            return Array(repeating: Float(0.1), count: barCount)
        } else {
            let padding = Array(repeating: Float(0.1), count: barCount - levels.count)
            return padding + levels
        }
    }

    private func sampleLevels(_ source: [Float], targetCount: Int) -> [Float] {
        let step = Double(source.count) / Double(targetCount)
        return (0..<targetCount).map { i in
            let index = min(Int(Double(i) * step), source.count - 1)
            return source[index]
        }
    }

    private func barWidth(in geometry: GeometryProxy) -> CGFloat {
        let totalSpacing = CGFloat(barCount - 1) * 2
        return (geometry.size.width - totalSpacing) / CGFloat(barCount)
    }

    private func barColor(for level: Float) -> Color {
        if isRecording {
            let intensity = min(1.0, Double(level) * 2)
            return Color(
                red: intensity,
                green: 0.2,
                blue: 1.0 - intensity * 0.5
            )
        } else {
            return Color.gray.opacity(0.5)
        }
    }
}

struct WaveformView: View {
    let levels: [Float]
    let isRecording: Bool

    private let barCount = 50

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Array(displayLevels.enumerated()), id: \.offset) { index, level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(for: level))
                        .frame(
                            width: barWidth(in: geometry),
                            height: max(4, CGFloat(level) * geometry.size.height)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .animation(.easeOut(duration: 0.1), value: levels)
    }

    private var displayLevels: [Float] {
        if levels.count >= barCount {
            // Sample the levels to fit our bar count
            return sampleLevels(levels, targetCount: barCount)
        } else if levels.isEmpty {
            // Show a flat line
            return Array(repeating: Float(0.05), count: barCount)
        } else {
            // Pad with low values on the left
            let padding = Array(repeating: Float(0.05), count: barCount - levels.count)
            return padding + levels
        }
    }

    private func sampleLevels(_ source: [Float], targetCount: Int) -> [Float] {
        let step = Double(source.count) / Double(targetCount)
        return (0..<targetCount).map { i in
            let index = min(Int(Double(i) * step), source.count - 1)
            return source[index]
        }
    }

    private func barWidth(in geometry: GeometryProxy) -> CGFloat {
        let totalSpacing = CGFloat(barCount - 1) * 2
        return (geometry.size.width - totalSpacing) / CGFloat(barCount)
    }

    private func barColor(for level: Float) -> Color {
        if isRecording {
            // Gradient from blue to red based on level
            let intensity = min(1.0, Double(level) * 2)
            return Color(
                red: intensity,
                green: 0.2,
                blue: 1.0 - intensity * 0.5
            )
        } else {
            return Color.gray.opacity(0.5)
        }
    }
}

// Alternative waveform using Swift Charts (for more advanced visualization)
struct ChartWaveformView: View {
    let levels: [Float]
    let isRecording: Bool

    var body: some View {
        Chart {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                BarMark(
                    x: .value("Sample", index),
                    y: .value("Level", level)
                )
                .foregroundStyle(isRecording ? Color.red.gradient : Color.gray.gradient)
                .cornerRadius(2)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...1)
    }
}

// Circular waveform visualization (alternative style)
struct CircularWaveformView: View {
    let level: Float
    let isRecording: Bool

    var body: some View {
        ZStack {
            // Outer ring
            Circle()
                .stroke(
                    isRecording ? Color.red.opacity(0.3) : Color.gray.opacity(0.3),
                    lineWidth: 4
                )

            // Animated inner ring
            Circle()
                .trim(from: 0, to: CGFloat(level))
                .stroke(
                    isRecording ? Color.red : Color.gray,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.1), value: level)

            // Mic icon
            Image(systemName: isRecording ? "mic.fill" : "mic")
                .font(.title2)
                .foregroundStyle(isRecording ? .red : .gray)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        WaveformView(
            levels: (0..<50).map { _ in Float.random(in: 0.1...0.8) },
            isRecording: true
        )
        .frame(height: 50)

        WaveformView(
            levels: [],
            isRecording: false
        )
        .frame(height: 50)

        CircularWaveformView(level: 0.6, isRecording: true)
            .frame(width: 60, height: 60)
    }
    .padding()
}
