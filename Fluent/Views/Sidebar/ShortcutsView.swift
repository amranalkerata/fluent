import SwiftUI

struct ShortcutsView: View {
    @ObservedObject var hotkeyService = HotkeyService.shared
    @State private var selectedAction: ShortcutAction?
    @State private var showingResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FluentSpacing.sectionSpacing) {
                // Header
                VStack(alignment: .leading, spacing: FluentSpacing.sm) {
                    Text("Keyboard Shortcuts")
                        .font(.Fluent.headlineMedium)

                    Text("Configure global hotkeys for Fluent. You can assign multiple shortcuts to each action.")
                        .font(.Fluent.bodyMedium)
                        .foregroundStyle(FluentColors.textSecondary)
                }
                .fluentAppear(delay: 0)

                // Permission Status
                PermissionStatusCard()
                    .fluentAppear(delay: 0.05)

                // Shortcuts List
                VStack(spacing: FluentSpacing.lg) {
                    ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                        ShortcutActionCard(
                            action: action,
                            shortcuts: hotkeyService.shortcutConfiguration.shortcuts(for: action),
                            onAddShortcut: {
                                selectedAction = action
                            },
                            onRemoveShortcut: { shortcut in
                                hotkeyService.removeShortcut(shortcut, from: action)
                            }
                        )
                        .fluentAppear(delay: 0.1 + Double(index) * 0.03)
                    }
                }

                // Reset Button
                HStack {
                    Spacer()
                    FluentButton("Reset to Defaults", variant: .tertiary) {
                        showingResetConfirmation = true
                    }
                }
            }
            .padding(FluentSpacing.pagePadding)
        }
        .background(FluentColors.background)
        .navigationTitle("Shortcuts")
        .sheet(item: $selectedAction) { action in
            ShortcutRecorderSheet(action: action)
        }
        .alert("Reset Shortcuts?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                hotkeyService.resetToDefaults()
            }
        } message: {
            Text("This will reset all shortcuts to their default values.")
        }
    }
}

struct PermissionStatusCard: View {
    @ObservedObject var permissionService = PermissionService.shared
    @State private var isHovered = false

    var body: some View {
        let isGranted = permissionService.inputMonitoringStatus == .authorized

        HStack(spacing: FluentSpacing.md) {
            Image(systemName: isGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.title2)
                .foregroundStyle(isGranted ? FluentColors.success : FluentColors.warning)

            VStack(alignment: .leading, spacing: FluentSpacing.xxs) {
                Text(isGranted ? "Input Monitoring Enabled" : "Input Monitoring Required")
                    .font(.Fluent.headlineSmall)

                Text(isGranted
                     ? "Global shortcuts are working"
                     : "Enable Input Monitoring in System Settings to use global shortcuts")
                    .font(.Fluent.caption)
                    .foregroundStyle(FluentColors.textSecondary)
            }

            Spacer()

            if !isGranted {
                FluentButton("Open Settings", icon: "gear", variant: .primary, size: .small) {
                    permissionService.openInputMonitoringSettings()
                }
            }
        }
        .padding(FluentSpacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: FluentRadius.lg)
                .fill(isGranted ? FluentColors.success.opacity(0.1) : FluentColors.warning.opacity(0.1))
        )
        .fluentShadow(isHovered ? .medium : .low)
        .animation(FluentAnimation.fast, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct ShortcutActionCard: View {
    let action: ShortcutAction
    let shortcuts: [KeyboardShortcut]
    let onAddShortcut: () -> Void
    let onRemoveShortcut: (KeyboardShortcut) -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: FluentSpacing.md) {
            // Action header
            HStack {
                VStack(alignment: .leading, spacing: FluentSpacing.xxs) {
                    Text(action.displayName)
                        .font(.Fluent.headlineSmall)

                    Text(action.description)
                        .font(.Fluent.caption)
                        .foregroundStyle(FluentColors.textSecondary)
                }

                Spacer()

                FluentIconButton(icon: "plus.circle", color: FluentColors.primary) {
                    onAddShortcut()
                }
                .help("Add shortcut")
            }

            // Shortcuts
            if shortcuts.isEmpty {
                Text("No shortcuts assigned")
                    .font(.Fluent.bodyMedium)
                    .foregroundStyle(FluentColors.textTertiary)
                    .padding(.vertical, FluentSpacing.sm)
            } else {
                FlowLayout(spacing: FluentSpacing.sm) {
                    ForEach(shortcuts) { shortcut in
                        ShortcutBadge(shortcut: shortcut) {
                            onRemoveShortcut(shortcut)
                        }
                    }
                }
            }
        }
        .padding(FluentSpacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: FluentRadius.lg)
                .fill(FluentColors.surface)
        )
        .fluentShadow(isHovered ? .medium : .low)
        .animation(FluentAnimation.fast, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct ShortcutBadge: View {
    let shortcut: KeyboardShortcut
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: FluentSpacing.xs) {
            Text(shortcut.humanReadableString)
                .font(.Fluent.roundedSmall)

            if isHovering {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(FluentColors.textSecondary)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, FluentSpacing.md)
        .padding(.vertical, FluentSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: FluentRadius.md)
                .fill(FluentColors.primary.opacity(0.15))
        )
        .onHover { hovering in
            withAnimation(FluentAnimation.fast) {
                isHovering = hovering
            }
        }
    }
}

struct ShortcutRecorderSheet: View {
    let action: ShortcutAction
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var hotkeyService = HotkeyService.shared
    @State private var isRecording = false
    @State private var recordedShortcut: KeyboardShortcut?
    @State private var conflictAction: ShortcutAction?

    var body: some View {
        VStack(spacing: FluentSpacing.sectionSpacing) {
            // Header
            Text("Add Shortcut for \(action.displayName)")
                .font(.Fluent.headlineSmall)

            // Recording area
            VStack(spacing: FluentSpacing.lg) {
                if isRecording {
                    VStack(spacing: FluentSpacing.md) {
                        Text("Press your shortcut keys...")
                            .font(.Fluent.titleLarge)
                            .foregroundStyle(FluentColors.textSecondary)

                        ProgressView()
                            .controlSize(.small)

                        Text("Press Fn alone or a key combination")
                            .font(.Fluent.caption)
                            .foregroundStyle(FluentColors.textTertiary)
                    }
                } else if let shortcut = recordedShortcut {
                    VStack(spacing: FluentSpacing.sm) {
                        Text(shortcut.humanReadableString)
                            .font(.Fluent.displayMedium)
                            .padding(FluentSpacing.cardPadding)
                            .background(
                                RoundedRectangle(cornerRadius: FluentRadius.lg)
                                    .fill(FluentColors.primary.opacity(0.1))
                            )

                        if let conflict = conflictAction {
                            HStack(spacing: FluentSpacing.xs) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("Already assigned to \"\(conflict.displayName)\"")
                            }
                            .font(.Fluent.caption)
                            .foregroundStyle(FluentColors.warning)
                        }
                    }
                } else {
                    Text("Click \"Record\" to capture a shortcut")
                        .font(.Fluent.titleLarge)
                        .foregroundStyle(FluentColors.textSecondary)
                }
            }
            .frame(height: 120)

            // Buttons
            HStack(spacing: FluentSpacing.md) {
                FluentButton("Cancel", variant: .tertiary) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if !isRecording && recordedShortcut == nil {
                    FluentButton("Record", icon: "record.circle", variant: .primary) {
                        startRecording()
                    }
                } else if isRecording {
                    FluentButton("Stop", icon: "stop.fill", variant: .secondary) {
                        stopRecording()
                    }
                } else {
                    FluentButton("Record Again", icon: "arrow.clockwise", variant: .secondary) {
                        recordedShortcut = nil
                        conflictAction = nil
                        startRecording()
                    }

                    FluentButton("Save", icon: "checkmark", variant: .primary) {
                        saveShortcut()
                    }
                    .disabled(recordedShortcut == nil)
                }
            }
        }
        .padding(FluentSpacing.pagePadding)
        .frame(width: 400, height: 280)
        .onReceive(hotkeyService.$lastRecordedShortcut) { shortcut in
            if let shortcut = shortcut, isRecording {
                recordedShortcut = shortcut
                isRecording = false

                // Check for conflicts
                if let conflict = hotkeyService.conflictingAction(for: shortcut), conflict != action {
                    conflictAction = conflict
                } else {
                    conflictAction = nil
                }
            }
        }
    }

    private func startRecording() {
        isRecording = true
        recordedShortcut = nil
        conflictAction = nil
        hotkeyService.startRecordingShortcut()
    }

    private func stopRecording() {
        isRecording = false
        hotkeyService.stopRecordingShortcut()
    }

    private func saveShortcut() {
        guard let shortcut = recordedShortcut else { return }
        hotkeyService.addShortcut(shortcut, for: action)
        dismiss()
    }
}

// MARK: - Flow Layout for multiple shortcuts

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)

        for (index, subview) in subviews.enumerated() {
            let position = result.positions[index]
            subview.place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        let maxX = proposal.width ?? .infinity

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxX && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxWidth = max(maxWidth, currentX)
        }

        return (CGSize(width: maxWidth, height: currentY + lineHeight), positions)
    }
}

#Preview {
    ShortcutsView()
}
