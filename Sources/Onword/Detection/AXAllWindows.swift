import ApplicationServices
import CoreGraphics
import Foundation

/// An app's windows on every Space. The accessibility API lists only the current Space's windows, so a call
/// in a full-screen window (or on another desktop) would be invisible: no title, no mute button. Each window's
/// accessibility element is asked for directly by its token instead (as window switchers like AltTab do).
enum AXAllWindows {
    private typealias CreateWithToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private static let createWithToken: CreateWithToken? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken") else { return nil }
        return unsafeBitCast(symbol, to: CreateWithToken.self)
    }()

    static func windows(pid: pid_t, timeout: Float = 0.25) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        var found = (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success
            ? value as? [AXUIElement] : nil) ?? []
        let expected = windowCount(pid: pid)
        guard found.count < expected, let createWithToken else { return found }
        // Window element IDs are small numbers; stop once every window is found.
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(0x636f_636f)) { Data($0) })
        let deadline = Date().addingTimeInterval(0.4)
        for id in UInt64(0)..<2000 where found.count < expected && Date() < deadline {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
            guard let element = createWithToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, timeout)
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                  role as? String == kAXWindowRole as String, !found.contains(where: { CFEqual($0, element) }) else { continue }
            found.append(element)
        }
        return found
    }

    /// Normal windows the app has on any Space (from the window server; no titles needed).
    private static func windowCount(pid: pid_t) -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return 0 }
        return list.filter {
            ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
                && (($0[kCGWindowBounds as String] as? [String: Double])?["Height"] ?? 0) > 150
        }.count
    }
}

extension AXAllWindows {
    /// The web page in a browser window (its AXWebArea), found without wading through the tab strip and
    /// toolbars (a browser with many tabs would use up the time on tab titles).
    static func webArea(in window: AXUIElement, budget: TimeInterval = 0.75) -> AXUIElement? {
        let skipRoles: Set<String> = ["AXTabGroup", "AXToolbar", "AXMenuBar", "AXMenu", "AXList", "AXOutline", "AXTextField"]
        let deadline = Date().addingTimeInterval(budget)
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        while let (element, depth) = stack.popLast(), Date() < deadline {
            let role = attribute(element, kAXRoleAttribute)
            if role == "AXWebArea" { return element }
            guard depth < 30, !skipRoles.contains(role ?? "") else { continue }
            let label = (attribute(element, kAXDescriptionAttribute) ?? "").lowercased()
            if label.contains("tab bar") || label.contains("tab strip") || label.contains("bookmarks") || label.contains("sidebar") { continue }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                  let kids = children as? [AXUIElement] else { continue }
            // Depth-first, page containers first.
            let ordered = kids.sorted { a, b in
                let la = (attribute(a, kAXDescriptionAttribute) ?? "").lowercased(), lb = (attribute(b, kAXDescriptionAttribute) ?? "").lowercased()
                let pa = la.contains("content") || la.contains("page"), pb = lb.contains("content") || lb.contains("page")
                return !pa && pb
            }
            stack.append(contentsOf: ordered.map { ($0, depth + 1) })
        }
        return nil
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
