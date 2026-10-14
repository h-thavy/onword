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
        if Self.testUpcoming { return .mac }
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
    private var reminderTimer: Timer?
    private var reminded = Set<String>()
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
            MainActor.assumeIsolated { CalendarService.shared.refresh() }
        }
        // Reminders can be "right before" (15 s), so they're checked more often.
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { CalendarService.shared.remindIfStarting() }
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
    /// Test hook: ONWORD_TEST_UPCOMING=1 shows sample meetings (for snapshots).
    private static let testUpcoming = ProcessInfo.processInfo.environment["ONWORD_TEST_UPCOMING"] != nil

    func refresh(force: Bool = false) {
        if Self.testUpcoming {
            let now = Date(), cal = Calendar.current
            func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
            let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!.addingTimeInterval(10 * 3600)
            let later = cal.date(byAdding: .day, value: 3, to: cal.startOfDay(for: now))!.addingTimeInterval(15 * 3600)
            upcoming = [
                UpcomingMeeting(id: "t1", title: "Design review", start: at(-10), end: at(20), attendees: ["Dara Sok", "Mina Park", "Leo Chan"],
                                joinURL: URL(string: "https://meet.google.com/abc-defg-hij"), platform: .googleMeet, calendarColor: NSColor(srgbRed: 0.47, green: 0.53, blue: 0.80, alpha: 1)),
                UpcomingMeeting(id: "t2", title: "Weekly sync with Sam", start: at(35), end: at(65), attendees: ["Sam Lee"],
                                joinURL: URL(string: "https://zoom.us/j/123"), platform: .zoom, calendarColor: NSColor(srgbRed: 0.01, green: 0.61, blue: 0.90, alpha: 1)),
                UpcomingMeeting(id: "t3", title: "Hiring debrief", start: at(150), end: at(180), attendees: ["Ana Ruiz", "Tom Ng", "Kai Mori", "Eve Stone", "Bo Li"],
                                joinURL: nil, platform: nil, calendarColor: NSColor(srgbRed: 0.20, green: 0.71, blue: 0.47, alpha: 1)),
                UpcomingMeeting(id: "t4", title: "1:1 with Mina", start: tomorrow, end: tomorrow.addingTimeInterval(1800), attendees: ["Mina Park"],
                                joinURL: URL(string: "https://meet.google.com/xyz-abcd-efg"), platform: .googleMeet, calendarColor: NSColor(srgbRed: 0.89, green: 0.49, blue: 0.45, alpha: 1)),
                UpcomingMeeting(id: "t5", title: "Quarterly planning", start: later, end: later.addingTimeInterval(3600), attendees: ["Dara Sok", "Sam Lee"],
                                joinURL: URL(string: "https://zoom.us/j/456"), platform: .zoom, calendarColor: NSColor(srgbRed: 0.56, green: 0.14, blue: 0.67, alpha: 1)),
            ]
            return
        }
        if GoogleCalendar.shared.isConnected {
            guard force || Date().timeIntervalSince(lastGoogleFetch) > 300 else { return }
            lastGoogleFetch = Date()
            googleTask?.cancel()
            googleTask = Task {
                let now = Date()
                let until = Self.windowEnd(from: now)
                do {
                    googleCalendars = try await GoogleCalendar.shared.calendarList()
                    upcoming = Self.windowed(try await GoogleCalendar.shared.meetings(from: now.addingTimeInterval(-3 * 3600), to: until,
                                                                                      hidden: hiddenCalendarIDs), now: now)
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
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: Self.windowEnd(from: now),
                                                 calendars: visible)
        upcoming = Self.windowed(store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled && !declined($0) }
            .compactMap(meeting), now: now)
    }

    /// The end of the last day Onword looks at: today plus 6 days (a week, as in Wispr Flow).
    private static func windowEnd(from now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: now))!
    }

    /// Wispr Flow's upcoming list: meetings that haven't ended (and whose notes aren't finished), up to
    /// 6 days ahead; when there are 20 or more, only up to the day of the 20th; at most 50.
    private static func windowed(_ meetings: [UpcomingMeeting], now: Date) -> [UpcomingMeeting] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let finished = Set(MeetingStore.shared.meetings
            .filter { $0.status == .ready || $0.status == .processing || $0.status == .failed }
            .compactMap(\.calendarEventID))
        let sorted = meetings.filter { $0.end > now && !finished.contains($0.id) }.sorted { $0.start < $1.start }
        func dayOffset(_ m: UpcomingMeeting) -> Int {
            max(0, cal.dateComponents([.day], from: today, to: cal.startOfDay(for: m.start)).day ?? 0)
        }
        let lastDay = sorted.count < 20 ? 6 : min(max(1, dayOffset(sorted[19])), 6)
        return Array(sorted.filter { dayOffset($0) <= lastDay }.prefix(50))
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

    // MARK: - Join

    /// Opens the meeting's call link (known meeting hosts only).
    func join(_ meeting: UpcomingMeeting) {
        if let url = meeting.joinURL { NotetakerFlow.openJoinURL(url) }
    }

    /// "Notify before scheduled meetings start": the reminder pill above the Flow Bar, from the chosen lead
    /// time until 5 minutes after the start (or the end, if sooner).
    private func remindIfStarting() {
        let lead = NotetakerSettings.reminderLeadSeconds
        guard remindersEnabled, lead >= 0 else { return }
        let now = Date()
        for meeting in upcoming where !reminded.contains(meeting.id) {
            let untilStart = meeting.start.timeIntervalSince(now)
            guard untilStart <= TimeInterval(lead), untilStart > -60 else { continue }
            reminded.insert(meeting.id)
            if MeetingRecorder.shared.isRecording, let current = MeetingRecorder.shared.currentID,
               MeetingStore.shared.meeting(current)?.calendarEventID == meeting.id { continue }
            FlowBarIsland.shared.showReminder(.init(
                id: meeting.id, title: meeting.title, start: meeting.start, surface: .scheduled, platform: meeting.platform,
                meeting: meeting, dismissAt: min(meeting.start.addingTimeInterval(300), meeting.end)))
        }
    }
}
