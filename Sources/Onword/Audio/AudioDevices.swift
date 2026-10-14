import CoreAudio
import IOKit
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
        /// Virtual and aggregate devices (Zoom, Teams, loopback drivers): listed under "Show other devices".
        var isVirtual = false
        var isUSB = false

        /// AirPods are slow to start and less accurate for dictation (Wispr Flow warns about them too).
        var isAirPods: Bool { name.localizedCaseInsensitiveContains("airpods") }

        /// As Wispr Flow names them: "Built-in mic (recommended)", "hot pot (Bluetooth)".
        var displayName: String {
            if isBuiltIn { return "Built-in mic (recommended)" }
            if isBluetooth { return "\(name) (Bluetooth)" }
            if isUSB { return "\(name) (USB)" }
            return name
        }
    }

    /// The Mac's own microphone, if it has one.
    static var builtInInput: Device? { inputs().first(where: \.isBuiltIn) }

    /// Earlier "headset first" preference; now treated as Auto-detect.
    static let automatic = "auto"
    /// "Auto-detect": whatever macOS uses ("From computer settings").
    static let systemDefault = "system"

    /// The microphone to record from for a stored preference. No preference means the built-in mic
    /// (Wispr Flow's recommendation); a chosen device that's gone falls back down your ranking
    /// (Settings → Microphone → Edit Ranking), then to the built-in mic, then to the system default.
    static func resolve(preference: String?) -> Device? {
        let all = inputs()
        switch preference {
        case automatic?, systemDefault?:
            return defaultInput
        case let uid?:
            if let chosen = all.first(where: { $0.uid == uid }), !(chosen.isBuiltIn && Clamshell.isClosed) { return chosen }
        case nil:
            break
        }
        // With the lid closed the built-in mic can't hear you: skip it unless nothing else is there.
        let lidClosed = Clamshell.isClosed
        for uid in MicRanking.uids where uid != systemDefault {
            if let ranked = all.first(where: { $0.uid == uid }), !(lidClosed && ranked.isBuiltIn) { return ranked }
        }
        if lidClosed, let other = defaultInput, !other.isBuiltIn { return other }
        return all.first(where: \.isBuiltIn) ?? defaultInput
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
        let virtual = transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeAutoAggregate
        return Device(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                      isBluetooth: bluetooth, isHeadset: headset, isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                      isVirtual: virtual, isUSB: transport == kAudioDeviceTransportTypeUSB)
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

/// Your microphone preference order (Settings → Microphone → Edit Ranking). Picking a mic moves it to the
/// top; when it's disconnected Onword uses the next one in the list that's connected. Devices seen before
/// stay in the list (dimmed when offline) until you forget them.
enum MicRanking {
    struct Entry: Codable, Equatable, Identifiable {
        var uid: String
        var name: String
        var id: String { uid }
    }

    private static let key = "micRanking"

    static var entries: [Entry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    static var uids: [String] { entries.map(\.uid) }

    /// The ranking with connected devices not in it yet appended, as the dialog shows it.
    /// Starts as Wispr Flow's: built-in mic, Auto-detect, then the others; mics connected later go to the end,
    /// so a newly paired headset never outranks the built-in mic.
    static func merged(with connected: [AudioDevices.Device]) -> [Entry] {
        var list = entries
        let fresh = list.isEmpty
        let newDevices = connected.filter { device in !device.isVirtual && !list.contains { $0.uid == device.uid } }
            .sorted { $0.isBuiltIn && !$1.isBuiltIn }
        for device in newDevices { list.append(Entry(uid: device.uid, name: device.displayName)) }
        if !list.contains(where: { $0.uid == AudioDevices.systemDefault }) {
            let afterBuiltIn = (list.firstIndex { e in connected.contains { $0.uid == e.uid && $0.isBuiltIn } } ?? -1) + 1
            list.insert(Entry(uid: AudioDevices.systemDefault, name: "Auto-detect"), at: fresh ? min(afterBuiltIn, list.count) : list.count)
        }
        return list
    }

    /// Picking a microphone puts it first.
    static func promote(_ uid: String, name: String, connected: [AudioDevices.Device]) {
        var list = merged(with: connected)
        list.removeAll { $0.uid == uid }
        list.insert(Entry(uid: uid, name: name), at: 0)
        entries = list
    }
}

/// Whether the Mac's lid is closed (with an external display), when the built-in mic can't hear you.
enum Clamshell {
    static var isClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }
}
