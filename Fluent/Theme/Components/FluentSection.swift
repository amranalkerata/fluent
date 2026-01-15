import SwiftUI

// MARK: - Section Header

struct FluentSectionHeader: View {
    let title: String
    let icon: String?
    let action: (() -> Void)?
    let actionLabel: String?

    init(
        _ title: String,
        icon: String? = nil,
        action: (() -> Void)? = nil,
        actionLabel: String? = nil
    ) {
        self.title = title
        self.icon = icon
        self.action = action
        self.actionLabel = actionLabel
    }

    var body: some View {
        HStack {
            if let icon {
                Label(title, systemImage: icon)
                    .font(.Fluent.headlineSmall)
            } else {
                Text(title)
                    .font(.Fluent.headlineSmall)
            }

            Spacer()

            if let action, let actionLabel {
                Button(actionLabel, action: action)
                    .buttonStyle(.link)
                    .font(.Fluent.caption)
            }
        }
    }
}

// MARK: - Section Container

struct FluentSection<Content: View>: View {
    let title: String
    let icon: String?
    let action: (() -> Void)?
    let actionLabel: String?
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        icon: String? = nil,
        action: (() -> Void)? = nil,
        actionLabel: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.action = action
        self.actionLabel = actionLabel
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FluentSpacing.md) {
            FluentSectionHeader(title, icon: icon, action: action, actionLabel: actionLabel)
            content()
        }
    }
}

// MARK: - Settings Section (with card container)

struct FluentSettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FluentSpacing.md) {
            // Enhanced section header with icon background
            HStack(spacing: FluentSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FluentColors.primary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: FluentRadius.sm)
                            .fill(FluentColors.primary.opacity(0.12))
                    )

                Text(title)
                    .font(.Fluent.headlineMedium)
            }

            content()
                .fluentCard()
        }
    }
}

// MARK: - Divider

struct FluentDivider: View {
    var inset: Bool = false

    var body: some View {
        Divider()
            .background(FluentColors.border)
            .padding(.horizontal, inset ? FluentSpacing.sm : 0)
    }
}

// MARK: - Preview

#Preview("Sections") {
    VStack(spacing: 24) {
        FluentSection("Recent Activity", icon: "clock", action: {}, actionLabel: "View All") {
            Text("Content goes here")
                .foregroundStyle(.secondary)
        }

        FluentSettingsSection("Transcription", icon: "text.bubble") {
            VStack(spacing: 16) {
                FluentToggle(title: "AI Enhancement", description: "Improve transcription quality", isOn: .constant(true))
                FluentDivider()
                FluentToggle(title: "Auto-Detect Language", isOn: .constant(false))
            }
        }
    }
    .padding()
    .background(Color(NSColor.windowBackgroundColor))
}
