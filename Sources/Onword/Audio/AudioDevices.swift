import CoreAudio
import Foundation

/// Microphones known to Core Audio.
enum AudioDevices {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let isBluetooth: Bool
        /// A headset or external mic you plug in or pair (Bluetooth or USB), as opposed to the Mac's own mic
        /// or a virtual/aggregate device.
        let isHeadset: Bool
        /// The Mac's own microphone.
        let isBuiltIn: Bool
    }

    /// The Mac's own microphone, if it has one.
    static var builtInInput: Device? { inputs().first(where: \.isBuiltIn) }

    /// Microphone preference meaning "use a connected headset (AirPods, USB…), otherwise the system default".
    /// Also what no preference (nil) means.
    static let automatic = "auto"
    /// Microphone preference meaning "always follow macOS's default input".
    static let systemDefault = "system"

    /// The microphone to record from for a stored preference: nil/`automatic`, `systemDefault`, or a device UID.
    /// A chosen device that isn't connected falls back to the system default.
    static func resolve(preference: String?) -> Device? {
        switch preference {
        case nil, automatic?: return inputs().first(where: \.isHeadset) ?? defaultInput
        case systemDefault?: return defaultInput
        case let uid?: return device(uid: uid) ?? defaultInput
        }
    }

    /// Calls `onChange` on the main queue when microphones are connected or disconnected.
    static func addDeviceListListener(_ onChange: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        return block
    }

    static func removeDeviceListListener(_ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    static func inputs() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.filter(hasInput).compactMap(device)
    }

    static var defaultInput: Device? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return device(id)
    }

    static func device(uid: String) -> Device? {
        inputs().first { $0.uid == uid }
    }

    /// Calls `onChange` on the main queue whenever the system's default microphone changes
    /// (e.g. AirPods connect or disconnect). Returns a token for `removeListener`.
    static func addDefaultInputListener(_ onChange: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        var address = defaultInputAddress
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        return block
    }

    static func removeListener(_ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func device(_ id: AudioDeviceID) -> Device? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        let headset = bluetooth || transport == kAudioDeviceTransportTypeUSB
        return Device(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                      isBluetooth: bluetooth, isHeadset: headset, isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
