import SwiftUI

// MARK: - Button Style

enum FluentButtonVariant {
    case primary
    case secondary
    case tertiary
    case destructive
}

enum FluentButtonIconPosition {
    case leading
    case trailing
}

enum FluentButtonSize {
    case small
    case medium
    case large

    var horizontalPadding: CGFloat {
        switch self {
        case .small: return FluentSpacing.sm
        case .medium: return FluentSpacing.md
        case .large: return FluentSpacing.lg
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .small: return FluentSpacing.xs
        case .medium: return FluentSpacing.sm
        case .large: return FluentSpacing.md
        }
    }

    var font: Font {
        switch self {
        case .small: return .Fluent.labelSmall
        case .medium: return .Fluent.labelMedium
        case .large: return .Fluent.labelLarge
        }
    }
}

// MARK: - Fluent Button

struct FluentButton: View {
    let title: String
    let icon: String?
    let iconPosition: FluentButtonIconPosition
    let variant: FluentButtonVariant
    let size: FluentButtonSize
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    init(
        _ title: String,
        icon: String? = nil,
        iconPosition: FluentButtonIconPosition = .leading,
        variant: FluentButtonVariant = .primary,
        size: FluentButtonSize = .medium,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.iconPosition = iconPosition
        self.variant = variant
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: FluentSpacing.xs) {
                if let icon, iconPosition == .leading {
                    Image(systemName: icon)
                }
                Text(title)
                if let icon, iconPosition == .trailing {
                    Image(systemName: icon)
                }
            }
            .font(size.font)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background(backgroundView)
            .scaleEffect(isPressed ? 0.97 : 1.0)
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

    private var foregroundColor: Color {
        switch variant {
        case .primary:
            return .white
        case .secondary:
            return FluentColors.textPrimary
        case .tertiary:
            return FluentColors.primary
        case .destructive:
            return .white
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch variant {
        case .primary:
            RoundedRectangle(cornerRadius: FluentRadius.md)
                .fill(isHovered ? FluentColors.primaryHover : FluentColors.primary)

        case .secondary:
            RoundedRectangle(cornerRadius: FluentRadius.md)
                .fill(isHovered ? FluentColors.surfaceHover : FluentColors.surface)

        case .tertiary:
            RoundedRectangle(cornerRadius: FluentRadius.md)
                .fill(isHovered ? FluentColors.surface : Color.clear)

        case .destructive:
            RoundedRectangle(cornerRadius: FluentRadius.md)
                .fill(isHovered ? FluentColors.error.opacity(0.8) : FluentColors.error)
        }
    }
}

// MARK: - Icon Button

struct FluentIconButton: View {
    let icon: String
    let color: Color
    let size: CGFloat
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    init(
        icon: String,
        color: Color = FluentColors.textPrimary,
        size: CGFloat = 20,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.color = color
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundStyle(color)
                .padding(FluentSpacing.xs)
                .background(
                    Circle()
                        .fill(isHovered ? FluentColors.surface : Color.clear)
                )
                .scaleEffect(isPressed ? 0.9 : 1.0)
                .animation(FluentAnimation.spring, value: isPressed)
                .animation(FluentAnimation.fast, value: isHovered)
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

#Preview("Buttons") {
    VStack(spacing: 20) {
        HStack(spacing: 12) {
            FluentButton("Primary", icon: "plus", variant: .primary) {}
            FluentButton("Secondary", variant: .secondary) {}
            FluentButton("Tertiary", variant: .tertiary) {}
            FluentButton("Destructive", icon: "trash", variant: .destructive) {}
        }

        HStack(spacing: 12) {
            FluentButton("Small", variant: .primary, size: .small) {}
            FluentButton("Medium", variant: .primary, size: .medium) {}
            FluentButton("Large", variant: .primary, size: .large) {}
        }

        HStack(spacing: 12) {
            FluentIconButton(icon: "gear", color: .gray) {}
            FluentIconButton(icon: "trash", color: .red) {}
            FluentIconButton(icon: "plus.circle.fill", color: .blue) {}
        }
    }
    .padding()
    .background(Color(NSColor.windowBackgroundColor))
}
