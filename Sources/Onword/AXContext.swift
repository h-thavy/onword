import AppKit
import ApplicationServices

/// What the user is typing into, read through the Accessibility API at the moment dictation starts.
/// Used only on this Mac (casing/spacing), never sent anywhere.
struct TextContext {
    var bundleID: String?
    var appName: String?
    var pid: pid_t?
    /// The exact field that had focus when dictation started; text is inserted here, not wherever focus is later.
    var element: AXUIElement?
    var before = ""
    var after = ""
    var isSecureField = false
    /// Dictating into one of Onword's own windows (Scratchpad, meeting notes).
    var isOwnApp = false

    static let maxContext = 500
}

enum AX {
    /// The focused field of the frontmost app. Asking the frontmost app (rather than the system-wide element)
    /// matters: the system-wide answer can point into a different app, e.g. an Electron window in the background.
    static func focusedElement(in pid: pid_t) -> AXUIElement? {
        element(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    static func readContext() -> TextContext {
        let app = NSWorkspace.shared.frontmostApplication
        var context = TextContext(bundleID: app?.bundleIdentifier, appName: app?.localizedName, pid: app?.processIdentifier)
        // Never query our own Accessibility tree from the main thread: it would wait on itself.
        if app?.processIdentifier == getpid() {
            context.isOwnApp = true
            (context.before, context.after) = OwnWindowInserter.context()
            return context
        }
        guard let pid = app?.processIdentifier, let element = focusedElement(in: pid) else { return context }
        context.element = element

        context.isSecureField = string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
        guard !context.isSecureField,
              let value = string(element, kAXValueAttribute),
              let range = selectedRange(element) else { return context }

        let text = value as NSString
        let start = max(0, min(range.location, text.length))
        let end = max(start, min(range.location + range.length, text.length))
        context.before = String(text.substring(to: start).suffix(TextContext.maxContext))
        context.after = String(text.substring(from: end).prefix(TextContext.maxContext))
        return context
    }
}
