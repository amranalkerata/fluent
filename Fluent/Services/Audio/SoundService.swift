import AppKit

class SoundService {
    static let shared = SoundService()
    private var sound: NSSound?

    private init() {
        if let url = Bundle.main.url(forResource: "sound", withExtension: "m4a") {
            sound = NSSound(contentsOf: url, byReference: true)
        }
    }

    func playRecordingSound() {
        sound?.stop()
        sound?.play()
    }
}
