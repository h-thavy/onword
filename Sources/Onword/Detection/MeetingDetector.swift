import AppKit
import ApplicationServices
import OnwordCore
import os

/// A call that's happening right now, on a known meeting platform (used to read speaker names).
struct DetectedMeeting: Equatable {
    let platform: MeetingPlatform
    let pid: pid_t
    let bundleID: String
    let windowTitle: String?
}

/// An app on the microphone that may be a call (any app in Wispr Flow's table: meeting apps, browsers, chat).
struct CallHolder: Equatable {
    let app: CallApp
    let pid: pid_t
    let bundleID: String
    /// Browsers: the address of the page in front, and the window title.
    var pageURL: String?
    var windowTitle: String?

    /// The meeting platform: the app's own, or the page's (Google Meet in a browser), or from the window title.
    var platform: MeetingPlatform? {
        app.platform ?? pageURL.flatMap(MeetingRules.platform(forURL:))
            ?? windowTitle.flatMap { MeetingRules.platform(forWindowTitle: $0, isSlack: app.name == "Slack") }
    }

    /// The meeting's code (Google Meet "abc-defg-hij", Zoom number) from the page address or window title.
    var meetingCode: String? {
        if let url = pageURL, let code = MeetingRules.meetingCode(inURL: url) { return code }
        guard let title = windowTitle?.lowercased(),
              let range = title.range(of: #"[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .regularExpression) else { return nil }
        return String(title[range])
    }
}

/// Watches for calls starting and ending, and asks to record (or records) them, as Wispr Flow does: any call
/// app (meeting apps, every browser, Slack, Discord, WhatsApp…) taking the microphone shows "Meeting detected"
/// at once. Only real meetings (a meeting app, a browser on a Meet/Teams/Zoom page, a Slack huddle) may start
/// the Notetaker by themselves.
@MainActor
final class MeetingDetector: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case ask, auto, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: "Notify me"
            case .auto: "Start automatically"
            case .off: "Do nothing"
            }
        }
    }

    static let shared = MeetingDetector()

    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "meetingDetection") }
    }
    @Published private(set) var current: CallHolder?

    /// The recording was started because of a detected call, so it also stops when the call ends.
    private(set) var recordingFollowsCall = false
    private var lastSeen = Date.distantPast
    private var timer: Timer?
    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "detection")

    /// How long the call app must be off the mic before the call counts as over: 1.5 s, plus 5 s of grace
    /// while a recording follows the call (a brief mic drop shouldn't stop it).
    private var endGrace: TimeInterval { recordingFollowsCall ? 6.5 : 1.5 }

    private init() {
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: "meetingDetection") ?? "") ?? .ask
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// The call on a known meeting platform, also when detection is off or the recording was started by hand
    /// (used to know which app to read speaker names from).
    func findMeeting() -> DetectedMeeting? {
        if let holder = current ?? scan(), let platform = holder.platform {
            return DetectedMeeting(platform: platform, pid: holder.pid, bundleID: holder.bundleID, windowTitle: holder.windowTitle)
        }
        return nil
    }

    // MARK: - Polling

    private func poll() {
        let found = scan(readPage: false)
        if let found {
            lastSeen = Date()
            // A new call: nothing was on the mic, or a different app took it. The same app staying on the mic
            // never asks again.
            if current?.app.name != found.app.name {
                var holder = found
                fillPage(&holder)
                current = holder
                log.notice("Call detected: \(holder.app.name, privacy: .public) (\(holder.bundleID, privacy: .public))\(holder.platform.map { ", " + $0.title } ?? "", privacy: .public)")
                callStarted(holder)
            }
        } else if let ended = current, Date().timeIntervalSince(lastSeen) > endGrace {
            current = nil
            FlowBarIsland.shared.dismissReminder("detected")
            log.notice("Call ended: \(ended.app.name, privacy: .public)")
            // "Notetaker stopping" counts down, then stops (Keep going cancels it).
            if MeetingRecorder.shared.isRecording && recordingFollowsCall {
                recordingFollowsCall = false
                NotetakerFlow.shared.callEnded()
            }
        }
    }

    private func callStarted(_ holder: CallHolder) {
        guard !MeetingRecorder.shared.isRecording, mode != .off, Onboarding.isComplete else { return }
        Task { @MainActor in
            // A browser's page can still be loading: look for the calendar event a few times (Wispr: 3 × 400 ms).
            var holder = holder
            var event = calendarEvent(for: holder)
            if event == nil, holder.app.kind == .browser {
                for _ in 0..<3 {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard current?.app.name == holder.app.name, !MeetingRecorder.shared.isRecording else { return }
                    fillPage(&holder)
                    event = calendarEvent(for: holder)
                    if event != nil { break }
                }
                if current?.app.name == holder.app.name { current = holder }
            }
            let autoStart = mode == .auto
                && MeetingRules.mayAutoStart(holder.app, pagePlatform: holder.platform, calendarMatched: event != nil)
            // "Meeting detected" (or the event's title) for 20 s; with "Start Notetaker automatically" it counts
            // down 10 s and starts.
            let name = holder.platform.map { holder.app.kind == .browser ? "\($0.title) in \(holder.app.name)" : $0.title } ?? holder.app.name
            log.notice("Meeting detected card: \(event?.title ?? "-", privacy: .public) / \(event != nil ? "Meeting detected" : name, privacy: .public), auto-start \(autoStart)")
            FlowBarIsland.shared.showReminder(.init(
                id: "detected", title: event?.title ?? "", subtitle: event != nil ? "Meeting detected" : name,
                start: Date(), surface: .detected, platform: holder.platform, meeting: event,
                autoStartSeconds: autoStart ? 10 : nil, dismissAt: Date().addingTimeInterval(autoStart ? 30 : 20)))
        }
    }

    /// The calendar event this call belongs to: one whose link has the call's meeting code; for meeting apps
    /// without a code, the event happening now.
    private func calendarEvent(for holder: CallHolder) -> UpcomingMeeting? {
        let upcoming = CalendarService.shared.upcoming
        if let code = holder.meetingCode {
            let matches = upcoming.filter { $0.joinURL?.absoluteString.lowercased().contains(code) == true }
            return matches.first { $0.start <= Date() && $0.end > Date() }
                ?? matches.min { abs($0.start.timeIntervalSinceNow) < abs($1.start.timeIntervalSinceNow) }
        }
        guard holder.app.kind == .meetingApp else { return nil }
        return CalendarService.shared.currentMeeting()
    }

    /// Records the detected call (from the card); it also stops when the call ends.
    func recordDetected() {
        guard let holder = current ?? scan() else {
            NotetakerFlow.shared.newNote(source: "auto_detect_prompt")
            return
        }
        recordingFollowsCall = true
        NotetakerFlow.shared.beginRecording(event: calendarEvent(for: holder))
        if let id = MeetingRecorder.shared.currentID {
            MeetingStore.shared.update(id) {
                if $0.title.isEmpty { $0.title = "\(holder.platform?.title ?? holder.app.name) call" }
                if let platform = holder.platform { $0.platform = platform.rawValue }
            }
        }
    }

    // MARK: - Ignored and closed cards

    private var closedStreak: Int {
        get { UserDefaults.standard.integer(forKey: "detectCardClosedStreak") }
        set { UserDefaults.standard.set(newValue, forKey: "detectCardClosedStreak") }
    }
    private var ignoredStreak: Int {
        get { UserDefaults.standard.integer(forKey: "detectCardIgnoredStreak") }
        set { UserDefaults.standard.set(newValue, forKey: "detectCardIgnoredStreak") }
    }

    /// The "Meeting detected" card was closed. Three in a row: offer to turn the notifications off (once).
    func cardClosed() {
        closedStreak += 1
        ignoredStreak = 0
        if closedStreak >= 3 { offerToTurnOff(key: "detectOptOutOffered", body: "You've closed the last few Notetaker meeting notifications.") }
    }

    /// The card timed out. Five in a row: offer to turn the notifications off (once).
    func cardIgnored() {
        ignoredStreak += 1
        if ignoredStreak >= 5 { offerToTurnOff(key: "detectIgnoredOptOutOffered", body: "You've ignored the past few Notetaker notifications.") }
    }

    /// A meeting was started from a card.
    func cardUsed() {
        closedStreak = 0
        ignoredStreak = 0
    }

    private func offerToTurnOff(key: String, body: String) {
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        FlowBarIsland.shared.show(.init(
            title: "Turn off meeting notifications?", kind: .standard(status: .info, body: body),
            actions: [.init(title: "Keep as is", style: .light) {},
                      .init(title: "Manage notifications", style: .lumen) {
                          WindowManager.shared.show()
                          HubRouter.shared.settingsTab = .notetaker
                      }],
            timeout: 10))
    }

    // MARK: - Finding the call app

    /// The first call app on the microphone. `readPage` also reads a browser's page and window title.
    private func scan(readPage: Bool = true) -> CallHolder? {
        for holder in MicHolders.current() {
            guard let app = MeetingRules.callApp(bundleID: holder.bundleID) else { continue }
            var call = CallHolder(app: app, pid: holder.pid, bundleID: holder.bundleID)
            if readPage { fillPage(&call) }
            return call
        }
        return nil
    }

    /// Browsers and chat apps: the page in front and the window titles, to tell which meeting it is.
    private func fillPage(_ holder: inout CallHolder) {
        guard holder.app.kind != .meetingApp else { return }
        let titles = windowTitles(pid: holder.pid)
        holder.windowTitle = titles.first { MeetingRules.platform(forWindowTitle: $0, isSlack: holder.app.name == "Slack") != nil }
            ?? titles.first
        if holder.app.kind == .browser { holder.pageURL = pageURL(pid: holder.pid) }
    }

    private func windowTitles(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return [] }
        return list.compactMap { AX.string($0, kAXTitleAttribute) }
    }

    /// The address of the page in the browser's front window: its web area's AXURL (searched for at most
    /// 0.75 s, as Wispr does). Chrome-based browsers expose their pages to accessibility only when asked.
    private func pageURL(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused: CFTypeRef?
        let root: AXUIElement
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success, let window = focused {
            root = window as! AXUIElement
        } else {
            root = app
        }
        let deadline = Date().addingTimeInterval(0.75)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, Date() < deadline, visited < 4000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if AX.string(element, kAXRoleAttribute) == "AXWebArea" {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
                   let url = value as? URL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    return url.absoluteString
                }
                continue   // the page's contents don't hold another page address
            }
            guard depth < 40 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list.map { ($0, depth + 1) })
            }
        }
        return nil
    }
}
