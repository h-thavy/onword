import ApplicationServices
import OnwordCore
import os

/// Reads whether you're muted in a call app, from its controls' accessibility labels (Zoom's audio button,
/// Google Meet's "Your microphone is off.", Teams' Mute/Unmute button). Called off the main thread.
enum CallMute {
    static func state(pid: pid_t) -> CallMuteState {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Chrome-based browsers expose their pages to accessibility only when asked.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return .unknown }
        var labels: [String] = []
        var queue = list.map { ($0, 0) }
        let deadline = Date().addingTimeInterval(0.5)
        var visited = 0
        while !queue.isEmpty, Date() < deadline, visited < 8000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
                if let text = string(element, attribute), !text.isEmpty, text.count < 120 { labels.append(text) }
            }
            // Stop as soon as the call's own wording is found.
            if let last = labels.last, MeetingRules.muteState(labels: [last]) != .unknown, !last.lowercased().hasPrefix("mute") {
                debugLog(visited, labels.count, MeetingRules.muteState(labels: [last]), [last])
                return MeetingRules.muteState(labels: [last])
            }
            guard depth < 45 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let kids = children as? [AXUIElement] {
                queue.append(contentsOf: kids.map { ($0, depth + 1) })
            }
        }
        let state = MeetingRules.muteState(labels: labels)
        debugLog(visited, labels.count, state, labels.filter { $0.lowercased().contains("micro") || $0.lowercased().contains("mute") })
        return state
    }

    /// ONWORD_DEBUG_MUTE=1 logs each reading and the labels it was based on.
    private static func debugLog(_ visited: Int, _ count: Int, _ state: CallMuteState, _ labels: [String]) {
        guard ProcessInfo.processInfo.environment["ONWORD_DEBUG_MUTE"] != nil else { return }
        Logger(subsystem: "io.github.h-thavy.onword", category: "meetings")
            .notice("Mute check: \(visited) elements, \(count) labels, \(String(describing: state), privacy: .public); \(labels.prefix(3).joined(separator: " | "), privacy: .public)")
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
