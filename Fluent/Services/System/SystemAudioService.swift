import Foundation

/// Service for controlling system audio mute state during recording.
/// Uses AppleScript via osascript to query and set system mute state.
class SystemAudioService {
    static let shared = SystemAudioService()

    /// Tracks whether we muted the system (to avoid unmuting if user had it muted)
    private var didMuteSystem = false

    private init() {}

    // MARK: - Public API

    /// Mutes system audio before recording starts.
    /// Saves the previous mute state to restore later.
    func muteForRecording() {
        // Only mute if not already muted (don't interfere with user's choice)
        if !isSystemMuted() {
            setSystemMuted(true)
            didMuteSystem = true
        } else {
            didMuteSystem = false
        }
    }

    /// Restores system audio after recording ends.
    /// Only unmutes if we were the ones who muted it.
    func restoreAfterRecording() {
        // Only unmute if we muted it
        if didMuteSystem {
            setSystemMuted(false)
            didMuteSystem = false
        }
    }

    // MARK: - Private Helpers

    /// Queries current system mute state via AppleScript.
    /// - Returns: `true` if system is muted, `false` otherwise
    private func isSystemMuted() -> Bool {
        let script = "output muted of (get volume settings)"
        guard let result = runAppleScript(script) else {
            return false // Assume not muted if we can't determine
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Sets the system mute state via AppleScript.
    /// - Parameter muted: `true` to mute, `false` to unmute
    private func setSystemMuted(_ muted: Bool) {
        let script = muted ? "set volume with output muted" : "set volume without output muted"
        _ = runAppleScript(script)
    }

    /// Runs an AppleScript command via osascript.
    /// - Parameter script: The AppleScript to execute
    /// - Returns: The output string, or nil on failure
    private func runAppleScript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
