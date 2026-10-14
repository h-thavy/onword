import AppKit
import ApplicationServices
import OnwordCore
import os

/// A call that's happening right now.
struct DetectedMeeting: Equatable {
    let platform: MeetingPlatform
    let pid: pid_t
    let bundleID: String
    let windowTitle: String?
}

/// Watches for calls starting and ending, and asks to record (or records) them.
@MainActor
final class MeetingDetector: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case ask, auto, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: "Ask me"
            case .auto: "Record automatically"
            case .off: "Do nothing"
            }
        }
    }

    static let shared = MeetingDetector()

    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "meetingDetection") }
    }
    @Published private(set) var current: DetectedMeeting?

    /// The recording was started because of a detected call, so it also stops when the call ends.
    private(set) var recordingFollowsCall = false
    private var dismissedPID: pid_t?
    private var lastSeen = Date.distantPast
    private var timer: Timer?
    private lazy var prompt = MeetingPromptPanel()
    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "detection")

    /// How long the call app must be off the mic before the call counts as over.
    private let endGrace: TimeInterval = 12

    private init() {
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: "meetingDetection") ?? "") ?? .ask
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Finds a call even when detection is off or the recording was started by hand
    /// (used to know which app to read speaker names from).
    func findMeeting() -> DetectedMeeting? {
        current ?? scan()
    }

    // MARK: - Polling

    private func poll() {
        let found = scan()
        let recorder = MeetingRecorder.shared

        if let found {
            lastSeen = Date()
            if current == nil || current?.pid != found.pid {
                current = found
                log.notice("Call detected: \(found.platform.title, privacy: .public) (\(found.bundleID, privacy: .public))")
                callStarted(found)
            }
        } else if let ended = current, Date().timeIntervalSince(lastSeen) > endGrace {
            current = nil
            dismissedPID = nil
            prompt.hide()
            log.notice("Call ended: \(ended.platform.title, privacy: .public)")
            if recorder.isRecording && recordingFollowsCall {
                recordingFollowsCall = false
                recorder.stop()
            }
        }
    }

    private func callStarted(_ meeting: DetectedMeeting) {
        let recorder = MeetingRecorder.shared
        guard !recorder.isRecording, dismissedPID != meeting.pid else { return }
        switch mode {
        case .off:
            break
        case .auto:
            record(meeting)
        case .ask:
            prompt.show(title: "\(meeting.platform.title) call detected", message: "Record and transcribe it on this Mac?") { [weak self] accepted in
                guard let self else { return }
                if accepted { self.record(meeting) } else { self.dismissedPID = meeting.pid }
            }
        }
    }

    private func record(_ meeting: DetectedMeeting) {
        recordingFollowsCall = true
        // Prefer the calendar event's title; fall back to "Zoom – Tue 13 Oct, 15:49".
        let fallback = "\(meeting.platform.title) – \(Meeting.defaultTitle(for: Date()).replacingOccurrences(of: "Meeting – ", with: ""))"
        MeetingRecorder.shared.start(title: CalendarService.shared.currentMeeting()?.title ?? fallback)
    }

    /// Call apps currently on the microphone.
    private func scan() -> DetectedMeeting? {
        for holder in MicHolders.current() {
            let needsTitles = MeetingRules.browsersAndChat.contains(holder.bundleID)
            let titles = needsTitles ? windowTitles(pid: holder.pid) : []
            if let platform = MeetingRules.platform(bundleID: holder.bundleID, windowTitles: titles) {
                let title = titles.first { MeetingRules.platform(forWindowTitle: $0, isSlack: platform == .slack) != nil }
                return DetectedMeeting(platform: platform, pid: holder.pid, bundleID: holder.bundleID, windowTitle: title)
            }
        }
        return nil
    }

    private func windowTitles(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return [] }
        return list.compactMap { AX.string($0, kAXTitleAttribute) }
    }
}
