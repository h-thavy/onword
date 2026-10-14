import AppKit
import EventKit
import OnwordCore
import os

/// A calendar event worth recording: has other people or a call link.
struct UpcomingMeeting: Identifiable, Equatable {
    let id: String              // EKEvent.calendarItemIdentifier + start time (recurring events share an ID)
    let title: String
    let start: Date
    let end: Date
    let attendees: [String]     // names, without you
    let joinURL: URL?
    let platform: MeetingPlatform?
    let calendarColor: NSColor

    var isNow: Bool { start <= Date().addingTimeInterval(5 * 60) && end > Date() }
}

/// Upcoming meetings from Google Calendar (signed in with Google) or, alternatively, from the calendars
/// added to macOS (iCloud, Outlook/Exchange… under System Settings → Internet Accounts). Read-only.
@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    enum Access { case notDetermined, granted, denied }

    @Published private(set) var access: Access = .notDetermined
    @Published private(set) var upcoming: [UpcomingMeeting] = []
    @Published private(set) var calendars: [EKCalendar] = []
    @Published private(set) var googleCalendars: [GoogleCalendar.CalendarListEntry] = []

    enum Source { case google, mac, none }
    var source: Source {
        if GoogleCalendar.shared.isConnected { return .google }
        return access == .granted ? .mac : .none
    }
    private var googleTask: Task<Void, Never>?
    private var lastGoogleFetch = Date.distantPast
    /// Calendar identifiers the user turned off.
    @Published var hiddenCalendarIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(hiddenCalendarIDs), forKey: "hiddenCalendars")
            refresh(force: true)
        }
    }
    @Published var remindersEnabled: Bool {
        didSet { UserDefaults.standard.set(remindersEnabled, forKey: "meetingReminders") }
    }

    private let store = EKEventStore()
    private var timer: Timer?
    private var reminded = Set<String>()
    private lazy var prompt = MeetingPromptPanel()
    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "calendar")

    private init() {
        hiddenCalendarIDs = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? [])
        remindersEnabled = UserDefaults.standard.object(forKey: "meetingReminders") as? Bool ?? true
        updateAccess()
    }

    func start() {
        updateAccess()
        refresh()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarService.shared.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                CalendarService.shared.refresh()
                CalendarService.shared.remindIfStarting()
            }
        }
    }

    func requestAccess() {
        Task {
            do {
                _ = try await store.requestFullAccessToEvents()
            } catch {
                log.error("Calendar access request failed: \(error.localizedDescription)")
            }
            updateAccess()
            if access == .denied { Self.openPrivacySettings() }
            refresh()
        }
    }

    static func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    static func openInternetAccounts() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
    }

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .notDetermined
        default: access = .denied
        }
    }

    // MARK: - Events

    /// Reloads meetings. Google is polled at most every 5 minutes unless `force` is set.
    func refresh(force: Bool = false) {
        if GoogleCalendar.shared.isConnected {
            guard force || Date().timeIntervalSince(lastGoogleFetch) > 300 else { return }
            lastGoogleFetch = Date()
            googleTask?.cancel()
            googleTask = Task {
                let now = Date()
                let until = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now))!
                do {
                    googleCalendars = try await GoogleCalendar.shared.calendarList()
                    upcoming = try await GoogleCalendar.shared.meetings(from: now.addingTimeInterval(-3 * 3600), to: until,
                                                                        hidden: hiddenCalendarIDs)
                } catch {
                    log.error("Google Calendar refresh failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }
        googleCalendars = []
        guard access == .granted else { upcoming = []; calendars = []; return }
        calendars = store.calendars(for: .event).sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        let visible = calendars.filter { !hiddenCalendarIDs.contains($0.calendarIdentifier) }
        guard !visible.isEmpty else { upcoming = []; return }

        let now = Date()
        let until = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now))!
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: until, calendars: visible)
        upcoming = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled && !declined($0) }
            .compactMap(meeting)
            .sorted { $0.start < $1.start }
    }

    private func meeting(_ event: EKEvent) -> UpcomingMeeting? {
        let link = MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes])
        let others = (event.attendees ?? []).filter { !$0.isCurrentUser && $0.participantType == .person }
        // Solo blocks (focus time, reminders) aren't meetings.
        guard link != nil || !others.isEmpty else { return nil }
        let names = others.compactMap { participant -> String? in
            if let name = participant.name, !name.isEmpty, !name.contains("@") { return name }
            return participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                .split(separator: "@").first.map { $0.replacingOccurrences(of: ".", with: " ").capitalized }
        }
        return UpcomingMeeting(
            id: "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
            title: event.title?.isEmpty == false ? event.title! : "Untitled meeting",
            start: event.startDate, end: event.endDate, attendees: names,
            joinURL: link?.url, platform: link?.platform, calendarColor: event.calendar.color)
    }

    private func declined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    /// The meeting happening right now (started up to 15 min ago, or starting within 5 min).
    func currentMeeting(at date: Date = Date()) -> UpcomingMeeting? {
        upcoming.filter { $0.start <= date.addingTimeInterval(5 * 60) && $0.end > date }
            .min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }

    // MARK: - Join & record

    /// Opens the call link (if any) and starts recording, titled after the event.
    func joinAndRecord(_ meeting: UpcomingMeeting) {
        if let url = meeting.joinURL { NSWorkspace.shared.open(url) }
        if !MeetingRecorder.shared.isRecording {
            MeetingRecorder.shared.start(title: meeting.title, calendarMeeting: meeting)
        }
        WindowManager.shared.show(.notetaker)
    }

    /// At a meeting's start time, offer to join and record it.
    private func remindIfStarting() {
        guard remindersEnabled, !MeetingRecorder.shared.isRecording else { return }
        let now = Date()
        guard let meeting = upcoming.first(where: { abs($0.start.timeIntervalSince(now)) <= 60 && !reminded.contains($0.id) })
        else { return }
        reminded.insert(meeting.id)
        let message = meeting.joinURL != nil
            ? "Join\(meeting.platform.map { " on \($0.title)" } ?? "") and take notes on this Mac?"
            : "Take notes on this Mac?"
        prompt.show(title: "\(meeting.title) is starting", message: message,
                    acceptTitle: meeting.joinURL != nil ? "Join & Record" : "Record") { accepted in
            if accepted { CalendarService.shared.joinAndRecord(meeting) }
        }
    }
}
