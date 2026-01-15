import AppKit
import Carbon.HIToolbox

class PasteService {
    static let shared = PasteService()

    private var isPasting = false
    private var lastPasteTime: Date?
    private let pasteDebounceInterval: TimeInterval = 1.0 // Minimum 1 second between pastes

    private init() {}

    /// Copy text to clipboard and optionally paste it
    func pasteText(_ text: String, autoPaste: Bool = true) {
        // Prevent rapid-fire paste operations
        let now = Date()
        if let lastPaste = lastPasteTime,
           now.timeIntervalSince(lastPaste) < pasteDebounceInterval {
            print("Paste debounced - too soon since last paste")
            return
        }
        
        guard !isPasting else {
            print("Paste already in progress, ignoring")
            return
        }
        
        guard !text.isEmpty else {
            print("Cannot paste empty text")
            return
        }
        
        isPasting = true
        lastPasteTime = now
        
        // 1. Save old clipboard content (to restore if paste fails)
        let pasteboard = NSPasteboard.general
        let oldContent = pasteboard.string(forType: .string)
        
        // 2. Clear and set new content
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        
        guard success else {
            print("Failed to set clipboard content")
            isPasting = false
            return
        }

        // 3. Auto-paste if enabled
        if autoPaste {
            // Verify clipboard update with retries, then paste
            verifyClipboardAndPaste(expectedText: text, oldContent: oldContent, retries: 3)
        } else {
            isPasting = false
        }
    }
    
    /// Verify clipboard contains expected text before pasting
    private func verifyClipboardAndPaste(expectedText: String, oldContent: String?, retries: Int) {
        let pasteboard = NSPasteboard.general
        
        // Check if clipboard has the expected content
        if let currentContent = pasteboard.string(forType: .string),
           currentContent == expectedText {
            // Clipboard is correct, proceed with paste
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.simulatePaste()
                // Reset paste lock after paste completes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self?.isPasting = false
                }
            }
        } else if retries > 0 {
            // Retry after a short delay
            print("Clipboard verification failed, retrying... (\(retries) left)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.verifyClipboardAndPaste(expectedText: expectedText, oldContent: oldContent, retries: retries - 1)
            }
        } else {
            // Failed after all retries - restore old clipboard content
            print("Failed to verify clipboard after all retries")
            if let old = oldContent {
                pasteboard.clearContents()
                pasteboard.setString(old, forType: .string)
            }
            isPasting = false
        }
    }

    /// Copy text to clipboard without pasting
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Simulate Cmd+V keystroke to paste
    private func simulatePaste() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            print("Failed to create event source for paste simulation")
            return
        }

        // V key virtual key code is 9
        let vKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_V)

        // Create key down event with Command modifier
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            print("Failed to create keyboard events for paste simulation")
            return
        }

        // Set Command modifier
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // Post events to the system
        keyDown.post(tap: .cghidEventTap)

        // Small delay between key down and up
        usleep(10000) // 10ms

        keyUp.post(tap: .cghidEventTap)
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
