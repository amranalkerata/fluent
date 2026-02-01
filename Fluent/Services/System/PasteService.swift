import AppKit
import os.log

/// Result of a paste operation
enum PasteResult {
    case success
    case debounced           // Rejected due to 1-second debounce
    case alreadyPasting      // Previous paste still in progress
    case emptyText           // No text to paste
    case clipboardFailed     // Failed to set clipboard content
    case eventSourceFailed   // CGEventSource creation failed
    case eventCreationFailed // CGEvent creation failed

    var succeeded: Bool {
        self == .success
    }
}

private let pasteLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.fluent", category: "PasteService")

class PasteService {
    static let shared = PasteService()

    private var isPasting = false
    private var lastPasteTime: Date?
    private let pasteDebounceInterval: TimeInterval = 1.0 // Minimum 1 second between pastes
    private let maxRetries = 3
    private let retryDelay: UInt32 = 50_000 // 50ms in microseconds

    private init() {}

    /// Paste text using clipboard + Cmd+V (reliable approach)
    /// - Parameters:
    ///   - text: The text to paste or copy
    ///   - autoPaste: If true, simulate Cmd+V after copying to clipboard. If false, just copy to clipboard.
    ///   - completion: Called with the result of the paste operation
    func pasteText(_ text: String, autoPaste: Bool = true, completion: ((PasteResult) -> Void)? = nil) {
        // Prevent rapid-fire paste operations
        let now = Date()
        if let lastPaste = lastPasteTime,
           now.timeIntervalSince(lastPaste) < pasteDebounceInterval {
            pasteLogger.warning("Paste debounced - last paste was \(now.timeIntervalSince(lastPaste), privacy: .public)s ago")
            completion?(.debounced)
            return
        }

        guard !isPasting else {
            pasteLogger.warning("Paste rejected - another paste operation is in progress")
            completion?(.alreadyPasting)
            return
        }

        guard !text.isEmpty else {
            pasteLogger.warning("Paste rejected - text is empty")
            completion?(.emptyText)
            return
        }

        isPasting = true
        lastPasteTime = now

        if autoPaste {
            // Save old clipboard content to restore later
            let oldContent = NSPasteboard.general.string(forType: .string)

            // Copy new text to clipboard
            copyToClipboard(text)
            pasteLogger.debug("Text copied to clipboard (\(text.count) chars)")

            // Verify clipboard and paste with retries
            verifyClipboardAndPaste(
                expectedText: text,
                oldContent: oldContent,
                retriesRemaining: maxRetries,
                completion: completion
            )
        } else {
            // Just copy to clipboard without pasting
            copyToClipboard(text)
            isPasting = false
            completion?(.success)
        }
    }

    /// Verify clipboard has correct content and simulate Cmd+V paste
    /// Retries up to maxRetries times if clipboard verification fails
    private func verifyClipboardAndPaste(
        expectedText: String,
        oldContent: String?,
        retriesRemaining: Int,
        completion: ((PasteResult) -> Void)?
    ) {
        // Verify clipboard has the expected content
        let currentClipboard = NSPasteboard.general.string(forType: .string)

        if currentClipboard == expectedText {
            // Clipboard is correct, simulate paste
            let pasteSucceeded = simulatePaste()

            if pasteSucceeded {
                pasteLogger.info("Paste completed successfully via Cmd+V")

                // Restore old clipboard content after a brief delay
                // to ensure paste has been processed
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    if let oldContent = oldContent {
                        self?.copyToClipboard(oldContent)
                        pasteLogger.debug("Restored previous clipboard content")
                    }
                    self?.isPasting = false
                    completion?(.success)
                }
            } else {
                pasteLogger.error("Cmd+V simulation failed")
                isPasting = false
                completion?(.eventCreationFailed)
            }
        } else if retriesRemaining > 0 {
            // Clipboard doesn't match, retry after delay
            pasteLogger.warning("Clipboard verification failed, retrying (\(retriesRemaining) attempts remaining)")
            usleep(retryDelay)

            // Re-copy to clipboard and retry
            copyToClipboard(expectedText)
            verifyClipboardAndPaste(
                expectedText: expectedText,
                oldContent: oldContent,
                retriesRemaining: retriesRemaining - 1,
                completion: completion
            )
        } else {
            // Out of retries
            pasteLogger.error("Clipboard verification failed after \(self.maxRetries) retries - text remains in clipboard for manual paste")
            isPasting = false
            completion?(.clipboardFailed)
        }
    }

    /// Simulate Cmd+V keystroke to paste from clipboard
    /// - Returns: true if the keystroke was successfully posted
    private func simulatePaste() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            pasteLogger.error("Failed to create CGEventSource for Cmd+V")
            return false
        }

        // Virtual key code for 'V' is 9
        let vKeyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            pasteLogger.error("Failed to create CGEvent for Cmd+V")
            return false
        }

        // Add Command modifier
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // Post the events
        keyDown.post(tap: .cghidEventTap)
        usleep(1000) // 1ms delay between key down and up
        keyUp.post(tap: .cghidEventTap)

        pasteLogger.debug("Cmd+V keystroke posted")
        return true
    }

    /// Copy text to clipboard
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
