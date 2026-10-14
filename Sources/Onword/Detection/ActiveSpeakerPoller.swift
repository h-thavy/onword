import AppKit
import ApplicationServices
import OnwordCore
import os

/// While a call is recorded, reads the call app's window through Accessibility a few times a second and
/// notes whose tile is marked as speaking.
///
/// Web apps (Meet, Teams, Slack huddles) expose their HTML classes as `AXDOMClassList`; the active
/// speaker's tile carries a marker class. Zoom labels the tile "…, active speaker". The class names are
/// obfuscated and change from time to time, so they can be overridden in
/// ~/Library/Application Support/Onword/speaker-markers.json.
final class ActiveSpeakerPoller {
    struct Markers: Codable {
        /// Class on (or inside) the tile of whoever is speaking.
        var marker: [String]
        /// Class of the participant tile that holds the name. Empty = walk up until a name is found.
        var tile: [String]
    }

    /// Defaults; override them in the JSON file when the call apps change their markup.
    static let defaultMarkers: [String: Markers] = [
        MeetingPlatform.googleMeet.rawValue: Markers(marker: ["kssMZb"], tile: ["oZRSLe"]),
        MeetingPlatform.teams.rawValue: Markers(marker: ["vdi-frame-occlusion"], tile: []),
        MeetingPlatform.slack.rawValue: Markers(marker: ["p-huddle_peer_tile__overlay--active_speaker"], tile: ["p-huddle_peer_tile"]),
    ]

    private let meeting: DetectedMeeting
    private let startedAt: Date
    private let output: URL
    private let markers: Markers?
    private let queue = DispatchQueue(label: "com.onword.speaker-poller", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var handle: FileHandle?
    private var lastSpeaking: [String] = []
    private var observations: [SpeakerObservation] = []
    private(set) var namesSeen = Set<String>()
    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "speakers")

    init(meeting: DetectedMeeting, startedAt: Date, output: URL) {
        self.meeting = meeting
        self.startedAt = startedAt
        self.output = output
        markers = Self.loadMarkers()[meeting.platform.rawValue]
    }

    static func loadMarkers() -> [String: Markers] {
        let url = AppPaths.root.appendingPathComponent("speaker-markers.json")
        if let data = try? Data(contentsOf: url), let custom = try? JSONDecoder().decode([String: Markers].self, from: data) {
            return defaultMarkers.merging(custom) { _, new in new }
        }
        return defaultMarkers
    }

    func start() {
        guard markers != nil || meeting.platform == .zoom else {
            log.notice("No speaker markers for \(self.meeting.platform.title, privacy: .public); names will come from renaming")
            return
        }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        handle = try? FileHandle(forWritingTo: output)
        enableWebAccessibility()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.4)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
        log.notice("Reading active speakers from \(self.meeting.platform.title, privacy: .public)")
    }

    /// The one person shown speaking around `t` seconds into the recording (for the live transcript).
    func speaker(at t: Double) -> String? {
        queue.sync {
            let nearby = observations.reversed().first { abs($0.t - t) <= 1.0 }
            let people = (nearby?.speaking ?? []).filter { !SpeakerNames.isSelf($0) }
            return people.count == 1 ? people[0] : nil
        }
    }

    /// Stops polling and returns every name seen.
    @discardableResult
    func stop() -> [String] {
        timer?.cancel()
        timer = nil
        let names = queue.sync { () -> [String] in
            try? handle?.close()
            handle = nil
            return namesSeen.sorted()
        }
        // Leave the browser as we found it (enhanced UI can slow window animations).
        if meeting.platform != .zoom, meeting.platform != .facetime {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(meeting.pid), "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        log.notice("Speaker reading stopped; \(names.count) name(s) seen")
        return names
    }

    // MARK: - Polling (background queue)

    private func poll() {
        let speaking = currentSpeakers()
        // Only write when it changes, plus a heartbeat every poll while someone is speaking,
        // so each spoken stretch collects several votes.
        guard !speaking.isEmpty || !lastSpeaking.isEmpty else { return }
        lastSpeaking = speaking
        namesSeen.formUnion(speaking)
        let observation = SpeakerObservation(t: Date().timeIntervalSince(startedAt), speaking: speaking)
        observations.append(observation)
        if var line = try? JSONEncoder().encode(observation) {
            line.append(0x0A)
            try? handle?.write(contentsOf: line)
        }
    }

    private func currentSpeakers() -> [String] {
        let app = AXUIElementCreateApplication(meeting.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var budget = 6000
        var names: [String] = []
        for window in callWindows(app) {
            if let markers {
                findMarked(window, markers: markers, budget: &budget, names: &names)
            } else {
                findZoomActiveSpeaker(window, budget: &budget, names: &names)
            }
        }
        return Array(Set(names.map(SpeakerNames.clean).filter(SpeakerNames.isPlausible))).sorted()
    }

    /// For browsers, only the window with the call; for native apps, all windows.
    private func callWindows(_ app: AXUIElement) -> [AXUIElement] {
        let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard let title = meeting.windowTitle else { return windows }
        let matching = windows.filter { AX.string($0, kAXTitleAttribute) == title }
        return matching.isEmpty ? windows : matching
    }

    private func findMarked(_ element: AXUIElement, markers: Markers, budget: inout Int, names: inout [String], depth: Int = 0) {
        guard budget > 0, depth < 60 else { return }
        budget -= 1
        if let classes = attr(element, "AXDOMClassList") as? [String], classes.contains(where: markers.marker.contains) {
            if let name = nameForTile(containing: element, tileClasses: markers.tile) { names.append(name) }
            return
        }
        for child in children(element) {
            findMarked(child, markers: markers, budget: &budget, names: &names, depth: depth + 1)
        }
    }

    /// Walks up from the marker to the participant tile, then reads the first name-like text inside it.
    private func nameForTile(containing marker: AXUIElement, tileClasses: [String]) -> String? {
        var node: AXUIElement? = marker
        for _ in 0..<10 {
            guard let current = node else { return nil }
            let classes = (attr(current, "AXDOMClassList") as? [String]) ?? []
            let isTile = tileClasses.isEmpty || classes.contains(where: tileClasses.contains)
            if isTile, let name = firstText(in: current) { return name }
            node = attr(current, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        return nil
    }

    private func firstText(in element: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 12 else { return nil }
        if attr(element, kAXRoleAttribute) as? String == kAXStaticTextRole as String,
           let value = AX.string(element, kAXValueAttribute), SpeakerNames.isPlausible(SpeakerNames.clean(value)) {
            return value
        }
        for child in children(element) {
            if let text = firstText(in: child, depth: depth + 1) { return text }
        }
        return nil
    }

    private func findZoomActiveSpeaker(_ element: AXUIElement, budget: inout Int, names: inout [String], depth: Int = 0) {
        guard budget > 0, depth < 40 else { return }
        budget -= 1
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
            if let text = AX.string(element, attribute), text.range(of: "active speaker", options: .caseInsensitive) != nil {
                names.append(text)
                return
            }
        }
        for child in children(element) {
            findZoomActiveSpeaker(child, budget: &budget, names: &names, depth: depth + 1)
        }
    }

    /// Chromium and Electron only build their web accessibility tree when an assistive app asks for it.
    private func enableWebAccessibility() {
        guard meeting.platform != .zoom, meeting.platform != .facetime else { return }
        let app = AXUIElementCreateApplication(meeting.pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
