import AppKit
import OnwordCore
import SwiftUI

/// Notetaker: past notes by day on the left, the selected meeting on the right.
struct NotetakerPage: View {
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var router = HubRouter.shared
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            HStack(spacing: 0) {
                list
                    .frame(width: 300)
                Divider().overlay(Theme.border)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { router.selectedMeetingID = router.selectedMeetingID ?? store.meetings.first?.id }
        .onChange(of: recorder.currentID) { _, id in if let id { router.selectedMeetingID = id } }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Notetaker").font(Theme.serif(34))
            Spacer()
            IconButton(systemImage: "gearshape", help: "Notetaker settings") { router.settingsTab = .notetaker }
            if recorder.isRecording {
                Button { recorder.stop() } label: {
                    HStack(spacing: 7) {
                        Circle().fill(.white).frame(width: 7, height: 7)
                        Text("Stop  \(TimeFormat.clock(recorder.elapsed))").monospacedDigit()
                    }
                }
                .buttonStyle(PillButtonStyle(tint: Theme.recording))
            } else {
                Button { recorder.start() } label: { Label("Start Notetaker", systemImage: "record.circle") }
                    .buttonStyle(.pill)
            }
        }
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 16)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            UpcomingSection()
            HStack {
                Text("Past notes").font(Theme.sans(13, .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.selected))
                Spacer()
            }
            SearchField(prompt: "Search past meetings", text: $query)
            if let warning = recorder.systemAudioWarning {
                Text(warning).font(Theme.sans(12)).foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.day) { group in
                        SectionLabel(text: group.day).padding(.leading, 10).padding(.top, 10).padding(.bottom, 2)
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting, selected: router.selectedMeetingID == meeting.id)
                                .onTapGesture { router.selectedMeetingID = meeting.id }
                                .contextMenu {
                                    Button("Delete", role: .destructive) { delete(meeting.id) }
                                }
                        }
                    }
                    if groups.isEmpty {
                        Text(query.isEmpty ? "No meetings yet." : "No matches.")
                            .foregroundStyle(Theme.inkTertiary).padding(10)
                    }
                }
            }
        }
        .padding(16)
    }

    private var groups: [(day: String, meetings: [Meeting])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = store.meetings.filter { m in
            q.isEmpty || m.title.localizedCaseInsensitiveContains(q)
                || m.segments.contains { $0.text.localizedCaseInsensitiveContains(q) }
        }
        var result: [(String, [Meeting])] = []
        for meeting in filtered {
            let day = HistoryStore.dayLabel(meeting.startedAt)
            if result.last?.0 == day { result[result.count - 1].1.append(meeting) } else { result.append((day, [meeting])) }
        }
        return result.map { (day: $0.0, meetings: $0.1) }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = router.selectedMeetingID, let meeting = store.meeting(id) {
            MeetingDetail(meeting: meeting)
        } else {
            VStack(spacing: 14) {
                Text("Bot-free meeting notes").font(Theme.serif(28))
                Text("Start Notetaker when a call begins, or let Onword ask when it notices one. Your mic and the call are recorded separately, transcribed on this Mac, and tagged by speaker.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.inkTertiary).frame(maxWidth: 420)
                Button { recorder.start() } label: { Label("Start Notetaker", systemImage: "record.circle") }.buttonStyle(.pill)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func delete(_ id: UUID) {
        if router.selectedMeetingID == id { router.selectedMeetingID = nil }
        store.delete(id)
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).font(Theme.sans(13.5, .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(meeting.startedAt.formatted(date: .omitted, time: .shortened).lowercased())
                    switch meeting.status {
                    case .recording: Text("· Recording").foregroundStyle(Theme.recording)
                    case .processing: Text("· Processing…")
                    case .failed: Text("· Failed").foregroundStyle(Theme.recording)
                    case .ready: if meeting.duration > 0 { Text("· \(TimeFormat.clock(meeting.duration))") }
                    }
                }
                .font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
            }
            Spacer(minLength: 4)
            if meeting.status == .ready, meeting.summary == nil, !meeting.segments.isEmpty,
               MeetingSummarizer.shared.unavailableReason == nil, hovering || selected {
                Button("Generate summary") { MeetingSummarizer.shared.summarize(meeting.id) }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(selected ? Theme.selected : (hovering ? Theme.hover : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct MeetingDetail: View {
    let meeting: Meeting
    @ObservedObject private var store = MeetingStore.shared
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                content
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 32).padding(.vertical, 26)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: Binding(get: { renaming.map(IdentifiedString.init) }, set: { renaming = $0?.value })) { item in
            RenameSheet(name: $newName, original: meeting.name(for: item.value),
                        suggestions: suggestions(excluding: item.value)) {
                rename(item.value, to: newName.trimmingCharacters(in: .whitespaces))
                renaming = nil
            } cancel: { renaming = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                TextField("Title", text: Binding(get: { meeting.title },
                                                 set: { title in store.update(meeting.id) { $0.title = title } }))
                    .textFieldStyle(.plain)
                    .font(Theme.serif(30))
                Spacer()
                Menu {
                    Button("Copy as Markdown") { copyMarkdown() }.disabled(meeting.segments.isEmpty)
                    Button("Export…") { exportMarkdown() }.disabled(meeting.segments.isEmpty)
                    Button("Show audio files") { NSWorkspace.shared.activateFileViewerSelecting([meeting.folder]) }
                    Divider()
                    Button("Generate summary") { MeetingSummarizer.shared.summarize(meeting.id) }
                        .disabled(meeting.status != .ready || meeting.segments.isEmpty || MeetingSummarizer.shared.unavailableReason != nil)
                    Button("Re-process") { MeetingRecorder.shared.process(meeting.id) }
                        .disabled(meeting.status == .recording || meeting.status == .processing)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Text(subtitle).font(Theme.sans(13.5)).foregroundStyle(Theme.inkTertiary)

            if !meeting.speakers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Attendees")
                    FlowRow(spacing: 6) {
                        ForEach(meeting.speakers, id: \.self) { speaker in
                            Button {
                                newName = meeting.name(for: speaker)
                                renaming = speaker
                            } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(SpeakerColor.color(for: speaker)).frame(width: 7, height: 7)
                                    Text(meeting.name(for: speaker)).font(Theme.sans(13, .medium))
                                    if speaker == "me" { Text("(you)").font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary) }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(Theme.card))
                                .overlay(Capsule().strokeBorder(Theme.border))
                            }
                            .buttonStyle(.plain)
                            .help("Rename — use a name another speaker has to merge them")
                        }
                    }
                }
            }
        }
    }

    private var subtitle: String {
        var parts = [meeting.startedAt.formatted(.dateTime.weekday(.wide))]
        let start = meeting.startedAt.formatted(date: .omitted, time: .shortened).lowercased()
        if meeting.duration > 0 {
            let end = meeting.startedAt.addingTimeInterval(meeting.duration).formatted(date: .omitted, time: .shortened).lowercased()
            parts.append("\(start) – \(end)")
        } else {
            parts.append(start)
        }
        if let platform = meeting.platform.flatMap(MeetingPlatform.init(rawValue:)) { parts.append(platform.title) }
        if !meeting.hasSystemAudio { parts.append("microphone only") }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder
    private var content: some View {
        switch meeting.status {
        case .recording:
            LiveTranscriptView()
        case .processing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(meeting.statusDetail ?? "Processing…").foregroundStyle(Theme.inkTertiary)
            }
            .padding(.vertical, 20)
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                Label("Couldn't process this meeting", systemImage: "exclamationmark.triangle").font(Theme.sans(15, .semibold))
                Text(meeting.statusDetail ?? "").foregroundStyle(Theme.inkTertiary)
                Button("Re-process") { MeetingRecorder.shared.process(meeting.id) }.buttonStyle(.pillQuiet)
            }
        case .ready where meeting.segments.isEmpty:
            Text(meeting.statusDetail ?? "No speech was detected.").foregroundStyle(Theme.inkTertiary)
        case .ready:
            NotesSection(meeting: meeting)
            VStack(alignment: .leading, spacing: 14) {
                Text("Transcript").font(Theme.serif(22))
                ForEach(meeting.segments) { segment in
                    SegmentRow(segment: segment, name: meeting.name(for: segment.speaker))
                }
            }
            .textSelection(.enabled)
        }
    }

    /// Names from the calendar invite and the call app that aren't used by another speaker yet.
    private func suggestions(excluding speaker: String) -> [String] {
        let used = Set(meeting.speakers.filter { $0 != speaker }.map { meeting.name(for: $0).lowercased() })
        var seen = Set<String>()
        return ((meeting.attendees ?? []) + (meeting.participants ?? []))
            .filter { !used.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
    }

    /// Renaming a speaker to a name another speaker already has means "same person": merge them.
    private func rename(_ speaker: String, to name: String) {
        store.update(meeting.id) { m in
            if let existing = m.speakers.first(where: { $0 != speaker && m.name(for: $0).caseInsensitiveCompare(name) == .orderedSame }) {
                m.segments = TranscriptMerger.reassign(m.segments, from: speaker, to: existing)
                m.speakerNames[speaker] = nil
            } else {
                m.speakerNames[speaker] = name
            }
        }
    }

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meeting.markdown, forType: .string)
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? meeting.markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// The rough transcript while recording. Auto-scrolls as new lines arrive.
private struct LiveTranscriptView: View {
    @ObservedObject private var recorder = MeetingRecorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(Theme.recording).frame(width: 8, height: 8)
                Text("Live transcript").font(Theme.sans(13, .semibold))
                Text("rough — the full, speaker-tagged version is made when you stop")
                    .font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
            }
            HStack(spacing: 14) {
                LevelBar(label: "You", level: recorder.micLevel)
                LevelBar(label: "Call", level: recorder.systemLevel)
            }
            if recorder.liveSegments.isEmpty {
                Text("Listening… lines appear here every few seconds.").foregroundStyle(Theme.inkTertiary)
            } else {
                ForEach(recorder.liveSegments) { segment in
                    SegmentRow(segment: segment, name: segment.speaker)
                }
            }
        }
    }
}

private struct LevelBar: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.sans(11.5)).foregroundStyle(Theme.inkTertiary)
            GeometryReader { geo in
                Capsule().fill(Theme.selected)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.ink).frame(width: geo.size.width * CGFloat(min(1, level)))
                    }
            }
            .frame(width: 90, height: 4)
        }
    }
}

/// Summary, decisions and action items written by Apple's on-device model.
private struct NotesSection: View {
    let meeting: Meeting
    @ObservedObject private var summarizer = MeetingSummarizer.shared
    @ObservedObject private var store = MeetingStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if summarizer.working.contains(meeting.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(summarizer.progress[meeting.id] ?? "Writing notes…").foregroundStyle(Theme.inkTertiary)
                }
            } else if let summary = meeting.summary {
                block("Summary") { Text(summary).font(Theme.sans(14.5)).lineSpacing(3) }
                if let decisions = meeting.decisions, !decisions.isEmpty {
                    block("Decisions") {
                        ForEach(decisions, id: \.self) { decision in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(Theme.inkTertiary)
                                Text(decision)
                            }
                        }
                    }
                }
                if let todos = meeting.todos, !todos.isEmpty {
                    block("Action items") {
                        ForEach(todos) { todo in TodoRow(meetingID: meeting.id, todo: todo) }
                    }
                }
                Text("Written on this Mac by Apple Intelligence. Check it against the transcript.")
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.inkTertiary)
            } else if let error = meeting.summaryError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let reason = summarizer.unavailableReason {
                Label(reason, systemImage: "sparkles").foregroundStyle(Theme.inkTertiary)
            } else {
                Button { summarizer.summarize(meeting.id) } label: {
                    Label("Generate summary", systemImage: "sparkles")
                }
                .buttonStyle(.pill)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium).strokeBorder(Theme.border))
    }

    private func block(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.serif(20))
            content()
        }
    }
}

private struct TodoRow: View {
    let meetingID: UUID
    let todo: MeetingTodo

    var body: some View {
        Button {
            MeetingStore.shared.update(meetingID) { m in
                if let i = m.todos?.firstIndex(where: { $0.id == todo.id }) { m.todos?[i].done.toggle() }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16)).foregroundStyle(todo.done ? Theme.ink : Theme.inkTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(todo.task).strikethrough(todo.done).foregroundStyle(todo.done ? Theme.inkTertiary : Theme.ink)
                    let details = [todo.owner, todo.due.map { "due \($0)" }].compactMap { $0 }
                    if !details.isEmpty {
                        Text(details.joined(separator: " · ")).font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(name).font(Theme.sans(13, .semibold)).foregroundStyle(SpeakerColor.color(for: segment.speaker))
                Text(TimeFormat.clock(segment.start)).font(Theme.sans(11.5).monospacedDigit()).foregroundStyle(Theme.inkTertiary)
            }
            Text(segment.text).font(Theme.sans(14.5)).lineSpacing(2)
        }
    }
}

private struct RenameSheet: View {
    @Binding var name: String
    let original: String
    var suggestions: [String] = []
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Who is “\(original)”?").font(Theme.serif(24))
            TextField("Name", text: $name).textFieldStyle(.plain).font(Theme.sans(14))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
                .onSubmit(save)
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "From the invite")
                    FlowRow(spacing: 6) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { name = suggestion }
                                .buttonStyle(PillButtonStyle(prominent: name == suggestion))
                        }
                    }
                }
            }
            Text("Use a name another speaker already has to merge them into one person.")
                .font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(.pillQuiet).keyboardShortcut(.cancelAction)
                Button("Rename", action: save).buttonStyle(.pill).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(Theme.panel)
    }
}

private struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
}

/// Wraps chips onto multiple lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

enum SpeakerColor {
    // Muted tones that sit well on the sand palette.
    private static let palette: [Color] = [
        Color(red: 0.36, green: 0.42, blue: 0.75), Color(red: 0.55, green: 0.32, blue: 0.62),
        Color(red: 0.78, green: 0.45, blue: 0.24), Color(red: 0.20, green: 0.55, blue: 0.55),
        Color(red: 0.72, green: 0.30, blue: 0.45), Color(red: 0.42, green: 0.36, blue: 0.70),
    ]

    static func color(for speaker: String) -> Color {
        if speaker == "me" || speaker == "You" { return Color(red: 0.25, green: 0.55, blue: 0.35) }
        if speaker.first == "s", let number = Int(speaker.dropFirst()) {
            return palette[abs(number - 1) % palette.count]
        }
        let hash = speaker.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }
}

/// Today's and tomorrow's meetings from the calendar, with one-click Join & Record.
private struct UpcomingSection: View {
    @ObservedObject private var calendar = CalendarService.shared
    @ObservedObject private var google = GoogleCalendar.shared
    @ObservedObject private var recorder = MeetingRecorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Upcoming").font(Theme.sans(13, .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.selected))
                Spacer()
            }
            if google.isConnected || calendar.access == .granted {
                if calendar.upcoming.isEmpty {
                    Text("No more meetings today or tomorrow.").font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
                        .padding(.horizontal, 10)
                } else {
                    ForEach(groups, id: \.day) { group in
                        SectionLabel(text: group.day).padding(.leading, 10).padding(.top, 4)
                        ForEach(group.meetings) { meeting in
                            UpcomingRow(meeting: meeting, recording: recorder.isRecording)
                        }
                    }
                }
            } else {
                ConnectCalendarCard()
            }
        }
        .padding(.bottom, 6)
    }

    private var groups: [(day: String, meetings: [UpcomingMeeting])] {
        var result: [(String, [UpcomingMeeting])] = []
        for meeting in calendar.upcoming.prefix(8) {
            let day = HistoryStore.dayLabel(meeting.start)
            if result.last?.0 == day { result[result.count - 1].1.append(meeting) } else { result.append((day, [meeting])) }
        }
        return result.map { (day: $0.0, meetings: $0.1) }
    }
}

private struct UpcomingRow: View {
    let meeting: UpcomingMeeting
    let recording: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: meeting.calendarColor)).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).font(Theme.sans(13.5, .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(timeRange)
                    if let platform = meeting.platform { Text("· \(platform.title)") }
                    if !meeting.attendees.isEmpty { Text("· \(meeting.attendees.count + 1) people") }
                }
                .font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !recording, meeting.isNow || hovering {
                Button(meeting.joinURL != nil ? "Join & Record" : "Record") {
                    CalendarService.shared.joinAndRecord(meeting)
                }
                .buttonStyle(PillButtonStyle(prominent: meeting.isNow))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(meeting.attendees.isEmpty ? meeting.title : "With " + meeting.attendees.joined(separator: ", "))
    }

    private var timeRange: String {
        if meeting.isNow { return "Now" }
        let f = { (d: Date) in d.formatted(date: .omitted, time: .shortened).lowercased() }
        return "\(f(meeting.start)) – \(f(meeting.end))"
    }
}

/// "Connect Google Calendar" call to action (with the Mac's calendars as an alternative).
struct ConnectCalendarCard: View {
    @ObservedObject private var google = GoogleCalendar.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect Google Calendar").font(Theme.sans(13.5, .semibold))
            Text("See upcoming meetings, join and take notes in one click, and get notes named after the event.")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    google.connect()
                } label: {
                    HStack(spacing: 6) {
                        if google.isConnecting { ProgressView().controlSize(.mini) }
                        Text(google.isConnecting ? "Waiting for Google…" : "Connect Google Calendar")
                    }
                }
                .buttonStyle(.pill)
                .disabled(!google.isConfigured || google.isConnecting)
                Button("Use Mac Calendar") { CalendarService.shared.requestAccess() }
                    .buttonStyle(.plain).font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
            }
            if !google.isConfigured {
                Text("This build has no Google sign-in configured (Resources/GoogleOAuth.plist).")
                    .font(Theme.sans(11.5)).foregroundStyle(.orange)
            } else if let error = google.lastError {
                Text(error).font(Theme.sans(11.5)).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.accent.opacity(0.5)))
    }
}
