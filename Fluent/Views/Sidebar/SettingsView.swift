import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsService = SettingsService.shared
    @State private var showingAPIKeySheet = false
    @State private var showingResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FluentSpacing.sectionSpacing) {
                // API Key Section
                FluentSettingsSection("API Key", icon: "key") {
                    APIKeySettingsCard(showingSheet: $showingAPIKeySheet)
                }
                .fluentAppear(delay: 0)

                // Transcription Section
                FluentSettingsSection("Transcription", icon: "text.bubble") {
                    TranscriptionSettingsCard()
                }
                .fluentAppear(delay: 0.05)

                // Behavior Section
                FluentSettingsSection("Behavior", icon: "gearshape.2") {
                    BehaviorSettingsCard()
                }
                .fluentAppear(delay: 0.1)

                // Permissions Section
                FluentSettingsSection("Permissions", icon: "lock.shield") {
                    PermissionsSettingsCard()
                }
                .fluentAppear(delay: 0.15)

                // About Section
                FluentSettingsSection("About", icon: "info.circle") {
                    AboutSettingsCard()
                }
                .fluentAppear(delay: 0.2)

                // Reset
                HStack {
                    Spacer()
                    FluentButton("Reset All Settings", variant: .destructive) {
                        showingResetConfirmation = true
                    }
                }
            }
            .padding(FluentSpacing.pagePadding)
        }
        .background(FluentColors.background)
        .navigationTitle("Settings")
        .sheet(isPresented: $showingAPIKeySheet) {
            APIKeySheet()
        }
        .alert("Reset All Settings?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                settingsService.resetAllSettings()
            }
        } message: {
            Text("This will reset all settings to their default values. Your API key will not be affected.")
        }
    }
}

struct APIKeySettingsCard: View {
    @Binding var showingSheet: Bool
    private let keychainService = KeychainService.shared
    @State private var isHovered = false

    private var isConfigured: Bool {
        keychainService.hasAPIKey()
    }

    var body: some View {
        HStack(spacing: FluentSpacing.md) {
            // Status indicator with icon background
            Image(systemName: isConfigured ? "checkmark.circle.fill" : "key.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isConfigured ? FluentColors.success : FluentColors.warning)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: FluentRadius.sm)
                        .fill((isConfigured ? FluentColors.success : FluentColors.warning).opacity(0.12))
                )

            VStack(alignment: .leading, spacing: FluentSpacing.xxs) {
                Text("OpenAI API Key")
                    .font(.Fluent.titleSmall)

                if let maskedKey = keychainService.getMaskedAPIKey() {
                    Text(maskedKey)
                        .font(.Fluent.monoSmall)
                        .foregroundStyle(FluentColors.textSecondary)
                } else {
                    Text("Not configured")
                        .font(.Fluent.caption)
                        .foregroundStyle(FluentColors.textSecondary)
                }
            }

            Spacer()

            FluentButton(
                isConfigured ? "Change" : "Add Key",
                icon: isConfigured ? "pencil" : "plus",
                variant: isConfigured ? .secondary : .primary
            ) {
                showingSheet = true
            }
        }
    }
}

struct TranscriptionSettingsCard: View {
    @ObservedObject var settingsService = SettingsService.shared

    var body: some View {
        VStack(spacing: FluentSpacing.md) {
            // GPT Enhancement
            FluentToggle(
                title: "AI Enhancement",
                description: "Improve transcription with auto-punctuation and formatting",
                isOn: $settingsService.settings.isGPTEnhancementEnabled
            )

            FluentDivider(inset: true)

            // Language
            HStack {
                VStack(alignment: .leading, spacing: FluentSpacing.xxs) {
                    Text("Language")
                        .font(.Fluent.titleSmall)
                    Text("Select transcription language or auto-detect")
                        .font(.Fluent.caption)
                        .foregroundStyle(FluentColors.textSecondary)
                }

                Spacer(minLength: FluentSpacing.lg)

                Picker("", selection: $settingsService.settings.language) {
                    ForEach(AppSettings.TranscriptionLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
            }
        }
    }
}

struct BehaviorSettingsCard: View {
    @ObservedObject var settingsService = SettingsService.shared

    var body: some View {
        VStack(spacing: FluentSpacing.md) {
            FluentToggle(
                title: "Auto-Paste",
                description: "Automatically paste transcription at cursor",
                isOn: $settingsService.settings.autoPasteEnabled
            )

            FluentDivider(inset: true)

            FluentToggle(
                title: "Show Recording Overlay",
                description: "Display floating window while recording",
                isOn: $settingsService.settings.showRecordingOverlay
            )

            FluentDivider(inset: true)

            FluentToggle(
                title: "Launch at Login",
                description: "Start Fluent when you log in",
                isOn: Binding(
                    get: { settingsService.isLaunchAtLoginEnabled },
                    set: { settingsService.setLaunchAtLogin($0) }
                )
            )
        }
    }
}

struct PermissionsSettingsCard: View {
    @ObservedObject var permissionService = PermissionService.shared

    var body: some View {
        VStack(spacing: FluentSpacing.md) {
            PermissionRow(
                title: "Microphone",
                description: "Required for voice recording",
                status: permissionService.microphoneStatus,
                action: { permissionService.openMicrophoneSettings() }
            )

            FluentDivider(inset: true)

            PermissionRow(
                title: "Input Monitoring",
                description: "Required for global keyboard shortcuts",
                status: permissionService.inputMonitoringStatus,
                action: { permissionService.openInputMonitoringSettings() }
            )

            FluentDivider(inset: true)

            PermissionRow(
                title: "Accessibility",
                description: "Optional, enables auto-paste feature",
                status: permissionService.accessibilityStatus,
                action: { permissionService.openAccessibilitySettings() }
            )
        }
        .onAppear {
            permissionService.refreshAllStatuses()
        }
    }
}

struct PermissionRow: View {
    let title: String
    let description: String
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        HStack(spacing: FluentSpacing.md) {
            // Status indicator dot
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: FluentSpacing.xxs) {
                HStack(spacing: FluentSpacing.xs) {
                    Text(title)
                        .font(.Fluent.titleSmall)

                    FluentStatusBadge(variant: statusVariant)
                }

                Text(description)
                    .font(.Fluent.caption)
                    .foregroundStyle(FluentColors.textSecondary)
            }

            Spacer()

            if status != .authorized {
                FluentButton("Grant", variant: .secondary, size: .small) {
                    action()
                }
            }
        }
    }

    private var statusColor: Color {
        switch status {
        case .authorized:
            return FluentColors.success
        case .denied:
            return FluentColors.error
        case .notDetermined, .restricted:
            return FluentColors.warning
        }
    }

    private var statusVariant: FluentBadgeVariant {
        switch status {
        case .authorized:
            return .success
        case .denied:
            return .error
        case .notDetermined, .restricted:
            return .warning
        }
    }
}

struct AboutSettingsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: FluentSpacing.md) {
            HStack(spacing: FluentSpacing.md) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: FluentSpacing.xxs) {
                    Text("Fluent")
                        .font(.Fluent.headlineSmall)

                    Text("Version 1.0.0")
                        .font(.Fluent.caption)
                        .foregroundStyle(FluentColors.textSecondary)
                }

                Spacer()
            }

            Text("An open-source voice dictation app for macOS.\nPowered by OpenAI Whisper.")
                .font(.Fluent.caption)
                .foregroundStyle(FluentColors.textSecondary)

            VStack(alignment: .leading, spacing: FluentSpacing.sm) {
                Image("CreatorPhoto")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())

                Text("Developed by Amran Al Kerata")
                    .font(.Fluent.caption)
                    .foregroundStyle(FluentColors.textSecondary)
            }

            HStack(spacing: FluentSpacing.md) {
                Link(destination: URL(string: "https://kerata.net")!) {
                    HStack(spacing: FluentSpacing.xs) {
                        Image(systemName: "globe")
                        Text("Website")
                    }
                    .font(.Fluent.caption)
                }

                Link(destination: URL(string: "https://www.linkedin.com/in/amran-al-kerata/")!) {
                    HStack(spacing: FluentSpacing.xs) {
                        Image(systemName: "person.crop.circle")
                        Text("LinkedIn")
                    }
                    .font(.Fluent.caption)
                }

                Link(destination: URL(string: "https://github.com/amranalkerata/fluent")!) {
                    HStack(spacing: FluentSpacing.xs) {
                        Image(systemName: "link")
                        Text("GitHub")
                    }
                    .font(.Fluent.caption)
                }

                Link(destination: URL(string: "https://github.com/amranalkerata/fluent/issues")!) {
                    HStack(spacing: FluentSpacing.xs) {
                        Image(systemName: "exclamationmark.bubble")
                        Text("Report Issue")
                    }
                    .font(.Fluent.caption)
                }
            }
        }
    }
}

struct APIKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var isValidating = false
    @State private var validationError: String?
    @State private var isValid = false

    private let keychainService = KeychainService.shared

    var body: some View {
        VStack(spacing: FluentSpacing.sectionSpacing) {
            Text("OpenAI API Key")
                .font(.Fluent.headlineSmall)

            VStack(alignment: .leading, spacing: FluentSpacing.sm) {
                Text("Enter your OpenAI API key to enable transcription.")
                    .font(.Fluent.bodyMedium)
                    .foregroundStyle(FluentColors.textSecondary)

                FluentSecureField("sk-...", text: $apiKey)
                    .onChange(of: apiKey) { _, _ in
                        validationError = nil
                        isValid = false
                    }

                if let error = validationError {
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
                        Text("API key is valid")
                    }
                    .font(.Fluent.caption)
                    .foregroundStyle(FluentColors.success)
                }

                Link("Get an API key from OpenAI", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.Fluent.caption)
            }

            HStack(spacing: FluentSpacing.md) {
                FluentButton("Cancel", variant: .tertiary) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if keychainService.hasAPIKey() {
                    FluentButton("Remove Key", icon: "trash", variant: .destructive) {
                        keychainService.deleteAPIKey()
                        dismiss()
                    }
                }

                FluentButton("Validate & Save", icon: "checkmark.shield", variant: .primary) {
                    validateAndSave()
                }
                .disabled(apiKey.isEmpty || isValidating)
            }
        }
        .padding(FluentSpacing.pagePadding)
        .frame(width: 450)
    }

    private func validateAndSave() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // Basic format check
        guard keychainService.isValidAPIKeyFormat(trimmedKey) else {
            validationError = "Invalid API key format. Keys should start with 'sk-'"
            return
        }

        isValidating = true
        validationError = nil

        Task {
            let transcriptionService = TranscriptionService()
            let valid = await transcriptionService.testAPIKey(trimmedKey)

            await MainActor.run {
                isValidating = false

                if valid {
                    isValid = true
                    let saved = keychainService.saveAPIKey(trimmedKey)

                    if saved {
                        // Dismiss after brief delay to show success
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            dismiss()
                        }
                    } else {
                        validationError = "Failed to save API key to keychain."
                    }
                } else {
                    validationError = "API key validation failed. Please check your key."
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
