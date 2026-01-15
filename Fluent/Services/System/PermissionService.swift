import AVFoundation
import AppKit

enum PermissionStatus {
    case authorized
    case denied
    case notDetermined
    case restricted
}

class PermissionService: ObservableObject {
    static let shared = PermissionService()

    @Published var microphoneStatus: PermissionStatus = .notDetermined
    @Published var inputMonitoringStatus: PermissionStatus = .notDetermined
    @Published var accessibilityStatus: PermissionStatus = .notDetermined

    private init() {
        print("[PermissionService] init started")
        // Don't block init - refresh async to avoid main thread freeze
        Task {
            await refreshAllStatusesAsync()
        }
        print("[PermissionService] init completed (async refresh scheduled)")
    }

    func refreshAllStatuses() {
        print("[PermissionService] refreshAllStatuses called (sync)")
        refreshMicrophoneStatus()
        refreshInputMonitoringStatus()
        refreshAccessibilityStatus()
        print("[PermissionService] refreshAllStatuses completed")
    }

    /// Async version that moves blocking calls off main thread
    func refreshAllStatusesAsync() async {
        print("[PermissionService] refreshAllStatusesAsync started")

        // Run blocking system calls on background thread
        let (micStatus, inputTrusted, accessTrusted) = await Task.detached {
            print("[PermissionService] Checking permissions on background thread...")
            let mic = AVCaptureDevice.authorizationStatus(for: .audio)
            print("[PermissionService] Microphone status checked")
            let input = CGPreflightListenEventAccess()
            print("[PermissionService] Input monitoring checked: \(input)")
            let access = AXIsProcessTrusted()
            print("[PermissionService] Accessibility checked: \(access)")
            return (mic, input, access)
        }.value

        // Update UI on main thread
        await MainActor.run {
            self.microphoneStatus = self.convertAVAuthorizationStatus(micStatus)
            self.inputMonitoringStatus = inputTrusted ? .authorized : .denied
            self.accessibilityStatus = accessTrusted ? .authorized : .denied
            print("[PermissionService] UI updated with permission statuses")
        }

        print("[PermissionService] refreshAllStatusesAsync completed")
    }

    // MARK: - Microphone Permission

    func refreshMicrophoneStatus() {
        print("[PermissionService] refreshMicrophoneStatus called")
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneStatus = convertAVAuthorizationStatus(status)
        print("[PermissionService] Microphone status: \(microphoneStatus)")
    }

    func requestMicrophoneAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run {
            refreshMicrophoneStatus()
        }
        return granted
    }

    private func convertAVAuthorizationStatus(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        @unknown default: return .notDetermined
        }
    }

    // MARK: - Input Monitoring Permission (for CGEventTap)

    func refreshInputMonitoringStatus() {
        print("[PermissionService] refreshInputMonitoringStatus called (BLOCKING)")
        let trusted = CGPreflightListenEventAccess()
        inputMonitoringStatus = trusted ? .authorized : .denied
        print("[PermissionService] Input monitoring status: \(inputMonitoringStatus)")
    }

    func requestInputMonitoringAccess() {
        // This will prompt the user to go to System Settings
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)

        // Start polling for status change
        pollInputMonitoringStatus()
    }

    private func pollInputMonitoringStatus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.refreshInputMonitoringStatus()
            if self?.inputMonitoringStatus != .authorized {
                self?.pollInputMonitoringStatus()
            }
        }
    }

    // MARK: - Accessibility Permission (for paste simulation)

    func refreshAccessibilityStatus() {
        print("[PermissionService] refreshAccessibilityStatus called (BLOCKING)")
        let trusted = AXIsProcessTrusted()
        accessibilityStatus = trusted ? .authorized : .denied
        print("[PermissionService] Accessibility status: \(accessibilityStatus)")
    }

    func requestAccessibilityAccess() {
        // This will prompt the user to go to System Settings
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)

        // Start polling for status change
        pollAccessibilityStatus()
    }

    private func pollAccessibilityStatus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.refreshAccessibilityStatus()
            if self?.accessibilityStatus != .authorized {
                self?.pollAccessibilityStatus()
            }
        }
    }

    // MARK: - Open System Settings

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Check All Required Permissions

    var allRequiredPermissionsGranted: Bool {
        microphoneStatus == .authorized && inputMonitoringStatus == .authorized
    }

    var optionalPermissionsGranted: Bool {
        accessibilityStatus == .authorized
    }

    var missingRequiredPermissions: [String] {
        var missing: [String] = []
        if microphoneStatus != .authorized {
            missing.append("Microphone")
        }
        if inputMonitoringStatus != .authorized {
            missing.append("Input Monitoring")
        }
        return missing
    }
}
