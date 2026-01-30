import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsService = SettingsService.shared
    @ObservedObject var modelManager = ModelManager.shared
    @State private var showingResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FluentSpacing.sectionSpacing) {
                // Model Section
                FluentSettingsSection("Whisper Model", icon: "cpu") {
                    ModelSettingsCard()
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
        .alert("Reset All Settings?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                settingsService.resetAllSettings()
            }
        } message: {
            Text("This will reset all settings to their default values. The downloaded model will not be affected.")
        }
    }
}

struct ModelSettingsCard: View {
    @ObservedObject var modelManager = ModelManager.shared
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: FluentSpacing.md) {
            HStack(spacing: FluentSpacing.md) {
                // Status indicator with icon background
                Image(systemName: statusIcon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(statusColor)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: FluentRadius.sm)
                            .fill(statusColor.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: FluentSpacing.xxs) {
                    Text("Whisper Small Model")
                        .font(.Fluent.titleSmall)

                    Text(statusText)
                        .font(.Fluent.caption)
                        .foregroundStyle(FluentColors.textSecondary)
                }

                Spacer()

                actionButton
            }

            // Progress bar when downloading
            if case .downloading(let progress) = modelManager.state {
                VStack(spacing: FluentSpacing.xs) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)

                    HStack {
                        Text("\(Int(progress * 100))%")
                            .font(.Fluent.monoSmall)
                            .foregroundStyle(FluentColors.textSecondary)

                        Spacer()

                        Text(modelManager.modelSizeDescription)
                            .font(.Fluent.caption)
                            .foregroundStyle(FluentColors.textSecondary)
                    }
                }
            }

            // Model info when ready
            if modelManager.state.isReady || modelManager.state == .downloaded {
                FluentDivider(inset: true)

                HStack {
                    VStack(alignment: .leading, spacing: FluentSpacing.xxs) {
                        Text("Model Info")
                            .font(.Fluent.caption)
                            .foregroundStyle(FluentColors.textSecondary)

                        Text("Small model - Better accuracy for multilingual")
                            .font(.Fluent.caption)
                            .foregroundStyle(FluentColors.textTertiary)
                    }

                    Spacer()

                    FluentButton("Delete", icon: "trash", variant: .destructive, size: .small) {
                        showingDeleteConfirmation = true
                    }
                }
            }
        }
        .alert("Delete Model?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                modelManager.deleteModel()
            }
        } message: {
            Text("This will delete the downloaded model. You'll need to download it again to use transcription.")
        }
    }

    private var statusIcon: String {
        switch modelManager.state {
        case .notDownloaded:
            return "arrow.down.circle"
        case .downloading, .retrying:
            return "arrow.down.circle"
        case .downloaded:
            return "checkmark.circle"
        case .loading:
            return "arrow.clockwise.circle"
        case .ready:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch modelManager.state {
        case .notDownloaded:
            return FluentColors.warning
        case .downloading, .retrying, .loading:
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
            return "Not downloaded (\(modelManager.modelSizeDescription))"
        case .downloading:
            return "Downloading..."
        case .retrying(let attempt, let maxAttempts):
            return "Retrying download (\(attempt)/\(maxAttempts))..."
        case .downloaded:
            return "Downloaded - tap Load to activate"
        case .loading:
            return "Loading model..."
        case .ready:
            return "Ready for transcription"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch modelManager.state {
        case .notDownloaded, .error:
            FluentButton("Download", icon: "arrow.down.circle", variant: .primary) {
                Task {
                    try? await modelManager.downloadModel()
                }
            }
        case .downloading, .retrying:
            FluentButton("Cancel", icon: "xmark", variant: .secondary) {
                modelManager.cancelDownload()
            }
        case .downloaded:
            FluentButton("Load", icon: "play.fill", variant: .primary) {
                Task {
                    try? await modelManager.loadModel()
                }
            }
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .ready:
            FluentStatusBadge(variant: .success)
        }
    }
}

struct TranscriptionSettingsCard: View {
    @ObservedObject var settingsService = SettingsService.shared

    var body: some View {
        VStack(spacing: FluentSpacing.md) {
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

            FluentDivider(inset: true)

            FluentToggle(
                title: "Remove from Dock when closed",
                description: "Hide from Dock when window closes. Access via menu bar.",
                isOn: $settingsService.settings.removeFromDockOnClose
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

            Text("An open-source voice dictation app for macOS.\nPowered by local WhisperKit for 100% offline transcription.")
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

#Preview {
    SettingsView()
}
