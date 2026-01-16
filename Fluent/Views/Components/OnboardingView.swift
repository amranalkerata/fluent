import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentStep: Int
    @State private var apiKeyValid: Bool

    private let totalSteps = 4

    init() {
        print("[OnboardingView] init started")
        // Always start at Welcome step
        _currentStep = State(initialValue: 0)
        print("[OnboardingView] About to call hasAPIKey()")
        _apiKeyValid = State(initialValue: KeychainService.shared.hasAPIKey())
        print("[OnboardingView] init completed")
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
                        .onAppear { print("[Onboarding] WelcomeStep appeared") }
                case 1:
                    APIKeyStep(isValid: $apiKeyValid)
                        .onAppear { print("[Onboarding] APIKeyStep appeared") }
                case 2:
                    PermissionsStep()
                        .onAppear { print("[Onboarding] PermissionsStep appeared") }
                default:
                    ReadyStep()
                        .onAppear { print("[Onboarding] ReadyStep appeared") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Navigation
            HStack(spacing: FluentSpacing.md) {
                if currentStep > 0 {
                    FluentButton("Back", icon: "chevron.left", variant: .secondary) {
                        // NOTE: Removed withAnimation - causes deadlock with SecureField on macOS
                        currentStep -= 1
                    }
                }

                Spacer()

                if currentStep < totalSteps - 1 {
                    FluentButton("Continue", icon: "chevron.right", iconPosition: .trailing, variant: .primary) {
                        print("[Onboarding] Continue tapped, currentStep: \(currentStep) → \(currentStep + 1)")
                        // NOTE: Removed withAnimation - causes deadlock with SecureField on macOS
                        currentStep += 1
                        print("[Onboarding] Step transition complete")
                    }
                    .disabled(currentStep == 1 && !apiKeyValid)
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
                FeatureRow(icon: "text.bubble.fill", title: "AI Transcription", description: "Powered by OpenAI Whisper")
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

struct APIKeyStep: View {
    @Binding var isValid: Bool
    @State private var apiKey = ""
    @State private var isValidating = false
    @State private var error: String?

    private let keychainService: KeychainService

    init(isValid: Binding<Bool>) {
        print("[APIKeyStep] init started")
        // CRITICAL: Must explicitly initialize @State when using custom init
        self._isValid = isValid
        self._apiKey = State(initialValue: "")
        self._isValidating = State(initialValue: false)
        self._error = State(initialValue: nil)
        print("[APIKeyStep] About to access KeychainService.shared")
        self.keychainService = KeychainService.shared
        print("[APIKeyStep] init completed")
    }

    var body: some View {
        let _ = print("[APIKeyStep] body computed - START")
        return VStack(spacing: FluentSpacing.lg) {
            Image(systemName: "key.fill")
                .font(.system(size: 48))
                .foregroundStyle(FluentColors.warning.gradient)

            VStack(spacing: FluentSpacing.sm) {
                Text("Enter Your API Key")
                    .font(.Fluent.headlineMedium)

                Text("Fluent uses OpenAI's Whisper API for transcription.\nYou'll need your own API key.")
                    .font(.Fluent.bodyMedium)
                    .foregroundStyle(FluentColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: FluentSpacing.md) {
                // TEST: Using plain SecureField instead of FluentSecureField
                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 350)

                if let error = error {
                    HStack(spacing: FluentSpacing.xs) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text(error)
                    }
                    .font(.Fluent.caption)
                    .foregroundStyle(FluentColors.error)
                }

                if isValid {
                    HStack(spacing: FluentSpacing.xs) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("API key saved successfully!")
                    }
                    .font(.Fluent.caption)
                    .foregroundStyle(FluentColors.success)
                }

                FluentButton(
                    isValidating ? "Validating..." : "Validate & Save",
                    icon: "checkmark.shield",
                    variant: .primary
                ) {
                    validateKey()
                }
                .disabled(apiKey.isEmpty || isValidating)

                Link("Get an API key from OpenAI",
                     destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.Fluent.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(FluentSpacing.cardPadding)
    }

    private func validateKey() {
        print("[validateKey] START")
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard keychainService.isValidAPIKeyFormat(trimmedKey) else {
            print("[validateKey] Invalid format")
            error = "Invalid format. API keys start with 'sk-'"
            return
        }

        print("[validateKey] Setting isValidating = true")
        isValidating = true
        error = nil

        print("[validateKey] Creating Task")
        Task {
            print("[validateKey] Task started")
            let service = TranscriptionService()
            print("[validateKey] About to call testAPIKey")
            let valid = await service.testAPIKey(trimmedKey)
            print("[validateKey] testAPIKey returned: \(valid)")

            print("[validateKey] About to run MainActor.run")
            await MainActor.run {
                print("[validateKey] Inside MainActor.run")
                isValidating = false
                if valid {
                    print("[validateKey] API key valid, saving to keychain")
                    let saved = keychainService.saveAPIKey(trimmedKey)
                    if saved {
                        print("[validateKey] Saved successfully, setting isValid = true")
                        isValid = true
                    } else {
                        print("[validateKey] Failed to save")
                        error = "Failed to save API key to Keychain"
                    }
                } else {
                    print("[validateKey] API key invalid")
                    error = "Invalid API key. Please check and try again."
                }
                print("[validateKey] MainActor.run completed")
            }
            print("[validateKey] Task completed")
        }
        print("[validateKey] END (Task launched)")
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
            print("[PermissionsStep] onAppear - refreshing statuses async")
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
