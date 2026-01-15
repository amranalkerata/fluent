import SwiftUI

// MARK: - Empty State

struct FluentEmptyState: View {
    let icon: String
    let title: String
    let message: String
    let action: (() -> Void)?
    let actionLabel: String?

    init(
        icon: String,
        title: String,
        message: String,
        action: (() -> Void)? = nil,
        actionLabel: String? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.action = action
        self.actionLabel = actionLabel
    }

    var body: some View {
        VStack(spacing: FluentSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(FluentColors.textTertiary)

            VStack(spacing: FluentSpacing.xs) {
                Text(title)
                    .font(.Fluent.headlineSmall)

                Text(message)
                    .font(.Fluent.bodyMedium)
                    .foregroundStyle(FluentColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let action, let actionLabel {
                FluentButton(actionLabel, variant: .secondary) {
                    action()
                }
                .padding(.top, FluentSpacing.sm)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(FluentSpacing.xxxl)
        .fluentCard()
    }
}

// MARK: - Loading State

struct FluentLoadingState: View {
    let message: String?

    init(_ message: String? = nil) {
        self.message = message
    }

    var body: some View {
        VStack(spacing: FluentSpacing.md) {
            ProgressView()
                .scaleEffect(1.2)

            if let message {
                Text(message)
                    .font(.Fluent.caption)
                    .foregroundStyle(FluentColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(FluentSpacing.xxxl)
    }
}

// MARK: - Error State

struct FluentErrorState: View {
    let title: String
    let message: String
    let retryAction: (() -> Void)?

    init(
        title: String = "Something went wrong",
        message: String,
        retryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.retryAction = retryAction
    }

    var body: some View {
        VStack(spacing: FluentSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(FluentColors.warning)

            VStack(spacing: FluentSpacing.xs) {
                Text(title)
                    .font(.Fluent.headlineSmall)

                Text(message)
                    .font(.Fluent.bodyMedium)
                    .foregroundStyle(FluentColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let retryAction {
                FluentButton("Try Again", icon: "arrow.clockwise", variant: .secondary) {
                    retryAction()
                }
                .padding(.top, FluentSpacing.sm)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(FluentSpacing.xxxl)
        .fluentCard()
    }
}

// MARK: - Preview

#Preview("Empty States") {
    VStack(spacing: 24) {
        FluentEmptyState(
            icon: "waveform.path.ecg",
            title: "No recordings yet",
            message: "Press Fn or Option+Space to start recording",
            action: {},
            actionLabel: "Start Recording"
        )

        FluentLoadingState("Transcribing...")

        FluentErrorState(
            message: "Failed to load recordings. Please try again.",
            retryAction: {}
        )
    }
    .padding()
    .background(Color(NSColor.windowBackgroundColor))
}
