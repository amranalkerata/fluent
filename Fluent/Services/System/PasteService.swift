import AppKit

class PasteService {
    static let shared = PasteService()

    private var isPasting = false
    private var lastPasteTime: Date?
    private let pasteDebounceInterval: TimeInterval = 1.0 // Minimum 1 second between pastes

    private init() {}

    /// Paste text directly or copy to clipboard
    /// - Parameters:
    ///   - text: The text to paste or copy
    ///   - autoPaste: If true, inject text directly without using clipboard. If false, just copy to clipboard.
    func pasteText(_ text: String, autoPaste: Bool = true) {
        // Prevent rapid-fire paste operations
        let now = Date()
        if let lastPaste = lastPasteTime,
           now.timeIntervalSince(lastPaste) < pasteDebounceInterval {
            return
        }

        guard !isPasting else {
            return
        }

        guard !text.isEmpty else {
            return
        }

        isPasting = true
        lastPasteTime = now

        if autoPaste {
            // Direct injection - never touches clipboard
            injectTextDirectly(text)
        } else {
            // Explicit copy request - use clipboard
            copyToClipboard(text)
            isPasting = false
        }
    }

    /// Inject text directly into the focused application using CGEvent
    /// This bypasses the clipboard entirely, preserving whatever the user had copied
    private func injectTextDirectly(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            isPasting = false
            return
        }

        // CGEventKeyboardSetUnicodeString has a limit of ~20 characters per event
        // For longer text, we need to chunk it
        let maxChunkSize = 20
        let utf16Chars = Array(text.utf16)

        // Small delay to ensure target app is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.injectChunks(utf16Chars: utf16Chars, maxChunkSize: maxChunkSize, source: source, index: 0)
        }
    }

    /// Recursively inject text in chunks (CGEvent has a ~20 char limit per event)
    private func injectChunks(utf16Chars: [UInt16], maxChunkSize: Int, source: CGEventSource, index: Int) {
        guard index < utf16Chars.count else {
            // All chunks processed
            isPasting = false
            return
        }

        let endIndex = min(index + maxChunkSize, utf16Chars.count)
        var chunk = Array(utf16Chars[index..<endIndex])

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            isPasting = false
            return
        }

        keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
        keyDown.post(tap: .cghidEventTap)

        // Brief delay between key events
        usleep(1000) // 1ms

        keyUp.post(tap: .cghidEventTap)

        // Process next chunk after a small delay
        if endIndex < utf16Chars.count {
            usleep(2000) // 2ms between chunks
            injectChunks(utf16Chars: utf16Chars, maxChunkSize: maxChunkSize, source: source, index: endIndex)
        } else {
            isPasting = false
        }
    }

    /// Copy text to clipboard without pasting
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Get the name of the currently focused application
    func getFocusedApplicationName() -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return frontApp.localizedName
    }

    /// Get the bundle identifier of the currently focused application
    func getFocusedApplicationBundleIdentifier() -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return frontApp.bundleIdentifier
    }
}
