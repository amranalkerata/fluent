import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var modelManager = ModelManager.shared
    @ObservedObject var punctuationManager = PunctuationModelManager.shared
    @State private var currentStep: Int

    private let totalSteps = 4

    init() {
        // Always start at Welcome step
        _currentStep = State(initialValue: 0)
    }

    /// Both models must be downloaded to continue past step 1
    private var bothModelsReady: Bool {
        modelManager.isModelDownloaded && punctuationManager.isModelDownloaded
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
                    .disabled(currentStep == 1 && !bothModelsReady)
                } else {
                    FluentButton("Get Started", icon: "checkmark", variant: .primary) {
                        completeOnboarding()
                    }
                }
            }
            .padding(FluentSpacing.cardPadding)
        }
        .frame(width: 500, height: 600) // Slightly taller to fit both model cards
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

        // Load both models in background after onboarding
        Task {
            try? await modelManager.loadModel()
            try? await punctuationManager.loadModel()
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
                FeatureRow(icon: "cpu.fill", title: "Local AI Transcription", description: "100% offline using WhisperKit")
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
    @ObservedObject var punctuationManager = PunctuationModelManager.shared
    @State private var isDownloading = false

    /// Overall status text
    private var overallStatusText: String {
        let whisperDone = modelManager.isModelDownloaded
        let punctDone = punctuationManager.isModelDownloaded

        if whisperDone && punctDone {
            return "Both models downloaded!"
        } else if whisperDone {
            return "1 of 2 models downloaded"
        } else {
            return "0 of 2 models downloaded"
        }
    }

    /// Total size description
    private var totalSizeText: String {
        "Total: ~350 MB"
    }

    /// Whether downloads are in progress
    private var isAnyDownloading: Bool {
        modelManager.state.isDownloading || punctuationManager.state.isDownloading
    }

    /// Whether both are downloaded
    private var bothDownloaded: Bool {
        modelManager.isModelDownloaded && punctuationManager.isModelDownloaded
    }

    var body: some View {
        VStack(spacing: FluentSpacing.lg) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(FluentColors.primary.gradient)

            VStack(spacing: FluentSpacing.sm) {
                Text("Download Models")
                    .font(.Fluent.headlineMedium)

                Text("Fluent uses local AI models for transcription.\nNo internet needed after download.")
                    .font(.Fluent.bodyMedium)
                    .foregroundStyle(FluentColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: FluentSpacing.md) {
                // Whisper Model Card
                ModelDownloadCard(
                    title: "Whisper Small Model",
                    subtitle: "Speech recognition",
                    size: modelManager.modelSizeDescription,
                    state: whisperCardState,
                    progress: modelManager.downloadProgress
                )

                // Punctuation Model Card
                ModelDownloadCard(
                    title: "Punctuation Model",
                    subtitle: "Adds punctuation & capitalization",
                    size: punctuationManager.modelSizeDescription,
                    state: punctuationCardState,
                    progress: punctuationManager.downloadProgress
                )

                // Overall status
                HStack {
                    Text(totalSizeText)
                        .font(.Fluent.caption)
                        .foregroundStyle(FluentColors.textTertiary)

                    Spacer()

                    Text(overallStatusText)
                        .font(.Fluent.caption)
                        .foregroundStyle(bothDownloaded ? FluentColors.success : FluentColors.textSecondary)
                }

                // Action button
                downloadActionButton
            }
            .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(FluentSpacing.cardPadding)
    }

    // MARK: - Card States

    private var whisperCardState: ModelCardState {
        switch modelManager.state {
        case .notDownloaded:
            return .waiting
        case .downloading(let progress):
            return .downloading(progress: progress)
        case .retrying(let attempt, let max):
            return .retrying(attempt: attempt, maxAttempts: max)
        case .downloaded, .loading, .ready:
            return .completed
        case .error(let msg):
            return .error(message: msg)
        }
    }

    private var punctuationCardState: ModelCardState {
        // Punctuation waits for Whisper to complete first
        if !modelManager.isModelDownloaded && !punctuationManager.state.isDownloading {
            return .waiting
        }

        switch punctuationManager.state {
        case .notDownloaded:
            return .waiting
        case .downloading(let progress):
            return .downloading(progress: progress)
        case .retrying(let attempt, let max):
            return .retrying(attempt: attempt, maxAttempts: max)
        case .downloaded, .loading, .ready:
            return .completed
        case .error(let msg):
            return .error(message: msg)
        }
    }

    // MARK: - Action Button

    @ViewBuilder
    private var downloadActionButton: some View {
        if bothDownloaded {
            HStack(spacing: FluentSpacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                Text("Downloads Complete")
            }
            .font(.Fluent.bodyMedium)
            .foregroundStyle(FluentColors.success)
        } else if isAnyDownloading {
            FluentButton("Cancel", icon: "xmark", variant: .secondary) {
                cancelAllDownloads()
            }
        } else {
            FluentButton("Download Both Models", icon: "arrow.down.circle", variant: .primary) {
                Task {
                    await downloadBothModels()
                }
            }
        }
    }

    // MARK: - Download Actions

    private func downloadBothModels() async {
        // Sequential download: Whisper first, then Punctuation
        if !modelManager.isModelDownloaded {
            do {
                try await modelManager.downloadModel()
            } catch {
                // Stop if Whisper fails
                return
            }
        }

        if !punctuationManager.isModelDownloaded {
            do {
                try await punctuationManager.downloadModel()
            } catch {
                // Punctuation failed but Whisper succeeded
                return
            }
        }
    }

    private func cancelAllDownloads() {
        modelManager.cancelDownload()
        punctuationManager.cancelDownload()
    }
}

// MARK: - Model Card State

enum ModelCardState {
    case waiting
    case downloading(progress: Double)
    case retrying(attempt: Int, maxAttempts: Int)
    case completed
    case error(message: String)
}

// MARK: - Model Download Card

struct ModelDownloadCard: View {
    let title: String
    let subtitle: String
    let size: String
    let state: ModelCardState
    let progress: Double

    var body: some View {
        VStack(spacing: FluentSpacing.sm) {
            HStack(spacing: FluentSpacing.md) {
                // Status icon
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: FluentSpacing.xxs) {
                    Text(title)
                        .font(.Fluent.titleSmall)
                    Text(statusText)
                        .font(.Fluent.caption)
                        .foregroundStyle(FluentColors.textSecondary)
                }

                Spacer()

                Text(size)
                    .font(.Fluent.monoSmall)
                    .foregroundStyle(FluentColors.textTertiary)
            }

            // Progress bar when downloading
            if case .downloading = state {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            // Error message
            if case .error(let message) = state {
                HStack(spacing: FluentSpacing.xs) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(message)
                        .lineLimit(1)
                }
                .font(.Fluent.caption)
                .foregroundStyle(FluentColors.error)
            }
        }
        .padding(FluentSpacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: FluentRadius.md)
                .fill(FluentColors.surface)
        )
    }

    private var statusIcon: String {
        switch state {
        case .waiting:
            return "arrow.down.circle"
        case .downloading, .retrying:
            return "arrow.down.circle"
        case .completed:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.circle"
        }
    }

    private var statusColor: Color {
        switch state {
        case .waiting:
            return FluentColors.textTertiary
        case .downloading, .retrying:
            return FluentColors.primary
        case .completed:
            return FluentColors.success
        case .error:
            return FluentColors.error
        }
    }

    private var statusText: String {
        switch state {
        case .waiting:
            return "Waiting..."
        case .downloading(let progress):
            return "Downloading... \(Int(progress * 100))%"
        case .retrying(let attempt, let max):
            return "Retrying (\(attempt)/\(max))..."
        case .completed:
            return "Downloaded"
        case .error:
            return "Failed"
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
