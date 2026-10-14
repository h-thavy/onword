import AppKit
import CoreGraphics
import os

/// Global hotkey listener built on a listen-only CGEventTap (needs Input Monitoring permission).
/// Listen-only means it never swallows keys.
final class HotkeyMonitor {
    enum Key: String, CaseIterable, Identifiable {
        case fn, rightOption, rightCommand
        var id: String { rawValue }

        var title: String {
            switch self {
            case .fn: "Fn / 🌐"
            case .rightOption: "Right ⌥ Option"
            case .rightCommand: "Right ⌘ Command"
            }
        }

        /// Virtual key codes from HIToolbox `Events.h`: kVK_Function, kVK_RightOption, kVK_RightCommand.
        var keyCode: Int64 {
            switch self {
            case .fn: 63
            case .rightOption: 61
            case .rightCommand: 54
            }
        }

        /// Fn is the most natural key, but only when macOS isn't also using it.
        static var recommendedDefault: Key { GlobeKey.conflict == nil ? .fn : .rightOption }

        var flag: CGEventFlags {
            switch self {
            case .fn: .maskSecondaryFn
            case .rightOption: .maskAlternate
            case .rightCommand: .maskCommand
            }
        }
    }

    var key: Key = .fn
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onEscape: (() -> Void)?
    /// Called when the shortcut key was pressed in one of Onword's windows but the tap never saw it:
    /// the tap exists but macOS isn't delivering keys to it (Input Monitoring granted too recently).
    var onDeaf: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false
    private var localMonitor: Any?
    /// When the tap last received a modifier change.
    private var lastTapEventAt = Date.distantPast
    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "hotkey")

    var isRunning: Bool { tap != nil }
    /// Whether Input Monitoring was already granted when the tap was created.
    private(set) var createdWithAccess = false

    /// Returns false when the tap can't be created, which almost always means Input Monitoring is not granted.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("CGEvent.tapCreate failed (Input Monitoring not granted?)")
            return false
        }
        self.tap = tap
        createdWithAccess = CGPreflightListenEventAccess()
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        // Keys pressed in Onword's own windows always arrive here, so they show whether the tap hears them too.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, Int64(event.keyCode) == self.key.keyCode, self.tap != nil else { return event }
            let pressedAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard self.tap != nil, self.lastTapEventAt < pressedAt.addingTimeInterval(-0.5) else { return }
                self.log.error("Shortcut pressed in Onword but the event tap received nothing")
                self.onDeaf?()
            }
            return event
        }
        log.notice("Event tap started")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        tap = nil
        runLoopSource = nil
        isDown = false
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables slow taps; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log.warning("Event tap was disabled by the system; re-enabled")
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { // kVK_Escape
                DispatchQueue.main.async { self.onEscape?() }
            }
        case .flagsChanged:
            lastTapEventAt = Date()
            guard event.getIntegerValueField(.keyboardEventKeycode) == key.keyCode else { return }
            let down = event.flags.contains(key.flag)
            guard down != isDown else { return }
            isDown = down
            DispatchQueue.main.async { down ? self.onPress?() : self.onRelease?() }
        default:
            break
        }
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}

/// macOS's own action for the 🌐/Fn key: System Settings → Keyboard → "Press 🌐 key to".
/// Anything other than "Do Nothing" fires alongside dictation when Fn is the hotkey.
enum GlobeKey {
    /// `AppleFnUsageType`: 0 Do Nothing, 1 Change Input Source, 2 Show Emoji & Symbols, 3 Start Dictation.
    static var usage: Int? {
        UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
    }

    /// What the 🌐 key does instead of nothing, or nil when it's safe to use as the hotkey.
    static var conflict: String? {
        switch usage {
        case 0?: nil
        case 1?: "changes the input source"
        case 3?: "starts macOS Dictation"
        default: "opens Emoji & Symbols"   // 2, or unset (macOS default)
        }
    }

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
