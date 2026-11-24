import AppKit
import Carbon.HIToolbox
import os.log

private let typingLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.fluent", category: "TypingService")

/// Pure text rules of live typing (no events posted), shared with the DEBUG self-test.
enum LiveTyping {
    /// One keyboard event's worth of text, or a Return key press.
    enum Piece: Equatable {
        case text(String)
        case newline
    }

    /// `CGEvent.keyboardSetUnicodeString` reliably carries at most 20 UTF-16 units.
    static let maxChunkUTF16 = 20

    /// Splits `text` into chunks of at most `maxChunkUTF16` UTF-16 units without splitting a
    /// `Character` (a single grapheme longer than the limit becomes its own chunk), and turns
    /// every line break ("\n", "\r\n", "\r", U+2028…) into `.newline`.
    static func pieces(for text: String) -> [Piece] {
        var pieces: [Piece] = []
        var chunk = ""
        var chunkUnits = 0
        func flush() {
            if !chunk.isEmpty { pieces.append(.text(chunk)) }
            chunk = ""
            chunkUnits = 0
        }
        for character in text {
            if character.isNewline {
                flush()
                pieces.append(.newline)
                continue
            }
            let units = character.utf16.count
            if chunkUnits + units > maxChunkUTF16 { flush() }
            chunk.append(character)
            chunkUnits += units
        }
        flush()
        return pieces
    }

    /// What goes between already-delivered text and the next part: nothing at the start, or
    /// when either side already has whitespace (or a line break) at the seam; otherwise one space.
    static func separator(after previous: String, before next: String) -> String {
        guard let last = previous.last, let first = next.first else { return "" }
        return last.isWhitespace || first.isWhitespace ? "" : " "
    }

    /// Parts joined with `separator`, exactly as they are typed one after the other.
    static func join(_ parts: [String]) -> String {
        parts.reduce(into: "") { text, part in
            text += separator(after: text, before: part) + part
        }
    }
}

/// Types text at the cursor of the frontmost app by posting keyboard events with the text
/// attached (no clipboard), the way live typing inserts each dictated phrase.
@MainActor
final class TypingService {
    static let shared = TypingService()

    /// Pause between two posted chunks so the receiving app keeps up.
    private static let chunkPauseNanoseconds: UInt64 = 2_000_000
    /// Virtual key code of Return.
    private static let returnKeyCode: CGKeyCode = 36

    private init() {}

    /// Whether another app (a password field, Terminal's Secure Keyboard Entry…) has secure
    /// input on, which hides posted keyboard events from it.
    var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    /// Types `text` into the frontmost app. Returns false, having typed nothing, when secure
    /// input is on or keyboard events cannot be created.
    func type(_ text: String) async -> Bool {
        guard !text.isEmpty else { return true }
        guard !isSecureInputActive else {
            typingLogger.info("Typing skipped - secure input is on")
            return false
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            typingLogger.error("Failed to create CGEventSource for typing")
            return false
        }

        let pieces = LiveTyping.pieces(for: text)
        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                try? await Task.sleep(nanoseconds: Self.chunkPauseNanoseconds)
            }
            let posted: Bool
            switch piece {
            case .text(let chunk):
                posted = post(source: source, virtualKey: 0, unicode: Array(chunk.utf16))
            case .newline:
                // Shift+Return: a line break in chat apps (Slack, WhatsApp, ChatGPT…), where a
                // plain Return would send the message mid-dictation; a newline everywhere else.
                posted = post(source: source, virtualKey: Self.returnKeyCode, unicode: nil, flags: .maskShift)
            }
            guard posted else {
                typingLogger.error("Failed to create CGEvent for typing")
                return false
            }
        }
        return true
    }

    /// Posts one key down + key up, carrying `unicode` when given, with exactly `flags` as modifiers.
    private func post(source: CGEventSource, virtualKey: CGKeyCode, unicode: [UniChar]?, flags: CGEventFlags = []) -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            return false
        }
        keyDown.flags = flags
        keyUp.flags = flags
        if let unicode {
            keyDown.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
            keyUp.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
