import AppKit

class SoundService {
    static let shared = SoundService()
    private var sound: NSSound?

    private init() {
        if let url = Bundle.main.url(forResource: "sound", withExtension: "m4a") {
            sound = NSSound(contentsOf: url, byReference: true)
        }
    }

    /// Length of the start/stop sound in seconds (0 when it is missing).
    var recordingSoundDuration: TimeInterval {
        sound?.duration ?? 0
    }

    func playRecordingSound() {
        sound?.stop()
        sound?.play()
    }
}
