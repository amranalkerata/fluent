import Foundation
import Combine
import Carbon.HIToolbox
import AppKit

class HotkeyService: ObservableObject {
    static let shared = HotkeyService()

    @Published var shortcutConfiguration: ShortcutConfiguration
    @Published var isRecordingShortcut = false
    @Published var lastRecordedShortcut: KeyboardShortcut?

    private var fnKeyWasPressed = false
    private var lastFnPressTime: Date?
    private let fnKeyDebounceInterval: TimeInterval = 0.5 // Increased from 0.3 to prevent double-triggers

    // Track last action trigger to prevent rapid-fire
    private var lastActionTriggerTime: [ShortcutAction: Date] = [:]
    private let actionDebounceInterval: TimeInterval = 0.5 // Prevent same action within 0.5s

    private let settingsService = SettingsService.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Load saved configuration or use defaults
        shortcutConfiguration = settingsService.loadShortcutConfiguration() ?? .default
        setupAutoSave()
    }

    private func setupAutoSave() {
        $shortcutConfiguration
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] config in
                self?.settingsService.saveShortcutConfiguration(config)
            }
            .store(in: &cancellables)
    }

    // MARK: - Event Processing

    func processKeyEvent(keyCode: UInt16, modifiers: CGEventFlags, isKeyDown: Bool) {
        // If recording a shortcut, capture it
        if isRecordingShortcut && isKeyDown {
            captureShortcut(keyCode: keyCode, modifiers: modifiers)
            return
        }

        guard isKeyDown else { return }

        // Check against registered shortcuts
        for action in ShortcutAction.allCases {
            let shortcuts = shortcutConfiguration.shortcuts(for: action)
            for shortcut in shortcuts {
                if shortcut.matches(keyCode: keyCode, modifiers: modifiers) {
                    triggerAction(action)
                    return
                }
            }
        }
    }

    func handleFlagsChanged(flags: CGEventFlags) {
        let fnKeyIsPressed = flags.contains(.maskSecondaryFn)

        // Detect Fn key press (transition from not pressed to pressed)
        if fnKeyIsPressed && !fnKeyWasPressed {
            handleFnKeyPressed()
        } else if !fnKeyIsPressed && fnKeyWasPressed {
            handleFnKeyReleased()
        }

        fnKeyWasPressed = fnKeyIsPressed
    }

    private func handleFnKeyPressed() {
        let now = Date()

        // Debounce to prevent multiple triggers
        if let lastPress = lastFnPressTime,
           now.timeIntervalSince(lastPress) < fnKeyDebounceInterval {
            return
        }

        lastFnPressTime = now

        // If recording a shortcut, capture Fn
        if isRecordingShortcut {
            captureShortcut(keyCode: nil, modifiers: CGEventFlags(), isFnKey: true)
            return
        }

        // Check if Fn is registered for any action
        for action in ShortcutAction.allCases {
            let shortcuts = shortcutConfiguration.shortcuts(for: action)
            for shortcut in shortcuts {
                if shortcut.isFnKey {
                    triggerAction(action)
                    return
                }
            }
        }
    }

    private func handleFnKeyReleased() {
        // Can be used for press-and-hold behavior in the future
    }

    private func triggerAction(_ action: ShortcutAction) {
        let now = Date()

        // Debounce to prevent multiple triggers of the same action
        if let lastTrigger = lastActionTriggerTime[action],
           now.timeIntervalSince(lastTrigger) < actionDebounceInterval {
            return
        }

        lastActionTriggerTime[action] = now

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .shortcutTriggered, object: action)
        }
    }

    // MARK: - Shortcut Recording

    func startRecordingShortcut() {
        isRecordingShortcut = true
        lastRecordedShortcut = nil
    }

    func stopRecordingShortcut() {
        isRecordingShortcut = false
    }

    private func captureShortcut(keyCode: UInt16?, modifiers: CGEventFlags, isFnKey: Bool = false) {
        let shortcut: KeyboardShortcut

        if isFnKey {
            shortcut = .fnKey
        } else if let keyCode = keyCode {
            shortcut = KeyboardShortcut(
                keyCode: keyCode,
                modifiers: modifiers.rawValue,
                isFnKey: false
            )
        } else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.lastRecordedShortcut = shortcut
            self?.isRecordingShortcut = false
        }
    }

    // MARK: - Shortcut Management

    func addShortcut(_ shortcut: KeyboardShortcut, for action: ShortcutAction) {
        // Check for duplicates across all actions
        for otherAction in ShortcutAction.allCases {
            let existing = shortcutConfiguration.shortcuts(for: otherAction)
            if existing.contains(where: { $0 == shortcut }) {
                // Remove from other action first
                shortcutConfiguration.removeShortcut(shortcut, from: otherAction)
            }
        }

        shortcutConfiguration.addShortcut(shortcut, for: action)
    }

    func removeShortcut(_ shortcut: KeyboardShortcut, from action: ShortcutAction) {
        shortcutConfiguration.removeShortcut(shortcut, from: action)
    }

    func resetToDefaults() {
        shortcutConfiguration = .default
    }

    // MARK: - Validation

    func isShortcutAvailable(_ shortcut: KeyboardShortcut, excluding action: ShortcutAction? = nil) -> Bool {
        for checkAction in ShortcutAction.allCases {
            if checkAction == action { continue }

            let shortcuts = shortcutConfiguration.shortcuts(for: checkAction)
            if shortcuts.contains(where: { $0 == shortcut }) {
                return false
            }
        }
        return true
    }

    func conflictingAction(for shortcut: KeyboardShortcut) -> ShortcutAction? {
        for action in ShortcutAction.allCases {
            let shortcuts = shortcutConfiguration.shortcuts(for: action)
            if shortcuts.contains(where: { $0 == shortcut }) {
                return action
            }
        }
        return nil
    }
}
