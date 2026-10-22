import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// Puts text into whatever app has focus.
///
/// 1. Accessibility: replace the selection directly (no clipboard involved). Verified by re-reading the field,
///    because Chromium/Electron fields often report success and ignore the write.
/// 2. Fallback (what most dictation apps do): save the clipboard, write our text, post ⌘V, restore the clipboard.
/// 3. If the user switched to another app meanwhile, nothing is typed anywhere: the text is left on the clipboard.
enum TextInserter {
    enum Method: String, Codable {
        case accessibility, clipboard
        /// Focus moved to a different app before the text was ready; text was copied, not inserted.
        case copiedOnly
        /// Inserted straight into a Onword window (Scratchpad).
        case ownWindow
    }

    static func copyOnly(_ text: String) -> Method {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return .copiedOnly
    }

    private static let log = Logger(subsystem: "io.github.h-thavy.onword", category: "insert")

    /// Apps where the AX write is known to be unreliable or meaningless; always paste. Terminals especially:
    /// cmux applies the write a moment later, so it looked like it failed and the paste typed it a second time.
    private static let pasteOnlyBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "com.cmuxterm.app", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
        "org.tabby", "dev.zed.Zed", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.tinyspeck.slackmacgap",
    ]

    @discardableResult
    static func insert(_ text: String, into context: TextContext) -> Method {
        if let element = context.element, !pasteOnlyBundleIDs.contains(context.bundleID ?? ""),
           insertViaAccessibility(text, into: element) {
            log.notice("Inserted \(text.count) chars via Accessibility")
            return .accessibility
        }
        // ⌘V goes to whatever is frontmost now, so only paste if that's still the app we started in.
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let pid = context.pid, frontmost != pid {
            log.notice("Focus moved to another app; copied \(text.count) chars instead of pasting")
            return copyOnly(text)
        }
        pasteViaClipboard(text)
        log.notice("Inserted \(text.count) chars via clipboard")
        return .clipboard
    }

    // MARK: - Accessibility

    private static func insertViaAccessibility(_ text: String, into element: AXUIElement) -> Bool {
        guard AX.isSettable(element, kAXSelectedTextAttribute),
              let before = AX.string(element, kAXValueAttribute) else { return false }

        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        guard result == .success, var after = AX.string(element, kAXValueAttribute) else { return false }
        // Only trust it if the field visibly changed and now contains our text. Some apps apply the write a
        // moment later: look again before falling back to pasting, or the text would land twice.
        if after == before {
            Thread.sleep(forTimeInterval: 0.25)
            after = AX.string(element, kAXValueAttribute) ?? after
        }
        let landed = after != before && after.contains(text)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let target = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
        log.notice("AX insert into \(target, privacy: .public): length \(before.count) → \(after.count), landed=\(landed)")
        return landed
    }

    // MARK: - Clipboard + ⌘V

    private static func pasteViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Convention honoured by clipboard managers (Maccy, Raycast, Paste…): don't record this entry.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChange = pasteboard.changeCount

        postCommandV()

        // Give the target app time to read the pasteboard, then put the user's clipboard back —
        // unless something else has written to it in the meantime.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Finds which physical key types `character` on the current layout (so ⌘V works on Dvorak, AZERTY, …).
    private static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                    OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
                if status == noErr, length == 1, let scalar = UnicodeScalar(chars[0]), Character(scalar) == character {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
