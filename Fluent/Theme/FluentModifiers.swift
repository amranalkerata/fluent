import SwiftUI

// MARK: - Card Modifier

struct FluentCardModifier: ViewModifier {
    let radius: CGFloat
    let padding: CGFloat
    let elevation: FluentElevation
    let enableHover: Bool

    @State private var isHovered = false

    func body(content: Content) -> some View {
        let currentElevation = enableHover && isHovered ? elevationForHover(elevation) : elevation
        let shadowValues = currentElevation.shadow

        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(isHovered ? FluentColors.surfaceHover : FluentColors.surface)
            )
            .shadow(
                color: shadowValues.color,
                radius: shadowValues.radius,
                x: shadowValues.x,
                y: shadowValues.y
            )
            .animation(FluentAnimation.fast, value: isHovered)
            .onHover { hovering in
                if enableHover {
                    isHovered = hovering
                }
            }
    }

    private func elevationForHover(_ base: FluentElevation) -> FluentElevation {
        switch base {
        case .none: return .low
        case .low: return .medium
        case .medium: return .high
        case .high: return .high
        }
    }
}

extension View {
    func fluentCard(
        radius: CGFloat = FluentRadius.lg,
        padding: CGFloat = FluentSpacing.cardPadding,
        elevation: FluentElevation = .medium,
        enableHover: Bool = false
    ) -> some View {
        modifier(FluentCardModifier(radius: radius, padding: padding, elevation: elevation, enableHover: enableHover))
    }
}

// MARK: - Page Layout Modifier

extension View {
    func fluentPage() -> some View {
        self
            .padding(FluentSpacing.pagePadding)
            .background(FluentColors.background)
    }
}

// MARK: - Hover Effect Modifier

struct FluentHoverModifier: ViewModifier {
    @State private var isHovered = false
    let scaleEffect: CGFloat
    let showBackground: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? scaleEffect : 1.0)
            .background(
                Group {
                    if showBackground {
                        RoundedRectangle(cornerRadius: FluentRadius.md)
                            .fill(FluentColors.surface.opacity(isHovered ? 0.5 : 0))
                    }
                }
            )
            .animation(FluentAnimation.fast, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

extension View {
    func fluentHover(scale: CGFloat = 1.02, showBackground: Bool = false) -> some View {
        modifier(FluentHoverModifier(scaleEffect: scale, showBackground: showBackground))
    }
}

// MARK: - Press Effect Modifier

struct FluentPressModifier: ViewModifier {
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(FluentAnimation.spring, value: isPressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
    }
}

extension View {
    func fluentPress() -> some View {
        modifier(FluentPressModifier())
    }
}

// MARK: - Shadow Modifier

extension View {
    func fluentShadow(_ elevation: FluentElevation) -> some View {
        let shadowValues = elevation.shadow
        return self.shadow(
            color: shadowValues.color,
            radius: shadowValues.radius,
            x: shadowValues.x,
            y: shadowValues.y
        )
    }
}

// MARK: - Pulse Animation Modifier

struct FluentPulseModifier: ViewModifier {
    @State private var isPulsing = false
    let color: Color

    func body(content: Content) -> some View {
        content
            .overlay(
                Circle()
                    .fill(color.opacity(isPulsing ? 0.3 : 0.6))
                    .scaleEffect(isPulsing ? 1.3 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: isPulsing
                    )
            )
            .onAppear { isPulsing = true }
    }
}

extension View {
    func fluentPulse(color: Color = FluentColors.error) -> some View {
        modifier(FluentPulseModifier(color: color))
    }
}

// MARK: - Appear Animation Modifier

struct FluentAppearModifier: ViewModifier {
    @State private var appeared = false
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(FluentAnimation.spring.delay(delay), value: appeared)
            .onAppear { appeared = true }
    }
}

extension View {
    func fluentAppear(delay: Double = 0) -> some View {
        modifier(FluentAppearModifier(delay: delay))
    }
}
