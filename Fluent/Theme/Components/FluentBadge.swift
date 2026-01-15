import SwiftUI

// MARK: - Badge Variant

enum FluentBadgeVariant {
    case success
    case warning
    case error
    case info
    case neutral

    var color: Color {
        switch self {
        case .success: return FluentColors.success
        case .warning: return FluentColors.warning
        case .error: return FluentColors.error
        case .info: return FluentColors.info
        case .neutral: return FluentColors.textSecondary
        }
    }
}

// MARK: - Badge

struct FluentBadge: View {
    let text: String
    let variant: FluentBadgeVariant
    let icon: String?

    init(_ text: String, variant: FluentBadgeVariant = .neutral, icon: String? = nil) {
        self.text = text
        self.variant = variant
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: FluentSpacing.xxs) {
            if let icon {
                Image(systemName: icon)
                    .font(.Fluent.captionSmall)
            }

            Text(text)
                .font(.Fluent.labelSmall)
        }
        .foregroundStyle(variant.color)
        .padding(.horizontal, FluentSpacing.sm)
        .padding(.vertical, FluentSpacing.xxs)
        .background(
            Capsule()
                .fill(variant.color.opacity(0.15))
        )
    }
}

// MARK: - Status Badge (Icon only)

struct FluentStatusBadge: View {
    let variant: FluentBadgeVariant

    var body: some View {
        Image(systemName: iconName)
            .font(.Fluent.caption)
            .foregroundStyle(variant.color)
    }

    private var iconName: String {
        switch variant {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        case .neutral: return "questionmark.circle.fill"
        }
    }
}

// MARK: - Keyboard Shortcut Badge

struct FluentShortcutBadge: View {
    let keys: [String]
    let onRemove: (() -> Void)?

    @State private var isHovered = false

    init(_ keys: [String], onRemove: (() -> Void)? = nil) {
        self.keys = keys
        self.onRemove = onRemove
    }

    var body: some View {
        HStack(spacing: FluentSpacing.xxs) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                if index > 0 {
                    Text("+")
                        .foregroundStyle(FluentColors.textTertiary)
                }

                Text(key)
                    .font(.Fluent.roundedSmall)
                    .padding(.horizontal, FluentSpacing.xs)
                    .padding(.vertical, FluentSpacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: FluentRadius.xs)
                            .fill(FluentColors.surface)
                    )
            }

            if let onRemove {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(FluentColors.textTertiary)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0.5)
            }
        }
        .padding(.horizontal, FluentSpacing.sm)
        .padding(.vertical, FluentSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: FluentRadius.sm)
                .fill(FluentColors.surfaceElevated)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

#Preview("Badges") {
    VStack(spacing: 20) {
        HStack(spacing: 12) {
            FluentBadge("Authorized", variant: .success, icon: "checkmark")
            FluentBadge("Pending", variant: .warning)
            FluentBadge("Denied", variant: .error)
            FluentBadge("Info", variant: .info)
            FluentBadge("Default", variant: .neutral)
        }

        HStack(spacing: 12) {
            FluentStatusBadge(variant: .success)
            FluentStatusBadge(variant: .warning)
            FluentStatusBadge(variant: .error)
            FluentStatusBadge(variant: .info)
        }

        HStack(spacing: 12) {
            FluentShortcutBadge(["Fn"])
            FluentShortcutBadge(["Option", "Space"], onRemove: {})
            FluentShortcutBadge(["Cmd", "Shift", "R"])
        }
    }
    .padding()
    .background(Color(NSColor.windowBackgroundColor))
}
