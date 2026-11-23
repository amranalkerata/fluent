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
    /// Returns true when it switched the engine away from the system default input.
    @discardableResult
    func configureDevice(on engine: AVAudioEngine) async -> Bool {
        let deviceID = preferredDeviceID
        guard deviceID != kAudioObjectUnknown else { return false }

        guard let audioUnit = engine.inputNode.audioUnit else { return false }

        // AudioUnitSetProperty can block for Bluetooth device negotiation — run off main thread
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
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
                continuation.resume(returning: status == noErr)
            }
        }
    }

    // MARK: - Device Enumeration

    private func refreshPreferredDevice() {
        // The user (or macOS) already picked an external mic as the default input:
        // respect it and don't override anything.
        let defaultInput = defaultInputDevice()
        if defaultInput != kAudioObjectUnknown && !isBuiltIn(defaultInput) {
            preferredDeviceID = kAudioObjectUnknown
            return
        }

        // Default is the built-in mic: prefer a connected headset / USB mic.
        // Never pick Continuity (iPhone), virtual (Teams, Zoom…) or aggregate devices —
        // they are listed as "external" but often can't be started on demand.
        preferredDeviceID = inputDevices().first(where: isHeadsetOrExternalMic) ?? kAudioObjectUnknown
    }

    private func defaultInputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return kAudioObjectUnknown }
        return deviceID
    }

    /// Name of the device the next recording will use (nil = system default input).
    var preferredDeviceName: String? {
        let deviceID = preferredDeviceID
        guard deviceID != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
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

    /// Real, physically connected microphones: Bluetooth headsets (AirPods…) and USB mics.
    private func isHeadsetOrExternalMic(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType) == noErr else {
            return false
        }
        return transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
            || transportType == kAudioDeviceTransportTypeUSB
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

        // The choice also depends on the default input, which can change on its own
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            nil
        ) { [weak self] _, _ in
            self?.refreshPreferredDevice()
        }
    }
}
