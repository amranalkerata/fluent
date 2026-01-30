import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var modelManager = ModelManager.shared
    @State private var currentStep: Int

    private let totalSteps = 4

    init() {
        // Always start at Welcome step
        _currentStep = State(initialValue: 0)
    }

    private var modelReady: Bool {
        modelManager.isModelDownloaded
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with step indicator (centered)
            HStack {
                Spacer()

                // Step indicator
                Text("Step \(currentStep + 1) of \(totalSteps)")
                    .font(.Fluent.caption)
                    .foregroundStyle(FluentColors.textSecondary)

                Spacer()
            }
            .padding(.horizontal, FluentSpacing.cardPadding)
            .padding(.top, FluentSpacing.md)

            // Progress bar
            HStack(spacing: FluentSpacing.xs) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    RoundedRectangle(cornerRadius: FluentRadius.full)
                        .fill(step <= currentStep ? FluentColors.primary : FluentColors.textTertiary.opacity(0.2))
                        .frame(height: 3)
                        .animation(FluentAnimation.normal, value: currentStep)
                }
            }
            .padding(.horizontal, FluentSpacing.cardPadding)
            .padding(.top, FluentSpacing.sm)

            // Content
            Group {
                switch currentStep {
                case 0:
                    WelcomeStep()
                case 1:
                    ModelDownloadStep()
                case 2:
                    PermissionsStep()
                default:
                    ReadyStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Navigation
            HStack(spacing: FluentSpacing.md) {
                if currentStep > 0 {
                    FluentButton("Back", icon: "chevron.left", variant: .secondary) {
                        currentStep -= 1
                    }
                }

                Spacer()

                if currentStep < totalSteps - 1 {
                    FluentButton("Continue", icon: "chevron.right", iconPosition: .trailing, variant: .primary) {
                        currentStep += 1
                    }
                    .disabled(currentStep == 1 && !modelReady)
                } else {
                    FluentButton("Get Started", icon: "checkmark", variant: .primary) {
                        completeOnboarding()
                    }
                }
            }
            .padding(FluentSpacing.cardPadding)
        }
        .frame(width: 500, height: 550)
        .background(
            RoundedRectangle(cornerRadius: FluentRadius.lg)
                .fill(FluentColors.background)
        )
        .clipShape(RoundedRectangle(cornerRadius: FluentRadius.lg))
        .fluentShadow(.high)
    }

    private func completeOnboarding() {
        SettingsService.shared.isOnboardingComplete = true
        appState.showOnboarding = false

        // Load model in background after onboarding
        Task {
            try? await modelManager.loadModel()
        }
    }
}

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: FluentSpacing.lg) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)

            VStack(spacing: FluentSpacing.sm) {
                Text("Welcome to Fluent")
                    .font(.Fluent.headlineLarge)

                Text("Your voice, perfectly transcribed")
                    .font(.Fluent.titleLarge)
                    .foregroundStyle(FluentColors.textSecondary)
            }

            VStack(alignment: .leading, spacing: FluentSpacing.md) {
                FeatureRow(icon: "mic.fill", title: "Voice Recording", description: "Record audio with a single keypress")
                FeatureRow(icon: "cpu.fill", title: "Local AI Transcription", description: "100% offline using whisper.cpp")
                FeatureRow(icon: "doc.on.clipboard.fill", title: "Auto-Paste", description: "Transcriptions pasted instantly")
            }
            .fluentCard()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(FluentSpacing.cardPadding)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: FluentSpacing.md) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(FluentColors.primary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: FluentSpacing.xxs) {
                Text(title)
                    .font(.Fluent.titleSmall)
                Text(description)
                    .font(.Fluent.caption)
                    .foregroundStyle(FluentColors.textSecondary)
            }
        }
    }
}

struct ModelDownloadStep: View {
    @ObservedObject var modelManager = ModelManager.shared

    var body: some View {
        VStack(spacing: FluentSpacing.lg) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(FluentColors.primary.gradient)

            VStack(spacing: FluentSpacing.sm) {
                Text("Download Whisper Model")
                    .font(.Fluent.headlineMedium)

                Text("Fluent uses a local AI model for transcription.\nNo internet needed after download.")
                    .font(.Fluent.bodyMedium)
                    .foregroundStyle(FluentColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: FluentSpacing.md) {
                // Status card
                VStack(spacing: FluentSpacing.md) {
                    HStack(spacing: FluentSpacing.md) {
                        Image(systemName: statusIcon)
                            .font(.title2)
                            .foregroundStyle(statusColor)
                            .frame(width: 30)

                        VStack(alignment: .leading, spacing: FluentSpacing.xxs) {
                            Text("Whisper Base Model")
                                .font(.Fluent.titleSmall)
                            Text(statusText)
                                .font(.Fluent.caption)
                                .foregroundStyle(FluentColors.textSecondary)
                        }

                        Spacer()

                        Text(modelManager.modelSizeDescription)
                            .font(.Fluent.monoSmall)
                            .foregroundStyle(FluentColors.textTertiary)
                    }

                    // Progress bar when downloading
                    if case .downloading(let progress) = modelManager.state {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)

                        Text("\(Int(progress * 100))% downloaded")
                            .font(.Fluent.caption)
                            .foregroundStyle(FluentColors.textSecondary)
                    }

                    // Error message
                    if case .error(let message) = modelManager.state {
                        HStack(spacing: FluentSpacing.xs) {
                            Image(systemName: "exclamationmark.circle.fill")
                            Text(message)
                        }
                        .font(.Fluent.caption)
                        .foregroundStyle(FluentColors.error)
                    }

                    // Action button
                    actionButton
                }
                .padding(FluentSpacing.cardPadding)
                .background(
                    RoundedRectangle(cornerRadius: FluentRadius.md)
                        .fill(FluentColors.surface)
                )

                // Info text
                if modelManager.isModelDownloaded {
                    HStack(spacing: FluentSpacing.xs) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Model downloaded! You can continue.")
                    }
                    .font(.Fluent.caption)
                    .foregroundStyle(FluentColors.success)
                }
            }
            .frame(maxWidth: 350)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(FluentSpacing.cardPadding)
    }

    private var statusIcon: String {
        switch modelManager.state {
        case .notDownloaded:
            return "arrow.down.circle"
        case .downloading:
            return "arrow.down.circle"
        case .downloaded, .ready:
            return "checkmark.circle.fill"
        case .loading:
            return "arrow.clockwise.circle"
        case .error:
            return "exclamationmark.circle"
        }
    }

    private var statusColor: Color {
        switch modelManager.state {
        case .notDownloaded:
            return FluentColors.warning
        case .downloading, .loading:
            return FluentColors.primary
        case .downloaded, .ready:
            return FluentColors.success
        case .error:
            return FluentColors.error
        }
    }

    private var statusText: String {
        switch modelManager.state {
        case .notDownloaded:
            return "Ready to download"
        case .downloading:
            return "Downloading..."
        case .downloaded:
            return "Downloaded successfully"
        case .loading:
            return "Loading..."
        case .ready:
            return "Ready for transcription"
        case .error:
            return "Download failed"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch modelManager.state {
        case .notDownloaded, .error:
            FluentButton("Download Model", icon: "arrow.down.circle", variant: .primary) {
                Task {
                    try? await modelManager.downloadModel()
                }
            }
        case .downloading:
            FluentButton("Cancel", icon: "xmark", variant: .secondary) {
                modelManager.cancelDownload()
            }
        case .downloaded, .loading, .ready:
            HStack(spacing: FluentSpacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                Text("Download Complete")
            }
            .font(.Fluent.bodyMedium)
            .foregroundStyle(FluentColors.success)
        }
    }
}

struct PermissionsStep: View {
    @ObservedObject var permissionService = PermissionService.shared

    var body: some View {
        VStack(spacing: FluentSpacing.lg) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(FluentColors.success.gradient)

            VStack(spacing: FluentSpacing.sm) {
                Text("Grant Permissions")
                    .font(.Fluent.headlineMedium)

                Text("Fluent needs a few permissions to work properly")
                    .font(.Fluent.bodyMedium)
                    .foregroundStyle(FluentColors.textSecondary)
            }

            VStack(spacing: FluentSpacing.md) {
                PermissionCard(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Required to record your voice",
                    status: permissionService.microphoneStatus,
                    action: {
                        Task {
                            await permissionService.requestMicrophoneAccess()
                        }
                    }
                )

                PermissionCard(
                    icon: "keyboard",
                    title: "Input Monitoring",
                    description: "Required for global keyboard shortcuts",
                    status: permissionService.inputMonitoringStatus,
                    action: {
                        permissionService.requestInputMonitoringAccess()
                    }
                )

                PermissionCard(
                    icon: "hand.raised.fill",
                    title: "Accessibility",
                    description: "Optional, enables auto-paste feature",
                    status: permissionService.accessibilityStatus,
                    action: {
                        permissionService.requestAccessibilityAccess()
                    },
                    isOptional: true
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(FluentSpacing.cardPadding)
        .onAppear {
            Task {
                await permissionService.refreshAllStatusesAsync()
            }
        }
    }
}

struct PermissionCard: View {
    let icon: String
    let title: String
    let description: String
    let status: PermissionStatus
    let action: () -> Void
    var isOptional: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: FluentSpacing.md) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(statusColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: FluentSpacing.xxs) {
                HStack(spacing: FluentSpacing.xs) {
                    Text(title)
                        .font(.Fluent.titleSmall)
                    if isOptional {
                        FluentBadge("Optional", variant: .neutral)
                    }
                }
                Text(description)
                    .font(.Fluent.caption)
                    .foregroundStyle(FluentColors.textSecondary)
            }

            Spacer()

            if status == .authorized {
                FluentStatusBadge(variant: .success)
            } else {
                FluentButton("Grant", variant: .secondary, size: .small) {
                    action()
                }
            }
        }
        .padding(FluentSpacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: FluentRadius.md)
                .fill(FluentColors.surface)
        )
        .fluentShadow(isHovered ? .medium : .low)
        .animation(FluentAnimation.fast, value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var statusColor: Color {
        switch status {
        case .authorized: return FluentColors.success
        case .denied: return FluentColors.error
        default: return FluentColors.warning
        }
    }
}

struct ReadyStep: View {
    @ObservedObject var hotkeyService = HotkeyService.shared

    var body: some View {
        VStack(spacing: FluentSpacing.lg) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(FluentColors.success.gradient)

            VStack(spacing: FluentSpacing.sm) {
                Text("You're All Set!")
                    .font(.Fluent.headlineLarge)

                Text("Start dictating with these shortcuts")
                    .font(.Fluent.titleLarge)
                    .foregroundStyle(FluentColors.textSecondary)
            }

            VStack(spacing: FluentSpacing.md) {
                ShortcutInfoRow(
                    shortcut: "fn",
                    description: "Press to start/stop recording"
                )

                ShortcutInfoRow(
                    shortcut: "^ Space",
                    description: "Alternative recording shortcut"
                )

                ShortcutInfoRow(
                    shortcut: "esc",
                    description: "Cancel recording"
                )
            }
            .fluentCard()

            Text("You can customize shortcuts in Settings")
                .font(.Fluent.caption)
                .foregroundStyle(FluentColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(FluentSpacing.cardPadding)
    }
}

struct ShortcutInfoRow: View {
    let shortcut: String
    let description: String

    var body: some View {
        HStack(spacing: FluentSpacing.md) {
            Text(shortcut)
                .font(.Fluent.roundedSmall)
                .padding(.horizontal, FluentSpacing.md)
                .padding(.vertical, FluentSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: FluentRadius.sm)
                        .fill(FluentColors.primary.opacity(0.15))
                )

            Text(description)
                .font(.Fluent.bodyMedium)
                .foregroundStyle(FluentColors.textSecondary)

            Spacer()
        }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AppState())
}
