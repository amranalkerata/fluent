import AVFoundation
import CoreAudio

/// Manages audio input device detection and selection.
/// Prefers external microphones (headphones/earphones) over the built-in mic.
final class AudioDeviceManager {
    static let shared = AudioDeviceManager()

    private var preferredDeviceID: AudioDeviceID = kAudioObjectUnknown

    private init() {
        refreshPreferredDevice()
        listenForDeviceChanges()
    }

    // MARK: - Public

    /// Sets the preferred input device on an AVAudioEngine before it starts.
    func configureDevice(on engine: AVAudioEngine) async {
        let deviceID = preferredDeviceID
        guard deviceID != kAudioObjectUnknown else { return }

        guard let audioUnit = engine.inputNode.audioUnit else { return }

        // AudioUnitSetProperty can block for Bluetooth device negotiation — run off main thread
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var id = deviceID
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status != noErr {
                    print("[AudioDeviceManager] Failed to set device \(deviceID), status: \(status)")
                }
                continuation.resume()
            }
        }
    }

    // MARK: - Device Enumeration

    private func refreshPreferredDevice() {
        let devices = inputDevices()

        // Only override when an external (non-built-in) device is available.
        // Built-in mic is the system default — no need to set it explicitly.
        if let external = devices.first(where: { !isBuiltIn($0) }) {
            preferredDeviceID = external
        } else {
            preferredDeviceID = kAudioObjectUnknown
        }
    }

    /// Returns all audio devices that have at least one input stream.
    private func inputDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &devices
        ) == noErr else { return [] }

        return devices.filter { hasInputStreams($0) }
    }

    private func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    // MARK: - Device Type Detection

    private func isBuiltIn(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType) == noErr else {
            return true // Assume built-in if we can't determine
        }
        return transportType == kAudioDeviceTransportTypeBuiltIn
    }

    // MARK: - Device Change Listener

    private func listenForDeviceChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil
        ) { [weak self] _, _ in
            self?.refreshPreferredDevice()
        }
    }
}
