import Cocoa
import Carbon.HIToolbox
import Combine

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var recordingOverlayWindow: RecordingOverlayWindow?
    private var cancellables = Set<AnyCancellable>()

    // Singleton for access from event tap callback
    static var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupNotificationObservers()
        checkAndRequestInputMonitoringPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        disableEventTap()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Keep running in menu bar
    }

    // MARK: - Notification Observers

    private func setupNotificationObservers() {
        NotificationCenter.default.publisher(for: .toggleRecording)
            .sink { [weak self] _ in
                self?.handleToggleRecording()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .showRecordingOverlay)
            .sink { [weak self] notification in
                if let appState = notification.object as? AppState {
                    self?.showRecordingOverlay(appState: appState)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .hideRecordingOverlay)
            .sink { [weak self] _ in
                self?.hideRecordingOverlay()
            }
            .store(in: &cancellables)
    }

    private func handleToggleRecording() {
        // Post to AppState to handle the actual toggle
        NotificationCenter.default.post(name: .performToggleRecording, object: nil)
    }

    // MARK: - Input Monitoring Permission

    private func checkAndRequestInputMonitoringPermission() {
        let trusted = CGPreflightListenEventAccess()
        if trusted {
            setupGlobalEventTap()
        } else {
            // Request permission - this will open System Settings
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(options as CFDictionary)

            // Poll for permission being granted
            pollForInputMonitoringPermission()
        }
    }

    private func pollForInputMonitoringPermission() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if CGPreflightListenEventAccess() {
                self?.setupGlobalEventTap()
            } else {
                self?.pollForInputMonitoringPermission()
            }
        }
    }

    // MARK: - Global Event Tap

    private func setupGlobalEventTap() {
        // Event mask for keyboard events including flagsChanged for Fn key
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
                                      (1 << CGEventType.keyUp.rawValue) |
                                      (1 << CGEventType.flagsChanged.rawValue)

        // Create event tap
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                return AppDelegate.handleGlobalEvent(proxy: proxy, type: type, event: event, refcon: refcon)
            },
            userInfo: nil
        ) else {
            print("Failed to create event tap - check Input Monitoring permission in System Settings")
            return
        }

        self.eventTap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("Global event tap enabled successfully")
    }

    private func disableEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private static func handleGlobalEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent,
        refcon: UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? {
        // Handle tap being disabled by the system
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = AppDelegate.shared?.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        // Handle Fn key via flagsChanged
        if type == .flagsChanged {
            let flags = event.flags
            HotkeyService.shared.handleFlagsChanged(flags: flags)
        }

        // Handle regular key events
        if type == .keyDown {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            HotkeyService.shared.processKeyEvent(keyCode: keyCode, modifiers: flags, isKeyDown: true)
        }

        if type == .keyUp {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            HotkeyService.shared.processKeyEvent(keyCode: keyCode, modifiers: flags, isKeyDown: false)
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - Recording Overlay Window

    func showRecordingOverlay(appState: AppState) {
        guard recordingOverlayWindow == nil else { return }

        let overlayView = RecordingOverlayView()
            .environmentObject(appState)
            .environmentObject(appState.audioService)

        recordingOverlayWindow = RecordingOverlayWindow(contentView: overlayView)
        recordingOverlayWindow?.orderFront(nil)
    }

    func hideRecordingOverlay() {
        recordingOverlayWindow?.close()
        recordingOverlayWindow = nil
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let toggleRecording = Notification.Name("toggleRecording")
    static let performToggleRecording = Notification.Name("performToggleRecording")
    static let showRecordingOverlay = Notification.Name("showRecordingOverlay")
    static let hideRecordingOverlay = Notification.Name("hideRecordingOverlay")
    static let fnKeyPressed = Notification.Name("fnKeyPressed")
    static let fnKeyReleased = Notification.Name("fnKeyReleased")
    static let shortcutTriggered = Notification.Name("shortcutTriggered")
}
