import SwiftUI

// MARK: - Generic Card

struct FluentCard<Content: View>: View {
    let elevation: FluentElevation
    let radius: CGFloat
    let padding: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        elevation: FluentElevation = .low,
        radius: CGFloat = FluentRadius.lg,
        padding: CGFloat = FluentSpacing.cardPadding,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.elevation = elevation
        self.radius = radius
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(FluentColors.surface)
            )
            .fluentShadow(elevation)
    }
}

// MARK: - Stat Card

struct FluentStatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: FluentSpacing.sm) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color.gradient)
                Spacer()
            }

            Text(value)
                .font(.Fluent.headlineMedium)

            Text(title)
                .font(.Fluent.caption)
                .foregroundStyle(FluentColors.textSecondary)
        }
        .padding(FluentSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Action Card

struct FluentActionCard: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: FluentSpacing.sm) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color.gradient)

                Text(title)
                    .font(.Fluent.caption)
                    .foregroundStyle(FluentColors.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(FluentSpacing.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: FluentRadius.lg)
                    .fill(FluentColors.surface)
            )
            .fluentShadow(isHovered ? .medium : .low)
            .scaleEffect(isPressed ? 0.97 : (isHovered ? 1.02 : 1.0))
            .animation(FluentAnimation.spring, value: isHovered)
            .animation(FluentAnimation.spring, value: isPressed)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - Preview

#Preview("Stat Cards") {
    HStack(spacing: 16) {
        FluentStatCard(title: "Recordings", value: "42", icon: "waveform", color: .blue)
        FluentStatCard(title: "Today", value: "5", icon: "calendar", color: .green)
        FluentStatCard(title: "Total Time", value: "2h 30m", icon: "clock", color: .orange)
    }
    .padding()
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Action Cards") {
    HStack(spacing: 16) {
        FluentActionCard(title: "Start Recording", icon: "mic.fill", color: .blue) {}
        FluentActionCard(title: "Settings", icon: "gear", color: .gray) {}
        FluentActionCard(title: "Shortcuts", icon: "keyboard", color: .purple) {}
    }
    .padding()
    .background(Color(NSColor.windowBackgroundColor))
}
