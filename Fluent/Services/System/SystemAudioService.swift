import Foundation
import CoreAudio

/// Mutes the system output while recording and restores it afterwards, through Core Audio's
/// mute property on the default output device (a few hundred microseconds, no child process).
///
/// Every call runs on a private serial queue, so mute and restore stay in order and the main
/// thread never waits on the audio hardware for a mute. Devices without a settable mute
/// (some HDMI and USB outputs) are left alone.
final class SystemAudioService {
    static let shared = SystemAudioService()

    private let queue = DispatchQueue(label: "com.fluent.system-audio", qos: .userInitiated)

    // State below is only touched on `queue`.
    /// The device and the mute elements we switched on; restore switches exactly these off.
    private var mutedDevice: AudioObjectID?
    private var mutedElements: [AudioObjectPropertyElement] = []
    /// Bumped by every mute/restore request so a delayed mute that lost the race does nothing.
    private var generation: UInt64 = 0

    private init() {}

    // MARK: - Public API

    /// Mutes system audio for the recording, unless it is already muted (the user's choice is
    /// left alone). Returns at once; the mute happens `delay` seconds later on a background queue,
    /// so a sound that is playing right now (the start sound) is not cut off.
    func muteForRecording(after delay: TimeInterval = 0) {
        queue.async {
            self.generation &+= 1
            let requested = self.generation
            self.queue.asyncAfter(deadline: .now() + max(0, delay)) {
                // A restore (or a newer mute) came in meanwhile: this mute is stale.
                guard requested == self.generation else { return }
                self.performMute()
            }
        }
    }

    /// Restores system audio after recording ends, only unmuting what we muted. Cancels a mute
    /// that has not happened yet. Waits for the Core Audio call (well under a millisecond) so
    /// a sound played right after this is audible.
    func restoreAfterRecording() {
        queue.sync {
            self.generation &+= 1
            self.performRestore()
        }
    }

    // MARK: - Mute / restore (on `queue`)

    private func performMute() {
        let start = LatencyLog.now()
        defer { LatencyLog.log("audio.mute", since: start) }

        guard mutedDevice == nil else { return } // already muted by us
        guard let device = Self.defaultOutputDevice() else { return }
        let elements = Self.settableMuteElements(of: device)
        guard !elements.isEmpty else {
            LatencyLog.logger.info("audio.mute skipped: output device has no settable mute")
            return
        }

        // Only switch on elements that are not muted yet, and remember them for the restore.
        var switched: [AudioObjectPropertyElement] = []
        for element in elements where Self.isMuted(device, element) == false {
            if Self.setMuted(true, device: device, element: element) {
                switched.append(element)
            }
        }
        if !switched.isEmpty {
            mutedDevice = device
            mutedElements = switched
        }
    }

    private func performRestore() {
        guard let device = mutedDevice else { return }
        let start = LatencyLog.now()
        for element in mutedElements {
            _ = Self.setMuted(false, device: device, element: element)
        }
        mutedDevice = nil
        mutedElements = []
        LatencyLog.log("audio.restore", since: start)
    }

    // MARK: - Core Audio helpers

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func muteAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func isMuteSettable(_ device: AudioObjectID, _ element: AudioObjectPropertyElement) -> Bool {
        var address = muteAddress(element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    /// The main mute element when the device has one, otherwise every output channel that has its own.
    private static func settableMuteElements(of device: AudioObjectID) -> [AudioObjectPropertyElement] {
        if isMuteSettable(device, kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        let channels = outputChannelCount(of: device)
        guard channels > 0 else { return [] }
        return (1...channels).map { AudioObjectPropertyElement($0) }.filter { isMuteSettable(device, $0) }
    }

    private static func outputChannelCount(of device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// nil when the mute state cannot be read.
    private static func isMuted(_ device: AudioObjectID, _ element: AudioObjectPropertyElement) -> Bool? {
        var address = muteAddress(element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMuted(_ muted: Bool, device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
        var address = muteAddress(element)
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    #if DEBUG
    /// Times the calls a mute makes (device lookup, element discovery, read, and a write of the
    /// current value, which changes nothing audible). Returns a one-line summary.
    func benchmarkCoreAudioCalls(iterations: Int = 20) -> String {
        queue.sync {
            var lookups: [Double] = [], writes: [Double] = []
            var summary = "no default output device"
            for _ in 0..<iterations {
                let start = LatencyLog.now()
                guard let device = Self.defaultOutputDevice() else { break }
                let elements = Self.settableMuteElements(of: device)
                let states = elements.map { Self.isMuted(device, $0) }
                lookups.append(LatencyLog.ms(since: start))
                let writeStart = LatencyLog.now()
                for (element, state) in zip(elements, states) {
                    if let state { _ = Self.setMuted(state, device: device, element: element) }
                }
                writes.append(LatencyLog.ms(since: writeStart))
                summary = "device=\(device) elements=\(elements) muted=\(states.map { $0.map(String.init) ?? "?" })"
            }
            let median = { (values: [Double]) in values.isEmpty ? 0 : values.sorted()[values.count / 2] }
            let maximum = { (values: [Double]) in values.max() ?? 0 }
            return summary + String(format: " | query median %.3f ms (max %.3f) | write-same-value median %.3f ms (max %.3f)",
                                    median(lookups), maximum(lookups), median(writes), maximum(writes))
        }
    }
    #endif
}
