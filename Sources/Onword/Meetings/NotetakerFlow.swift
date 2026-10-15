import AppKit
import Combine
import OnwordCore
import os

/// Notetaker settings (Settings → Notetaker), with Wispr Flow's defaults.
enum NotetakerSettings {
    /// "Open Notepad when starting Notetaker" (on).
    static var openNotepad: Bool {
        get { UserDefaults.standard.object(forKey: "notetakerOpenNotepad") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notetakerOpenNotepad") }
    }
    /// "Stop Notetaker when a call ends" (on).
    static var stopWhenCallEnds: Bool {
        get { UserDefaults.standard.object(forKey: "notetakerStopWhenCallEnds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notetakerStopWhenCallEnds") }
    }
    /// Maximum meeting length in minutes: 30, 60, 120 (default) or 180.
    static let maxLengthOptions = [30, 60, 120, 180]
    static var maxLengthMinutes: Int {
        get { UserDefaults.standard.object(forKey: "notetakerMaxLength") as? Int ?? 120 }
        set { UserDefaults.standard.set(newValue, forKey: "notetakerMaxLength") }
    }
    /// "Notify before scheduled meetings start": seconds before the start (15 = "Right before"), or -1 = never.
    static let reminderLeadOptions: [(title: String, seconds: Int)] = [("Right before", 15), ("1 min before", 60),
                                                                      ("2 min before", 120), ("Never", -1)]
    static var reminderLeadSeconds: Int {
        get { UserDefaults.standard.object(forKey: "notetakerReminderLead") as? Int ?? 15 }
        set { UserDefaults.standard.set(newValue, forKey: "notetakerReminderLead") }
    }

    static func title(forMinutes minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr"
    }
}

/// Every way a Notetaker recording starts and ends, as in Wispr Flow: the Hub's "Start Notetaker",
/// "Join + Start", the reminder pill, call detection and ⌥M all open the Notepad and record; stopping is
/// followed by the "Started by mistake?" and "Notetaker stopped" banners.
@MainActor
final class NotetakerFlow {
    static let shared = NotetakerFlow()

    private var subscriptions: Set<AnyCancellable> = []
    private var lifecycleTimer: Timer?
    private var checkInShown = false
    private var micWarningShown = false
    private var stoppingCountdown = false
    private var summaryWatch: [UUID: Bool] = [:]
    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "notetaker")

    /// Hosts allowed to open from a calendar invite (https only).
    private static let joinHosts = ["meet.google.com", "zoom.us", "zoomgov.com", "teams.microsoft.com", "teams.live.com",
                                    "webex.com", "gotomeeting.com", "bluejeans.com", "whereby.com", "chime.aws",
                                    "meetings.dialpad.com", "slack.com", "discord.com"]

    private init() {
        let recorder = MeetingRecorder.shared
        recorder.onStopped = { [weak self] id in self?.recordingStopped(id) }
        recorder.$currentID.removeDuplicates().sink { [weak self] id in
            self?.lifecycleTimer?.invalidate()
            guard id != nil else { return }
            self?.checkInShown = false
            self?.micWarningShown = false
            self?.lifecycleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { NotetakerFlow.shared.checkRecording() }
            }
        }
        .store(in: &subscriptions)
        // Sleep ends the recording ("Notetaker stopped when your Mac went to sleep").
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let id = MeetingRecorder.shared.currentID else { return }
                MeetingRecorder.shared.stop()
                NotetakerFlow.shared.stoppedBanner(id, asleep: true)
            }
        }
        // "Your summary is ready!" when a summary lands while the Notepad isn't showing that note.
        MeetingStore.shared.$meetings.sink { [weak self] meetings in
            guard let self else { return }
            for m in meetings where m.summary != nil && self.summaryWatch[m.id] == true {
                self.summaryWatch[m.id] = nil
                if NotepadWindow.shared.showingMeetingID != m.id || !NotepadWindow.shared.isVisible {
                    FlowBarIsland.shared.show(.init(title: "Your summary is ready!", kind: .summaryReady(meetingTitle: m.displayTitle),
                                                    actions: [.init(title: "View summary") { self.openNote(m.id) }],
                                                    timeout: 10))
                }
            }
        }
        .store(in: &subscriptions)
    }

    /// Test hooks for snapshots: ONWORD_TEST_NOTEPAD=<index>[:tab] opens a note in the Notepad;
    /// ONWORD_TEST_ISLAND=reminder|detected|stopping|stopped|mistake|summary|maxlength|mic shows that surface.
    private static var liveTest: LiveTranscriber?

    /// The Google Calendar demo: Settings → Connections → Connect (the consent screen is done in the browser),
    /// then, once connected, the upcoming meetings, a note started from one, and Disconnect.
    private func runGoogleDemo() {
        Task { @MainActor in
            let google = GoogleCalendar.shared
            if google.connectedEmail != nil { google.disconnect() }
            try? await Task.sleep(for: .seconds(3))
            NSApp.activate(ignoringOtherApps: true)
            WindowManager.shared.show()
            HubRouter.shared.settingsTab = .connections
            try? await Task.sleep(for: .seconds(6))
            google.connect()
            while google.connectedEmail == nil { try? await Task.sleep(for: .seconds(1)) }
            log.notice("Demo: connected")
            try? await Task.sleep(for: .seconds(2))
            NSApp.activate(ignoringOtherApps: true)
            WindowManager.shared.show()
            try? await Task.sleep(for: .seconds(5))
            HubRouter.shared.settingsTab = nil
            HubRouter.shared.page = .notetaker
            CalendarService.shared.refresh(force: true)
            try? await Task.sleep(for: .seconds(8))
            if let meeting = CalendarService.shared.upcoming.first(where: { $0.joinURL != nil }) ?? CalendarService.shared.upcoming.first {
                log.notice("Demo: starting notes for an upcoming meeting")
                beginRecording(event: meeting)
                try? await Task.sleep(for: .seconds(10))
                MeetingRecorder.shared.stop()
                try? await Task.sleep(for: .seconds(4))
            }
            NotepadWindow.shared.close()
            NSApp.activate(ignoringOtherApps: true)
            WindowManager.shared.show()
            HubRouter.shared.settingsTab = .connections
            try? await Task.sleep(for: .seconds(4))
            google.disconnect()
            log.notice("Demo: disconnected")
        }
    }

    private func runLiveTest(_ folder: URL) {
        let mic = (try? AudioFileWriter.read(folder.appending(path: "mic.wav"))) ?? []
        let system = (try? AudioFileWriter.read(folder.appending(path: "system.wav"))) ?? []
        let live = LiveTranscriber()
        Self.liveTest = live
        let controller = DictationController.shared
        let languages = ProcessInfo.processInfo.environment["ONWORD_TEST_LANGUAGES"].map { $0.split(separator: ",").map(String.init) }
            ?? controller.selectedLanguages
        live.onUpdate = { segments in
            let text = segments.map { String(format: "%6.1f [%@] %@", $0.start, $0.speaker, $0.text) }.joined(separator: "\n")
            try? text.write(to: folder.appending(path: "live.txt"), atomically: true, encoding: .utf8)
        }
        live.start(model: controller.model, language: controller.language == "auto" ? nil : controller.language, languages: languages)
        let second = 16_000, total = max(mic.count, system.count) + 10 * second
        Task { @MainActor in
            var offset = 0
            while offset < total {
                func piece(_ track: [Float]) -> [Float] {
                    (offset..<offset + second).map { $0 < track.count ? track[$0] : 0 }
                }
                live.mic.append(piece(mic))
                live.system.append(piece(system))
                offset += second
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func runTestHooks() {
        let env = ProcessInfo.processInfo.environment
        if let value = env["ONWORD_TEST_NOTEPAD"] {
            let parts = value.split(separator: ":")
            let index = Int(parts.first ?? "0") ?? 0
            let meetings = MeetingStore.shared.meetings
            if meetings.indices.contains(index) {
                NotepadWindow.shared.show(meetings[index].id, focus: true, tab: parts.count > 1 ? NoteTab(rawValue: String(parts[1])) : nil)
            }
        }
        if let value = env["ONWORD_TEST_HUBNOTE"] {
            let parts = value.split(separator: ":")
            let meetings = MeetingStore.shared.meetings
            if let index = Int(parts.first ?? ""), meetings.indices.contains(index) {
                if parts.count > 1, let tab = NoteTab(rawValue: String(parts[1])) { HubRouter.shared.noteTab = tab }
                HubRouter.shared.selectedMeetingID = meetings[index].id
            }
        }
        // ONWORD_TEST_FOLDERS=grid|detail|editor shows the Folders tab, the first folder, or the Create dialog.
        if let folders = env["ONWORD_TEST_FOLDERS"] {
            HubRouter.shared.notesTab = .folders
            if folders == "detail" { HubRouter.shared.openFolderID = FolderStore.shared.folders.first?.id }
            if folders == "editor" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    FolderEditor.shared.create(prefill: "Design reviews", over: NSApp.windows.first { $0.title == "Onword" })
                }
            }
        }
        // ONWORD_TEST_LIVE=<folder with mic.wav, system.wav> streams them through the live transcript at 4× speed
        // and writes what it shows to <folder>/live.txt.
        if let folder = env["ONWORD_TEST_LIVE"] { runLiveTest(URL(fileURLWithPath: folder)) }
        // ONWORD_DEMO_GOOGLE=1 walks through the Google Calendar flow for the verification video.
        if env["ONWORD_DEMO_GOOGLE"] != nil { runGoogleDemo() }
        // ONWORD_TEST_RECORD=<seconds> records a meeting for that long, starting 3 s after launch.
        if let seconds = env["ONWORD_TEST_RECORD"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                _ = MeetingRecorder.shared.start(title: "Recording test")
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MeetingRecorder.shared.stop() }
            }
        }
        // ONWORD_TEST_REPROCESS=1 transcribes every meeting again (e.g. from recording.m4a).
        if env["ONWORD_TEST_REPROCESS"] != nil {
            for meeting in MeetingStore.shared.meetings where meeting.status == .ready { MeetingRecorder.shared.process(meeting.id) }
        }
        guard let island = env["ONWORD_TEST_ISLAND"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let next = CalendarService.shared.upcoming.first
            switch island {
            case "reminder", "detected":
                FlowBarIsland.shared.showReminder(.init(id: "test", title: next?.title ?? "Design review", start: Date().addingTimeInterval(120),
                                                         surface: island == "detected" ? .detected : .scheduled, platform: .googleMeet,
                                                         meeting: next, autoStartSeconds: env["ONWORD_TEST_AUTOSTART"] != nil ? 10 : nil,
                                                         dismissAt: Date().addingTimeInterval(600)))
                if env["ONWORD_TEST_ISLAND_MINI"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { FlowBarIsland.shared.expandedID = nil }
                }
            case "stopping":
                FlowBarIsland.shared.show(.init(title: "Notetaker stopping", kind: .condensed,
                                                actions: [.init(title: "Keep going") {}, .init(title: "Stop") {}], timeout: 600))
            case "stopped":
                FlowBarIsland.shared.show(.init(title: "Notetaker stopped", kind: .condensed, actions: [.init(title: "Resume") {}], timeout: 600))
            case "mistake":
                FlowBarIsland.shared.show(.init(title: "Started by mistake?",
                                                kind: .standard(status: .alert, body: "Only a few words were captured. Keep this meeting or discard it."),
                                                actions: [.init(title: "Discard", style: .dark) {}, .init(title: "Keep", style: .light) {}], timeout: 600))
            case "mic":
                FlowBarIsland.shared.show(.init(title: "Notetaker isn't hearing audio from your mic",
                                                kind: .standard(status: .error, body: "No sound from MacBook Pro Microphone for the past 3 minutes. Check that it's the right mic and that you're not muted."),
                                                actions: [.init(title: "Ignore", style: .dark) {}, .init(title: "Microphone settings", style: .light) {}], timeout: 600))
            case "summary":
                FlowBarIsland.shared.show(.init(title: "Your summary is ready!", kind: .summaryReady(meetingTitle: "Design review"),
                                                actions: [.init(title: "View summary") {}], timeout: 600))
            case "maxlength":
                FlowBarIsland.shared.show(.init(title: "Approaching time limit",
                                                kind: .maxLength(ends: Date().addingTimeInterval(299), limitTitle: "2 hr", canExtend: true),
                                                timeout: 600, pausesOnHover: false))
            default: break
            }
        }
    }

    // MARK: - Starting

    /// "Start Notetaker" / "New note" / ⌥M with nothing on the calendar: open the Notepad and record.
    func newNote(source: String = "hub") {
        if MeetingRecorder.shared.isRecording {
            confirmSwitch(title: "Start a new meeting note?", confirm: "Start") { self.beginRecording(event: nil) }
            return
        }
        beginRecording(event: nil)
    }

    /// Record a calendar meeting without opening its link.
    func start(meeting: UpcomingMeeting) {
        if MeetingRecorder.shared.isRecording {
            confirmSwitch(title: "Switch to “\(meeting.title)”?", confirm: "Switch") { self.beginRecording(event: meeting) }
            return
        }
        beginRecording(event: meeting)
    }

    /// "Join + Start": open the call link, then record bound to the event.
    func joinAndStart(_ meeting: UpcomingMeeting) {
        CalendarService.shared.join(meeting)
        start(meeting: meeting)
    }

    /// Clicking an upcoming meeting's row: open its note to prepare, recording only if it's happening now.
    func openDraft(for meeting: UpcomingMeeting) {
        if let existing = MeetingStore.shared.meetings.first(where: { $0.calendarEventID == meeting.id }) {
            openNote(existing.id)
            return
        }
        if meeting.isNow && !MeetingRecorder.shared.isRecording {
            beginRecording(event: meeting)
            return
        }
        var draft = Meeting(title: meeting.title, startedAt: meeting.start)
        draft.status = .draft
        draft.calendarEventID = meeting.id
        draft.attendees = meeting.attendees
        draft.platform = meeting.platform?.rawValue
        MeetingStore.shared.save(draft)
        NotepadWindow.shared.show(draft.id, focus: true)
    }

    /// The reminder pill's primary action (or its auto-start countdown).
    func startFromReminder(_ reminder: FlowBarIsland.Reminder) {
        FlowBarIsland.shared.dismissReminder(reminder.id)
        if let meeting = reminder.meeting {
            reminder.surface == .scheduled && meeting.joinURL != nil ? joinAndStart(meeting) : start(meeting: meeting)
        } else {
            MeetingDetector.shared.recordDetected()
        }
    }

    func snooze(_ reminder: FlowBarIsland.Reminder) {
        FlowBarIsland.shared.dismissReminder(reminder.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            var again = reminder
            again.dismissAt = Date().addingTimeInterval(reminder.surface == .detected ? 20 : 300)
            FlowBarIsland.shared.showReminder(again)
        }
    }

    /// ⌥M: record the call that's on; join the one meeting on the calendar now; several → the meetings drawer.
    func shortcut() {
        if MeetingRecorder.shared.isRecording {
            confirmSwitch(title: "Start a new meeting note?", confirm: "Start") { self.beginRecording(event: nil) }
            return
        }
        let now = Date()
        let live = CalendarService.shared.upcoming.filter { $0.start <= now.addingTimeInterval(60) && $0.end > now }
        if live.count > 1 {
            FlowBar.shared.toggleDrawer()
        } else if let meeting = live.first {
            MeetingDetector.shared.current != nil || meeting.joinURL == nil ? start(meeting: meeting) : joinAndStart(meeting)
        } else {
            newNote(source: "hotkey")
        }
    }

    /// Records into a note: a new one, a calendar event's, or (Resume) an existing one.
    func beginRecording(event: UpcomingMeeting?, into existing: UUID? = nil) {
        let recorder = MeetingRecorder.shared
        if recorder.isRecording { recorder.stop() }
        var target = existing
        if target == nil, let event,
           let draft = MeetingStore.shared.meetings.first(where: { $0.calendarEventID == event.id && $0.status == .draft }) {
            target = draft.id
        }
        guard let id = recorder.start(title: event?.title, calendarMeeting: event, into: target) else { return }
        if let platform = event?.platform { MeetingStore.shared.update(id) { $0.platform = $0.platform ?? platform.rawValue } }
        if NotetakerSettings.openNotepad {
            NotepadWindow.shared.show(id, focus: event?.joinURL == nil, tab: .notes)
        }
    }

    func resume(_ id: UUID) {
        beginRecording(event: nil, into: id)
    }

    /// Opens a note in the Notepad window.
    func openNote(_ id: UUID) {
        NotepadWindow.shared.show(id, focus: true)
    }

    private func confirmSwitch(title: String, confirm: String, _ run: @escaping () -> Void) {
        FlowBarIsland.shared.show(.init(title: title, kind: .standard(status: .info, body: "Notetaker is already taking notes."),
                                        actions: [.init(title: "No", style: .light) {}, .init(title: confirm, style: .lumen, run: run)],
                                        timeout: 10))
    }

    // MARK: - While recording

    private func checkRecording() {
        let recorder = MeetingRecorder.shared
        guard recorder.isRecording else { return }
        let cap = TimeInterval(NotetakerSettings.maxLengthMinutes * 60)
        let lead: TimeInterval = NotetakerSettings.maxLengthMinutes == 30 ? 120 : 300
        if recorder.elapsed >= cap, let id = recorder.currentID {
            log.notice("Meeting reached the \(NotetakerSettings.maxLengthMinutes) min limit")
            recorder.stop()
            stoppedBanner(id)
            return
        }
        if !checkInShown, recorder.elapsed >= cap - lead {
            checkInShown = true
            let limit = NotetakerSettings.title(forMinutes: NotetakerSettings.maxLengthMinutes)
            let canExtend = NotetakerSettings.maxLengthOptions.contains { $0 > NotetakerSettings.maxLengthMinutes }
            FlowBarIsland.shared.show(.init(title: "Approaching time limit",
                                            kind: .maxLength(ends: Date().addingTimeInterval(cap - recorder.elapsed),
                                                             limitTitle: limit, canExtend: canExtend),
                                            timeout: 60, pausesOnHover: false))
        }
        // Allow a longer limit chosen from the check-in to take effect.
        if checkInShown, recorder.elapsed < TimeInterval(NotetakerSettings.maxLengthMinutes * 60) - lead - 1 { checkInShown = false }
        if !micWarningShown, Date().timeIntervalSince(recorder.lastMicSound) > 180 {
            micWarningShown = true
            let mic = AudioDevices.resolve(preference: UserDefaults.standard.string(forKey: AudioRecorder.microphoneKey))?.name
                ?? "your microphone"
            FlowBarIsland.shared.show(.init(
                title: "Notetaker isn't hearing audio from your mic",
                kind: .standard(status: .error, body: "No sound from \(mic) for the past 3 minutes. Check that it's the right mic and that you're not muted."),
                actions: [.init(title: "Ignore", style: .dark) {},
                          .init(title: "Microphone settings", style: .light) {
                              NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!)
                          }],
                timeout: 60))
        }
    }

    /// The call ended: "Notetaker stopping" counts down 10 s (paused while hovered), then stops.
    func callEnded() {
        guard MeetingRecorder.shared.isRecording, NotetakerSettings.stopWhenCallEnds, !stoppingCountdown,
              ProcessInfo.processInfo.environment["ONWORD_TEST_RECORD"] == nil else { return }
        stoppingCountdown = true
        FlowBarIsland.shared.show(.init(
            title: "Notetaker stopping", kind: .condensed,
            actions: [.init(title: "Keep going") { self.stoppingCountdown = false },
                      .init(title: "Stop") { self.stoppingCountdown = false; MeetingRecorder.shared.stop() }],
            timeout: 10,
            onTimeout: {
                self.stoppingCountdown = false
                guard let id = MeetingRecorder.shared.currentID else { return }
                MeetingRecorder.shared.stop()
                self.stoppedBanner(id)
            }))
    }

    /// "Notetaker stopped – Resume" for 4 s (unless "Started by mistake?" is asking already).
    func stoppedBanner(_ id: UUID, asleep: Bool = false) {
        guard FlowBarIsland.shared.toast == nil else { return }
        FlowBarIsland.shared.show(.init(title: asleep ? "Notetaker stopped when your Mac went to sleep" : "Notetaker stopped",
                                        kind: .condensed,
                                        actions: [.init(title: "Resume") { self.resume(id) }],
                                        timeout: 4, pausesOnHover: false))
    }

    private func recordingStopped(_ id: UUID) {
        summaryWatch[id] = true
        // Fewer than 20 words heard: probably started by mistake.
        let words = MeetingRecorder.shared.liveWordCount
        guard words < 20, let meeting = MeetingStore.shared.meeting(id),
              meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        FlowBarIsland.shared.show(.init(
            title: "Started by mistake?",
            kind: .standard(status: .alert, body: "Only a few words were captured. Keep this meeting or discard it."),
            actions: [.init(title: "Discard", style: .dark) {
                          if NotepadWindow.shared.showingMeetingID == id { NotepadWindow.shared.close() }
                          if HubRouter.shared.selectedMeetingID == id { HubRouter.shared.selectedMeetingID = nil }
                          MeetingStore.shared.delete(id)
                      },
                      .init(title: "Keep", style: .light) {}],
            timeout: 60))
    }

    // MARK: - Opening links

    /// Opens a call link from the calendar, only for known meeting hosts.
    static func openJoinURL(_ url: URL) {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              joinHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            Logger(subsystem: "io.github.h-thavy.onword", category: "notetaker")
                .error("Refusing to open a meeting link on an unknown host")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
