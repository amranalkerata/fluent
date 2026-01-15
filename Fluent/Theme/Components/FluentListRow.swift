import SwiftUI

// MARK: - Generic List Row

struct FluentListRow<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    @State private var isHovered = false

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: FluentSpacing.md) {
            leading()

            VStack(alignment: .leading, spacing: FluentSpacing.xxs) {
                Text(title)
                    .font(.Fluent.bodyLarge)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.Fluent.caption)
                        .foregroundStyle(FluentColors.textSecondary)
                }
            }

            Spacer()

            trailing()
        }
        .padding(FluentSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: FluentRadius.md)
                .fill(isHovered ? FluentColors.surfaceHover : FluentColors.surface)
        )
        .animation(FluentAnimation.fast, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Recording Row

struct FluentRecordingRow: View {
    let title: String
    let subtitle: String
    let duration: String
    let onTap: (() -> Void)?

    @State private var isHovered = false

    init(
        title: String,
        subtitle: String,
        duration: String,
        onTap: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.duration = duration
        self.onTap = onTap
    }

    var body: some View {
        HStack(spacing: FluentSpacing.md) {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(FluentColors.primary.gradient)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: FluentSpacing.xxs) {
                Text(title)
                    .font(.Fluent.bodyLarge)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.Fluent.caption)
                    .foregroundStyle(FluentColors.textSecondary)
            }

            Spacer()

            Text(duration)
                .font(.Fluent.monoSmall)
                .foregroundStyle(FluentColors.textSecondary)
        }
        .padding(FluentSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: FluentRadius.md)
                .fill(isHovered ? FluentColors.surfaceHover : FluentColors.surface)
        )
        .animation(FluentAnimation.fast, value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture {
            onTap?()
        }
    }
}

// MARK: - Settings Row

struct FluentSettingsRow: View {
    let title: String
    let description: String?
    let value: String?
    let action: () -> Void

    @State private var isHovered = false

    init(
        title: String,
        description: String? = nil,
        value: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.description = description
        self.value = value
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: FluentSpacing.xxs) {
                    Text(title)
                        .font(.Fluent.titleSmall)

                    if let description {
                        Text(description)
                            .font(.Fluent.caption)
                            .foregroundStyle(FluentColors.textSecondary)
                    }
                }

                Spacer()

                if let value {
                    Text(value)
                        .font(.Fluent.monoSmall)
                        .foregroundStyle(FluentColors.textSecondary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(FluentColors.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

#Preview("List Rows") {
    VStack(spacing: 8) {
        FluentListRow(
            title: "Hello world transcription",
            subtitle: "2 minutes ago"
        ) {
            Image(systemName: "waveform")
                .foregroundStyle(.blue)
        } trailing: {
            Text("0:32")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }

        FluentRecordingRow(
            title: "Meeting notes from standup",
            subtitle: "Today at 9:00 AM",
            duration: "2:45"
        )

        FluentSettingsRow(
            title: "Language",
            description: "Transcription language",
            value: "English"
        ) {}
    }
    .padding()
    .background(Color(NSColor.windowBackgroundColor))
}
