import AppKit
import CoreAudio

/// Which apps are using the microphone right now, from Core Audio's process list (macOS 14+).
/// This is the main signal for noticing a call.
enum MicHolders {
    struct Holder: Hashable {
        let pid: pid_t
        let bundleID: String
    }

    static func current() -> [Holder] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr
        else { return [] }

        let ownPID = getpid()
        return objects.compactMap { object -> Holder? in
            guard uint32(object, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            let pid = pid_t(bitPattern: uint32(object, kAudioProcessPropertyPID) ?? 0)
            guard pid > 0, pid != ownPID else { return nil }
            // Helper processes (e.g. a browser's audio service) report their own bundle ID;
            // attribute them to the app that owns them.
            let app = NSRunningApplication(processIdentifier: pid)
            let rawID = app?.bundleIdentifier ?? string(object, kAudioProcessPropertyBundleID) ?? ""
            let bundleID = owningAppBundleID(rawID)
            // Use the owning app's process (for its windows), e.g. Chrome's audio helper → Chrome.
            if bundleID != rawID, let parent = parentPID(of: pid),
               NSRunningApplication(processIdentifier: parent)?.bundleIdentifier == bundleID {
                return Holder(pid: parent, bundleID: bundleID)
            }
            return Holder(pid: pid, bundleID: bundleID)
        }
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    /// "com.google.Chrome.helper" → "com.google.Chrome", so detection sees the browser itself.
    private static func owningAppBundleID(_ id: String) -> String {
        for suffix in [".helper.renderer", ".helper.plugin", ".helper", ".framework.AlertNotificationService"] where id.hasSuffix(suffix) {
            return String(id.dropLast(suffix.count))
        }
        return id
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
