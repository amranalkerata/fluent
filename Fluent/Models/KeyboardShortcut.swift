import Foundation
import Carbon.HIToolbox
import AppKit

// MARK: - Shortcut Action

enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
    case toggleRecording = "toggle_recording"
    case startRecording = "start_recording"
    case stopRecording = "stop_recording"
    case cancelRecording = "cancel_recording"
    case openMainWindow = "open_main_window"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toggleRecording: return "Toggle Recording"
        case .startRecording: return "Start Recording"
        case .stopRecording: return "Stop Recording"
        case .cancelRecording: return "Cancel Recording"
        case .openMainWindow: return "Open Main Window"
        }
    }

    var description: String {
        switch self {
        case .toggleRecording: return "Start or stop voice recording"
        case .startRecording: return "Begin a new recording"
        case .stopRecording: return "Stop current recording and transcribe"
        case .cancelRecording: return "Cancel recording without transcribing"
        case .openMainWindow: return "Bring Fluent window to front"
        }
    }
}

// MARK: - Keyboard Shortcut

struct KeyboardShortcut: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var keyCode: UInt16?          // nil for modifier-only shortcuts like Fn
    var modifiers: UInt64         // CGEventFlags raw value
    var isFnKey: Bool             // Special flag for Fn key

    init(id: UUID = UUID(), keyCode: UInt16? = nil, modifiers: UInt64 = 0, isFnKey: Bool = false) {
        self.id = id
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isFnKey = isFnKey
    }

    // Create from NSEvent (for recording shortcuts)
    init(from event: NSEvent) {
        self.id = UUID()
        self.keyCode = UInt16(event.keyCode)
        self.modifiers = UInt64(event.modifierFlags.rawValue)
        self.isFnKey = false
    }

    // Create Fn key shortcut
    static var fnKey: KeyboardShortcut {
        KeyboardShortcut(id: UUID(), keyCode: nil, modifiers: 0, isFnKey: true)
    }

    // Create Option+Space shortcut
    static var optionSpace: KeyboardShortcut {
        KeyboardShortcut(
            id: UUID(),
            keyCode: UInt16(kVK_Space),
            modifiers: CGEventFlags.maskAlternate.rawValue,
            isFnKey: false
        )
    }

    var displayString: String {
        var parts: [String] = []

        let flags = CGEventFlags(rawValue: modifiers)

        if flags.contains(.maskControl) { parts.append("^") }
        if flags.contains(.maskAlternate) { parts.append("^") }
        if flags.contains(.maskShift) { parts.append("^") }
        if flags.contains(.maskCommand) { parts.append("^") }

        if isFnKey {
            return "fn"
        }

        if let keyCode = keyCode {
            parts.append(KeyCodeMapper.stringForKeyCode(keyCode))
        }

        return parts.joined()
    }

    var humanReadableString: String {
        var parts: [String] = []

        let flags = CGEventFlags(rawValue: modifiers)

        if flags.contains(.maskControl) { parts.append("Control") }
        if flags.contains(.maskAlternate) { parts.append("Option") }
        if flags.contains(.maskShift) { parts.append("Shift") }
        if flags.contains(.maskCommand) { parts.append("Command") }

        if isFnKey {
            return "Fn"
        }

        if let keyCode = keyCode {
            parts.append(KeyCodeMapper.stringForKeyCode(keyCode))
        }

        return parts.joined(separator: " + ")
    }

    func matches(keyCode: UInt16, modifiers: CGEventFlags) -> Bool {
        guard let selfKeyCode = self.keyCode else { return false }
        guard !isFnKey else { return false }

        let relevantModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        let selfFlags = CGEventFlags(rawValue: self.modifiers).intersection(relevantModifiers)
        let eventFlags = modifiers.intersection(relevantModifiers)

        return selfKeyCode == keyCode && selfFlags == eventFlags
    }

    func matchesFnKey(flags: CGEventFlags) -> Bool {
        return isFnKey && flags.contains(.maskSecondaryFn)
    }
}

// MARK: - Shortcut Configuration

struct ShortcutConfiguration: Codable {
    var shortcuts: [String: [KeyboardShortcut]] // ShortcutAction.rawValue -> shortcuts

    init(shortcuts: [ShortcutAction: [KeyboardShortcut]] = [:]) {
        self.shortcuts = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
    }

    func shortcuts(for action: ShortcutAction) -> [KeyboardShortcut] {
        return shortcuts[action.rawValue] ?? []
    }

    mutating func setShortcuts(_ newShortcuts: [KeyboardShortcut], for action: ShortcutAction) {
        shortcuts[action.rawValue] = newShortcuts
    }

    mutating func addShortcut(_ shortcut: KeyboardShortcut, for action: ShortcutAction) {
        var current = shortcuts[action.rawValue] ?? []
        current.append(shortcut)
        shortcuts[action.rawValue] = current
    }

    mutating func removeShortcut(_ shortcut: KeyboardShortcut, from action: ShortcutAction) {
        var current = shortcuts[action.rawValue] ?? []
        current.removeAll { $0.id == shortcut.id }
        shortcuts[action.rawValue] = current
    }

    static var `default`: ShortcutConfiguration {
        var config = ShortcutConfiguration()
        config.shortcuts = [
            ShortcutAction.toggleRecording.rawValue: [
                .fnKey,
                .optionSpace
            ]
        ]
        return config
    }
}

// MARK: - Key Code Mapper

struct KeyCodeMapper {
    static func stringForKeyCode(_ keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_Escape: return "Esc"
        case kVK_ForwardDelete: return "Fwd Del"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_LeftArrow: return ""
        case kVK_RightArrow: return ""
        case kVK_UpArrow: return ""
        case kVK_DownArrow: return ""
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        default: return "Key\(keyCode)"
        }
    }
}
