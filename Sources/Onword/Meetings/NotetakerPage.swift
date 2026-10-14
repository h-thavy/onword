import AppKit
import OnwordCore
import SwiftUI

/// The Hub's Notetaker page, laid out like Wispr Flow's: a content column (Ask bar, Today card, Past notes)
/// with a 280-pt preview panel docked on the right. Opening a note swaps the list for the note page.
struct NotetakerPage: View {
    @ObservedObject private var router = HubRouter.shared
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var chat = MeetingChat.shared
    @State private var preview: Preview?
    @State private var askOpen = false

    enum Preview: Equatable {
        case upcoming(UpcomingMeeting)
        case note(UUID)
    }

    var body: some View {
        Group {
            if let id = router.selectedMeetingID, store.meeting(id) != nil {
                HubNotePage(meetingID: id)
            } else if askOpen {
                HubChatView { askOpen = false }
            } else {
                HStack(spacing: 0) {
                    contentColumn
                    SidePreview(preview: preview ?? defaultPreview)
                        .frame(width: 280)
                        .frame(maxHeight: .infinity)
                        .background(NT.sidePanel)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: router.selectedMeetingID)
    }

    private var defaultPreview: Preview? {
        if let next = CalendarService.shared.upcoming.first { return .upcoming(next) }
        return store.meetings.first(where: { $0.status != .draft }).map { .note($0.id) }
    }

    private var contentColumn: some View {
        VStack(spacing: 0) {
            header
                .frame(maxWidth: 1046)
                .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    AskAnythingBar { question in
                        askOpen = true
                        chat.askHub(question)
                    }
                    if !store.meetings.contains(where: { $0.status != .draft }) { ColdStartHero() }
                    TodayCard(preview: $preview)
                    PastNotesSection(preview: $preview)
                }
                .frame(maxWidth: 1046)
                .padding(.horizontal, 40).padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Notetaker").font(Theme.sans(24, .semibold))
            Spacer()
            SettingsGear()
            Button { NotetakerFlow.shared.newNote(source: "hub_header") } label: {
                HStack(spacing: 6) {
                    RecordDot(size: 14, color: Theme.ink)
                    Text("Start Notetaker")
                }
                .font(Theme.sans(15, .semibold)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 12).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.buttonFill))
            }
            .buttonStyle(.plainPointer)
            .keyboardShortcut("n", modifiers: .command)
            .help("Opens the notepad and starts recording (⌘N)")
            .padding(.leading, 4)
        }
    }
}

/// 32-pt gear that turns 60° on hover.
private struct SettingsGear: View {
    @State private var hovering = false

    var body: some View {
        Button { HubRouter.shared.settingsTab = .notetaker } label: {
            Image(systemName: "gearshape").font(.system(size: 17))
                .rotationEffect(.degrees(hovering ? 60 : 0))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.frame : .clear))
        }
        .buttonStyle(.plainPointer)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Open Notetaker settings")
    }
}

// MARK: - Ask anything

private struct AskAnythingBar: View {
    let submit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private static let placeholders = ["Summarize my week of meetings so far", "What are my action items this week?",
                                       "Who am I waiting to hear back from?", "What decisions did we make this week?",
                                       "What questions were left unanswered in my last meeting?",
                                       "How should I prepare for my next meeting?"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        if focused {
                            Text("Ask anything").foregroundStyle(NT.neutral500.opacity(0.5))
                        } else {
                            RollingText(phrases: Self.placeholders, interval: 5, font: Theme.sans(15), color: NT.neutral500.opacity(0.5))
                                .frame(height: 20)
                        }
                    }
                    TextField("", text: $text, axis: .vertical)
                        .textFieldStyle(.plain).font(Theme.sans(15, .medium)).lineLimit(1...4)
                        .focused($focused)
                        .onSubmit(send)
                        // Not focused when the page opens (the window would otherwise pick the first field).
                        .onAppear { DispatchQueue.main.async { focused = false; NSApp.keyWindow?.makeFirstResponder(nil) } }
                }
                .font(Theme.sans(15))
                if !text.isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.onPrimary)
                            .frame(width: 26, height: 26).background(Circle().fill(Theme.primary))
                    }
                    .buttonStyle(.plainPointer)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.init(top: 11, leading: 18, bottom: 11, trailing: 11))
            .frame(minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 25).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(focused ? NT.neutral500 : Theme.border))
            .background(RoundedRectangle(cornerRadius: 28).fill(focused ? Theme.mutedCard : .clear).padding(-3))
            if focused && text.isEmpty {
                HStack(spacing: 8) {
                    ForEach(MeetingChat.hubPrompts, id: \.self) { prompt in
                        Button { submit(prompt) } label: {
                            Text(prompt).font(Theme.sans(12, .medium)).foregroundStyle(Theme.inkTertiary)
                                .padding(.horizontal, 12).frame(height: 28)
                                .background(Capsule().fill(Theme.shortcutPill))
                                .overlay(Capsule().strokeBorder(Theme.buttonFill))
                        }
                        .buttonStyle(.plainPointer)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: focused)
        .animation(.easeOut(duration: 0.15), value: text.isEmpty)
    }

    private func send() {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        text = ""
        submit(question)
    }
}

/// The Hub's chat (Ask anything across meetings), replacing the page body.
private struct HubChatView: View {
    let close: () -> Void
    @ObservedObject private var chat = MeetingChat.shared
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HeaderIconButton(icon: "chevron.left", help: "Back", filled: true, action: close)
                Spacer()
                HeaderIconButton(icon: "square.and.pencil", help: "New chat") { chat.clear(MeetingChat.hubID) }
            }
            .padding(24)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(chat.hubMessages) { ChatBubble(message: $0).id($0.id) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 744).padding(.horizontal, 24).frame(maxWidth: .infinity)
                }
                .onChange(of: chat.hubMessages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack(spacing: 8) {
                TextField("", text: $text, prompt: Text("Ask anything").foregroundStyle(NT.neutral500.opacity(0.5)), axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.sans(15, .medium)).lineLimit(1...4)
                    .onSubmit(send)
                if chat.answering.contains(MeetingChat.hubID) {
                    Button { chat.stop(MeetingChat.hubID) } label: {
                        RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 10, height: 10)
                            .frame(width: 26, height: 26).background(Circle().fill(Color(hex: 0xA39D8E)))
                    }
                    .buttonStyle(.plainPointer)
                } else if !text.isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.onPrimary)
                            .frame(width: 26, height: 26).background(Circle().fill(Theme.primary))
                    }
                    .buttonStyle(.plainPointer)
                }
            }
            .padding(.init(top: 11, leading: 18, bottom: 11, trailing: 11))
            .frame(minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 25).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(Theme.border))
            .frame(maxWidth: 744)
            .padding(24)
        }
    }

    private func send() {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        text = ""
        chat.askHub(question)
    }
}

// MARK: - Cold start

/// "Take Notetaker for a test run": a dark hero until the first note is recorded.
private struct ColdStartHero: View {
    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Take Notetaker for a test run").font(Theme.serif(28)).tracking(-1.12).foregroundStyle(NT.lumen)
                    Text("Transcript, summary, and action items for every meeting").font(Theme.sans(15)).foregroundStyle(NT.lumen.opacity(0.8))
                }
                Button { NotetakerFlow.shared.newNote(source: "hub_cold_hero") } label: {
                    Text("Start Notetaker").font(Theme.sans(15, .semibold)).foregroundStyle(Color(hex: 0x1A1A1A))
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0xEEEBE3)))
                }
                .buttonStyle(.plainPointer)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HeroArt().frame(width: 300, height: 136).clipped()
        }
        .padding(.init(top: 12, leading: 24, bottom: 12, trailing: 12))
        .frame(minHeight: 160)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x1A1A1A)))
    }
}

/// Chat bubbles and two speaker tiles, standing in for Wispr's hero illustration.
private struct HeroArt: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                bubble(width: 120, color: 0x30302F)
                bubble(width: 90, color: 0xA26EC1)
                bubble(width: 130, color: 0x30302F)
                bubble(width: 70, color: 0xFB923C)
            }
            .frame(width: 140)
            tile(name: "Alex Kim", size: 64, color: 0xE89F4D)
            tile(name: "Sam Lee", size: 84, color: 0x6B3FAB).offset(y: -16)
        }
    }

    private func bubble(width: CGFloat, color: UInt32) -> some View {
        RoundedRectangle(cornerRadius: 8).fill(Color(hex: color)).frame(width: width, height: 22)
    }

    private func tile(name: String, size: CGFloat, color: UInt32) -> some View {
        RoundedRectangle(cornerRadius: 14).fill(Color(hex: color).opacity(0.85))
            .overlay(Text(name.split(separator: " ").compactMap(\.first).map(String.init).joined())
                .font(Theme.sans(size / 3, .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

// MARK: - Today card

private struct TodayCard: View {
    @Binding var preview: NotetakerPage.Preview?
    @ObservedObject private var calendar = CalendarService.shared
    @ObservedObject private var google = GoogleCalendar.shared
    @State private var showAll = false
    @State private var syncing = false

    private var groups: [(label: String, meetings: [UpcomingMeeting])] {
        let cal = Calendar.current
        var result: [(String, [UpcomingMeeting])] = []
        for meeting in calendar.upcoming {
            let label = cal.isDateInToday(meeting.start) || meeting.start < Date() ? "Today"
                : cal.isDateInTomorrow(meeting.start) ? "Tomorrow"
                : meeting.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            if result.last?.0 == label { result[result.count - 1].1.append(meeting) } else { result.append((label, [meeting])) }
        }
        return result.map { (label: $0.0, meetings: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Overline(text: "Today")
                Spacer()
                if calendar.source != .none {
                    Button {
                        syncing = true
                        calendar.refresh(force: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { syncing = false }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                            .rotationEffect(.degrees(syncing ? 360 : 0))
                            .animation(syncing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: syncing)
                            .frame(width: 24, height: 24).foregroundStyle(Theme.iconFaint)
                    }
                    .buttonStyle(.plainPointer)
                    .help(syncing ? "Syncing…" : "Sync calendar")
                }
            }
            .padding(.leading, 20).padding(.trailing, 12).padding(.top, 12)
            content
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.frame))
    }

    @ViewBuilder private var content: some View {
        if calendar.source == .none {
            VStack(spacing: 8) {
                Image(systemName: "calendar").font(.system(size: 22)).foregroundStyle(Theme.inkTertiary)
                Text("No meetings found").font(Theme.sans(18, .medium))
                Text("Add calendar for accurate speaker names and richer summaries on all meetings")
                    .font(Theme.sans(15)).foregroundStyle(Theme.inkTertiary).multilineTextAlignment(.center)
                Button {
                    if google.isConfigured { google.connect() } else { calendar.requestAccess() }
                } label: {
                    Text(google.isConnecting ? "Waiting for Google…" : "Connect calendar")
                }
                .buttonStyle(.pill).controlSize(.small).padding(.top, 8)
                .disabled(google.isConnecting)
                if google.isConfigured {
                    Button("Use Mac Calendar instead") { calendar.requestAccess() }
                        .buttonStyle(.plainPointer).font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.init(top: 16, leading: 16, bottom: 32, trailing: 16))
        } else if calendar.upcoming.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "calendar").font(.system(size: 16)).foregroundStyle(Theme.inkTertiary)
                    .padding(12).background(Circle().fill(Theme.page)).overlay(Circle().strokeBorder(Theme.border))
                Text("There are no more meetings today or tomorrow").font(Theme.sans(16, .medium)).foregroundStyle(Theme.inkTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32).padding(.horizontal, 16)
        } else {
            let all = groups
            let shown = showAll ? all : limit(all, to: 3)
            VStack(alignment: .leading, spacing: 4) {
                if !all.contains(where: { $0.label == "Today" }) {
                    Text("No meetings today").font(Theme.sans(16)).frame(maxWidth: .infinity).padding(16)
                }
                ForEach(shown, id: \.label) { group in
                    if group.label != "Today" {
                        Overline(text: group.label).padding(.init(top: 12, leading: 12, bottom: 4, trailing: 0))
                    }
                    ForEach(group.meetings) { meeting in
                        UpcomingRowView(meeting: meeting, preview: $preview)
                    }
                }
                if all.reduce(0, { $0 + $1.meetings.count }) > 3 {
                    Button { showAll.toggle() } label: {
                        HStack(spacing: 4) {
                            Text(showAll ? "Show less" : "Show more")
                            Image(systemName: showAll ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
                        }
                        .font(Theme.sans(15, .medium)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 12).frame(height: 32)
                    }
                    .buttonStyle(.plainPointer)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
    }

    private func limit(_ groups: [(label: String, meetings: [UpcomingMeeting])], to count: Int) -> [(label: String, meetings: [UpcomingMeeting])] {
        var left = count
        var result: [(label: String, meetings: [UpcomingMeeting])] = []
        for group in groups where left > 0 {
            let taken = Array(group.meetings.prefix(left))
            left -= taken.count
            result.append((group.label, taken))
        }
        return result
    }
}

private struct UpcomingRowView: View {
    let meeting: UpcomingMeeting
    @Binding var preview: NotetakerPage.Preview?
    @ObservedObject private var recorder = MeetingRecorder.shared
    @State private var hovering = false

    private var happeningNow: Bool { meeting.start <= Date() && meeting.end > Date() }
    private var recordingThis: Bool {
        guard let id = recorder.currentID else { return false }
        return MeetingStore.shared.meeting(id)?.calendarEventID == meeting.id
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: meeting.calendarColor)).frame(width: 4, height: 36)
            Facepile(names: meeting.attendees)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).font(Theme.sans(15, happeningNow ? .medium : .regular)).lineLimit(1)
                Text(NT.timeRange(meeting.start, meeting.end)).font(Theme.sans(12))
                    .foregroundStyle(Calendar.current.isDateInToday(meeting.start) ? Theme.ink : Theme.inkTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !recordingThis, let label = NT.countdown(start: meeting.start, end: meeting.end) {
                HStack(spacing: 6) {
                    if let icon = label.icon { Image(systemName: icon).font(.system(size: 12)) }
                    Text(label.text)
                }
                .font(Theme.sans(15)).foregroundStyle(NT.neutral500)
            }
            if recordingThis {
                LiveCluster(level: max(recorder.micLevel, recorder.systemLevel), elapsed: recorder.elapsed) {
                    if let id = recorder.currentID { NotetakerFlow.shared.openNote(id) }
                }
            } else if hovering || happeningNow {
                JoinStartButton(meeting: meeting, prominent: happeningNow)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(hovering ? Theme.buttonFill : .clear))
        .contentShape(Rectangle())
        .onTapGesture { NotetakerFlow.shared.openDraft(for: meeting) }
        .onHover { inside in
            hovering = inside
            if inside { preview = .upcoming(meeting) }
        }
        .pointerCursor()
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Past notes

private struct PastNotesSection: View {
    @Binding var preview: NotetakerPage.Preview?
    @ObservedObject private var store = MeetingStore.shared
    @State private var searching = false
    @State private var query = ""

    private var notes: [Meeting] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return store.meetings.filter { m in
            guard m.status != .draft || !m.notes.isEmpty else { return false }
            guard !q.isEmpty else { return true }
            return m.title.localizedCaseInsensitiveContains(q) || m.notes.localizedCaseInsensitiveContains(q)
                || (m.summary ?? "").localizedCaseInsensitiveContains(q)
                || m.segments.contains { $0.text.localizedCaseInsensitiveContains(q) }
        }
    }

    private var groups: [(day: String, meetings: [Meeting])] {
        var result: [(String, [Meeting])] = []
        for meeting in notes {
            let day = NT.dayBucket(meeting.startedAt)
            if result.last?.0 == day { result[result.count - 1].1.append(meeting) } else { result.append((day, [meeting])) }
        }
        return result.map { (day: $0.0, meetings: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 0) {
                Text("Past notes").font(Theme.sans(15, .semibold)).padding(12)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.ink).frame(height: 2).padding(.horizontal, 12) }
                Spacer()
                if searching {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.inkTertiary)
                        TextField("Search past notes", text: $query).textFieldStyle(.plain).font(Theme.sans(13))
                        Button { query = ""; searching = false } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.inkTertiary)
                        }
                        .buttonStyle(.plainPointer)
                    }
                    .padding(.horizontal, 8).frame(width: 200, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                } else {
                    BarAction(icon: "magnifyingglass", help: "Search past meetings") { searching = true }
                }
            }
            .padding(.horizontal, -12)
            .background(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            if groups.isEmpty {
                EmptyState(title: query.isEmpty ? "Your meetings will appear here" : "No notes found for “\(query)”")
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(groups, id: \.day) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Overline(text: group.day, color: NT.neutral500).padding(.leading, 6)
                            ForEach(group.meetings) { meeting in PastRow(meeting: meeting, preview: $preview) }
                        }
                    }
                }
            }
        }
    }
}

private struct PastRow: View {
    let meeting: Meeting
    @Binding var preview: NotetakerPage.Preview?
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var summarizer = MeetingSummarizer.shared
    @State private var hovering = false

    private var live: Bool { recorder.currentID == meeting.id }
    private var people: [String] { (meeting.attendees ?? []) + (meeting.participants ?? []) }

    var body: some View {
        HStack(spacing: 12) {
            Facepile(names: Array(Set(people)).sorted(), dimmed: !hovering)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.displayTitle).font(Theme.sans(15)).lineLimit(1)
                HStack(spacing: 0) {
                    Text(NT.clock(meeting.startedAt))
                    status
                }
                .font(Theme.sans(12)).foregroundStyle(hovering ? NT.neutral500 : Theme.ink)
            }
            .opacity(hovering ? 1 : 0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if live {
                    LiveCluster(level: max(recorder.micLevel, recorder.systemLevel), elapsed: recorder.elapsed) {
                        NotetakerFlow.shared.openNote(meeting.id)
                    }
                }
                let todos = meeting.activeTodos
                if !todos.isEmpty {
                    TasksChip(done: todos.filter(\.done).count, total: todos.count) { open(tab: .tasks) }
                }
                if hovering {
                    NoteMoreMenu(meeting: meeting)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .padding(12)
        .frame(minHeight: 60)
        .background(RoundedRectangle(cornerRadius: 12).fill(hovering ? Theme.frame : .clear))
        .contentShape(Rectangle())
        .onTapGesture { open(tab: nil) }
        .onHover { inside in
            hovering = inside
            if inside { preview = .note(meeting.id) }
        }
        .pointerCursor()
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder private var status: some View {
        if live {
            dot; Text("Recording").foregroundStyle(NT.liveText)
        } else if meeting.status == .processing || summarizer.working.contains(meeting.id) {
            dot
            RollingText(phrases: ["Tidying up the transcript", "Spotting action items", "Pulling out highlights",
                                  "Noting who said what", "Wrapping up"], interval: 7, font: Theme.sans(12), color: NT.neutral500)
                .frame(height: 16)
        } else if meeting.status == .failed {
            dot
            Text("Failed. ")
            Button { MeetingRecorder.shared.process(meeting.id) } label: { Text("Retry").underline() }.buttonStyle(.plainPointer)
        } else if meeting.summaryDeferred == true, meeting.summary == nil, !meeting.segments.isEmpty {
            dot
            Button {
                MeetingStore.shared.update(meeting.id) { $0.summaryDeferred = nil }
                summarizer.summarize(meeting.id)
            } label: { Text("Generate summary").underline() }
            .buttonStyle(.plainPointer)
        } else if meeting.duration > 0 {
            dot; Text("\(max(1, Int((meeting.duration / 60).rounded()))) min")
        }
    }

    private var dot: some View { Text(" • ") }

    private func open(tab: NoteTab?) {
        if live {
            NotetakerFlow.shared.openNote(meeting.id)
        } else {
            HubRouter.shared.noteTab = tab ?? (meeting.status == .draft ? .notes : .summary)
            HubRouter.shared.selectedMeetingID = meeting.id
        }
    }
}

// MARK: - Side panel

private struct SidePreview: View {
    let preview: NotetakerPage.Preview?
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var summarizer = MeetingSummarizer.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch preview {
                case .upcoming(let meeting): upcoming(meeting)
                case .note(let id): if let meeting = store.meeting(id) { past(meeting) }
                case nil: EmptyView()
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func upcoming(_ meeting: UpcomingMeeting) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            section(first: true) {
                if meeting.id == CalendarService.shared.upcoming.first?.id, meeting.start > Date() {
                    Text("UP NEXT").font(Theme.sans(12, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.black))
                        .padding(.bottom, 8)
                }
                Text(meeting.title).font(Theme.sans(18, .semibold))
                Text(upcomingLine(meeting)).font(Theme.sans(15))
                JoinStartButton(meeting: meeting, prominent: meeting.start <= Date())
                    .padding(.top, 8)
            }
            if !meeting.attendees.isEmpty {
                divider
                section { AttendeeList(names: meeting.attendees).padding(-16) }
            }
        }
    }

    private func past(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            section(first: true) {
                Text(meeting.displayTitle).font(Theme.sans(18, .semibold))
                Text(pastLine(meeting)).font(Theme.sans(15)).foregroundStyle(NT.neutral500)
            }
            let people = (meeting.attendees ?? []) + (meeting.participants ?? [])
            if !people.isEmpty {
                divider
                section { AttendeeList(names: Array(Set(people)).sorted()).padding(-16) }
            }
            divider
            section {
                Overline(text: "Overview", color: Theme.inkTertiary)
                if let summary = meeting.summary {
                    Text(summary).font(Theme.sans(15)).lineSpacing(4).lineLimit(14)
                } else if meeting.status == .processing || summarizer.working.contains(meeting.id) {
                    RollingText(phrases: ["Tidying up the transcript", "Spotting action items", "Pulling out highlights"],
                                interval: 7, font: Theme.sans(15), color: NT.neutral500)
                        .frame(height: 20)
                } else {
                    Text(meeting.notes.isEmpty ? "No summary yet" : String(meeting.notes.prefix(600)))
                        .font(Theme.sans(15)).foregroundStyle(meeting.notes.isEmpty ? Theme.inkTertiary : Theme.ink)
                }
            }
        }
    }

    private var divider: some View { Rectangle().fill(Theme.border).frame(height: 1) }

    /// "Today • 10 - 10:30am • in 5 min".
    private func upcomingLine(_ meeting: UpcomingMeeting) -> String {
        var parts: [String] = [NT.datePill(meeting.start), NT.timeRange(meeting.start, meeting.end)]
        if let countdown = NT.countdown(start: meeting.start, end: meeting.end) { parts.append(countdown.text) }
        return parts.joined(separator: " • ")
    }

    /// "Yesterday • 32 min".
    private func pastLine(_ meeting: Meeting) -> String {
        var parts: [String] = [NT.datePill(meeting.startedAt)]
        if meeting.duration > 0 {
            let minutes = max(1, Int((meeting.duration / 60).rounded()))
            parts.append("\(minutes) min")
        }
        return parts.joined(separator: " • ")
    }

    private func section<Content: View>(first: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(.horizontal, 24).padding(.top, first ? 40 : 24).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Note page (L2)

/// A note opened in the Hub: Back, ⋯, previous/next (J/K) and "Open note in window" above the title.
private struct HubNotePage: View {
    let meetingID: UUID
    @ObservedObject private var router = HubRouter.shared
    @ObservedObject private var store = MeetingStore.shared

    private var ordered: [Meeting] { store.meetings.filter { $0.status != .draft || !$0.notes.isEmpty } }
    private var index: Int? { ordered.firstIndex { $0.id == meetingID } }

    var body: some View {
        if let meeting = store.meeting(meetingID) {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    HeaderIconButton(icon: "chevron.left", help: "Back", filled: true) { router.selectedMeetingID = nil }
                    Spacer()
                    NoteMoreMenu(meeting: meeting) { router.selectedMeetingID = nil }
                    HeaderIconButton(icon: "chevron.left", help: "Previous note (J)", disabled: (index ?? 0) <= 0) { step(-1) }
                        .keyboardShortcut("j", modifiers: [])
                    HeaderIconButton(icon: "chevron.right", help: "Next note (K)", disabled: (index ?? ordered.count) >= ordered.count - 1) { step(1) }
                        .keyboardShortcut("k", modifiers: [])
                    HeaderIconButton(icon: "pip", help: "Open note in window") {
                        NotepadWindow.shared.show(meetingID, focus: true, tab: router.noteTab)
                    }
                }
                .padding(.bottom, 12)
                VStack(alignment: .leading, spacing: 4) {
                    NoteTitleField(meetingID: meetingID)
                    NotePills(meeting: meeting).padding(.horizontal, 8).padding(.bottom, 12)
                    NoteBody(meetingID: meetingID, tab: $router.noteTab, inHub: true)
                }
                .frame(maxWidth: 744)
                .frame(maxWidth: .infinity)
            }
            .padding(.init(top: 24, leading: 24, bottom: 0, trailing: 24))
            .overlay {
                UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 24)
                    .strokeBorder(Theme.buttonFill, lineWidth: 4)
                    .allowsHitTesting(false)
            }
            .transition(.opacity)
        }
    }

    private func step(_ delta: Int) {
        guard let index, ordered.indices.contains(index + delta) else { return }
        router.selectedMeetingID = ordered[index + delta].id
    }
}
