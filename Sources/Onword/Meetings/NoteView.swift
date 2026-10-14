import AppKit
import OnwordCore
import SwiftUI

/// The tabs of a note, in Wispr Flow's order.
enum NoteTab: String, CaseIterable, Identifiable {
    case notes, transcript, summary, tasks, docs
    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: "My thoughts"
        case .transcript: "Transcript"
        case .summary: "Summary"
        case .tasks: "Tasks"
        case .docs: "Docs"
        }
    }
}

/// A note's body, shared by the floating Notepad and the Hub's note page (as in Wispr Flow, where both are
/// one component): the tab bar, the tab panels, and the composer pill with the record toggle and Ask box.
struct NoteBody: View {
    let meetingID: UUID
    @Binding var tab: NoteTab
    /// The Hub's note page: Resume opens the Notepad instead of recording in place.
    var inHub = false
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var summarizer = MeetingSummarizer.shared

    var body: some View {
        if let meeting = store.meeting(meetingID) {
            VStack(spacing: 0) {
                NoteTabBar(meeting: meeting, tab: $tab)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                ZStack(alignment: .bottom) {
                    panel(meeting)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    // Fade the content out behind the composer.
                    LinearGradient(colors: [Theme.page.opacity(0), Theme.page], startPoint: .top, endPoint: .bottom)
                        .frame(height: 150).allowsHitTesting(false)
                    VStack(spacing: 8) {
                        if tab != .summary { GenerationCard(meeting: meeting, floating: true) }
                        if tab != .summary, meeting.summaryDeferred == true, meeting.summary == nil {
                            GenerateSummaryButton(meeting: meeting)
                        }
                        NoteComposer(meeting: meeting, inHub: inHub)
                    }
                    .padding(.bottom, 16)
                }
            }
            .onChange(of: meeting.status) { old, new in
                // When the meeting ends the note switches itself to the Summary.
                if old == .recording, new == .processing { tab = .summary }
            }
        }
    }

    @ViewBuilder private func panel(_ meeting: Meeting) -> some View {
        switch tab {
        case .notes: NotesPanel(meeting: meeting, switchTo: { tab = $0 })
        case .transcript: TranscriptPanel(meeting: meeting)
        case .summary: SummaryPanel(meeting: meeting)
        case .tasks: TasksPanel(meeting: meeting)
        case .docs: DocsPanel(meeting: meeting)
        }
    }
}

// MARK: - Title and pills

/// The note title: EB Garamond 36/45 with −0.04 em tracking and a "New note" placeholder.
struct NoteTitleField: View {
    let meetingID: UUID
    @ObservedObject private var store = MeetingStore.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text("New note").foregroundStyle(NT.neutral500.opacity(0.55)), axis: .vertical)
            .textFieldStyle(.plain)
            .font(Theme.serif(36))
            .tracking(-1.44)
            .lineSpacing(9)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .focused($focused)
            .onAppear {
                text = store.meeting(meetingID)?.title ?? ""
                // Opening a note doesn't select its title (the window would otherwise focus the first field).
                DispatchQueue.main.async { focused = false; NSApp.keyWindow?.makeFirstResponder(nil) }
            }
            .onChange(of: meetingID) { _, id in text = store.meeting(id)?.title ?? "" }
            .onChange(of: store.meeting(meetingID)?.title) { _, title in
                if !focused, let title, title != text { text = title }
            }
            .onChange(of: text) { _, value in
                let clean = value.replacingOccurrences(of: "\n", with: " ")
                if clean != value { text = clean; focused = false; return }
                if store.meeting(meetingID)?.title != clean { store.update(meetingID) { $0.title = clean } }
            }
    }
}

/// Date and attendee pills under the title.
struct NotePills: View {
    let meeting: Meeting
    @State private var showingPeople = false

    private var people: [String] {
        var seen = Set<String>()
        return ((meeting.attendees ?? []) + (meeting.participants ?? [])).filter { seen.insert($0.lowercased()).inserted }
    }

    var body: some View {
        HStack(spacing: 8) {
            pill { Text(NT.datePill(meeting.startedAt)) }
            FolderChip(meeting: meeting)
            if !people.isEmpty {
                Button { showingPeople.toggle() } label: {
                    pill {
                        HStack(spacing: -4) {
                            ForEach(people.prefix(5), id: \.self) { name in
                                Monogram(name: name, size: 20).clipShape(Circle())
                                    .overlay(Circle().strokeBorder(Theme.page, lineWidth: 1.5))
                            }
                        }
                        if people.count > 5 { Text("+\(people.count - 5)") }
                    }
                }
                .buttonStyle(.plainPointer)
                .popover(isPresented: $showingPeople, arrowEdge: .bottom) { AttendeeList(names: people).frame(minWidth: 280) }
            }
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .font(Theme.sans(12)).foregroundStyle(NT.pillInk)
            .padding(.horizontal, 8).frame(height: 26)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
    }
}

/// "ATTENDEES" with the first five, then "+N more" / "Show less".
struct AttendeeList: View {
    let names: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Overline(text: "Attendees", color: Theme.inkTertiary)
            ForEach(expanded ? names : Array(names.prefix(5)), id: \.self) { name in
                HStack(spacing: 8) {
                    Monogram(name: name, size: 24).clipShape(Circle())
                    Text(name).font(Theme.sans(15)).lineLimit(1)
                }
            }
            if names.count > 5 {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "Show less" : "+\(names.count - 5) more")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .font(Theme.sans(15)).foregroundStyle(Theme.inkTertiary)
                }
                .buttonStyle(.plainPointer)
            }
        }
        .padding(16)
    }
}

// MARK: - Tab bar

/// 44-pt tabs, 15/600, with a 2-pt underline under the selected label and a hairline across.
struct NoteTabBar: View {
    let meeting: Meeting
    @Binding var tab: NoteTab
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var summarizer = MeetingSummarizer.shared
    @Namespace private var underline

    private var tabs: [NoteTab] {
        NoteTab.allCases.filter {
            switch $0 {
            case .tasks: meeting.summary != nil || !(meeting.todos ?? []).isEmpty
            case .docs: !(meeting.docs ?? []).isEmpty
            default: true
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { item in TabItem(item: item, meeting: meeting, selected: tab == item, namespace: underline) { tab = item } }
            Spacer()
        }
        .padding(.horizontal, -12)
        .background(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1).padding(.horizontal, -400) }
        .animation(.spring(response: 0.15, dampingFraction: 0.9), value: tab)
    }
}

private struct TabItem: View {
    let item: NoteTab
    let meeting: Meeting
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var summarizer = MeetingSummarizer.shared
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if item == .transcript, recorder.currentID == meeting.id {
                    LiveWaveform(level: max(recorder.micLevel, recorder.systemLevel), bars: 3, height: 16, barWidth: 2.5, color: NT.green500)
                        .frame(width: 14, height: 16)
                        .transition(.opacity.combined(with: .scale(scale: 0.5)))
                }
                if item == .summary {
                    SparkleIcon(spinning: summarizer.working.contains(meeting.id))
                }
                Text(item.title)
                if let badge { Text(badge).fontWeight(.regular).foregroundStyle(Color(hex: 0x9D9C98)) }
            }
            .font(Theme.sans(15, .semibold))
            .foregroundStyle(selected ? Theme.ink : hovering ? NT.neutral600 : NT.neutral500)
            .padding(12)
            .overlay(alignment: .bottom) {
                if selected {
                    Rectangle().fill(Theme.ink).frame(height: 2).padding(.horizontal, 12)
                        .matchedGeometryEffect(id: "underline", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var badge: String? {
        switch item {
        case .tasks:
            let todos = meeting.activeTodos
            return todos.isEmpty ? nil : "(\(todos.filter(\.done).count)/\(todos.count))"
        case .docs:
            return "(\(meeting.docs?.count ?? 0))"
        default: return nil
        }
    }
}

/// The Summary tab's sparkle; it spins while the summary is being written.
private struct SparkleIcon: View {
    let spinning: Bool
    @State private var angle: Double = 0

    var body: some View {
        Image(systemName: "sparkle").font(.system(size: 10, weight: .semibold))
            .rotationEffect(.degrees(angle))
            .onAppear { spin() }
            .onChange(of: spinning) { _, _ in spin() }
    }

    private func spin() {
        if spinning {
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { angle = 360 }
        } else {
            withAnimation(.easeOut(duration: 0.15)) { angle = 0 }
        }
    }
}

// MARK: - My thoughts

private struct NotesPanel: View {
    let meeting: Meeting
    let switchTo: (NoteTab) -> Void
    @ObservedObject private var store = MeetingStore.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            PlainTextEditor(
                text: Binding(get: { store.meeting(meeting.id)?.notes ?? "" },
                              set: { value in store.update(meeting.id) { $0.notes = value } }),
                font: NoteFonts.editor, documentID: meeting.id, lineHeight: 28,
                textColor: .labelColor, caretColor: Theme.caret, inset: NSSize(width: 7, height: 12),
                bottomOverscroll: 140, autoFocus: false)
            if meeting.notes.isEmpty {
                Group {
                    if meeting.summary != nil {
                        HStack(spacing: 4) {
                            Text("Your summary is ready.")
                            Button { switchTo(.summary) } label: { Text("Check it out →").underline() }
                                .buttonStyle(.plainPointer)
                        }
                    } else {
                        Text("Write your notes here. We'll make a separate summary at the end.")
                            .allowsHitTesting(false)
                    }
                }
                .font(Theme.sans(15)).foregroundStyle(NT.placeholder)
                .padding(.leading, 12).padding(.top, 16)
            }
        }
        .padding(.top, 12)
    }
}

enum NoteFonts {
    /// Figtree at weight 550, the notes editor's "emphasis" weight.
    static let editor: NSFont = {
        let descriptor = NSFontDescriptor(fontAttributes: [.name: "Figtree", .variation: [2_003_265_652: 550]])
        return NSFont(descriptor: descriptor, size: 15) ?? .systemFont(ofSize: 15, weight: .medium)
    }()
}

// MARK: - Transcript

private struct TranscriptPanel: View {
    let meeting: Meeting
    @ObservedObject private var recorder = MeetingRecorder.shared
    @State private var searching = false
    @State private var query = ""
    @State private var copied = false
    @State private var renaming: String?
    @AppStorage("notetakerTranscriptTipDismissed") private var tipDismissed = false

    private var live: Bool { recorder.currentID == meeting.id }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 0) {
                        MultitoolBar(icon: "clock", label: label) {
                            if searching {
                                HStack(spacing: 4) {
                                    TextField("Search transcript…", text: $query).textFieldStyle(.plain).font(Theme.sans(13))
                                        .frame(width: 140)
                                    if !query.isEmpty {
                                        Text("\(matches)").font(Theme.sans(12).monospacedDigit()).foregroundStyle(Theme.inkTertiary)
                                    }
                                    BarAction(icon: "xmark", help: "Close search") { searching = false; query = "" }
                                }
                            } else {
                                BarAction(icon: "magnifyingglass", help: "Search transcript") { searching = true }
                            }
                            BarAction(icon: copied ? "checkmark" : "doc.on.doc", help: copied ? "Copied transcript" : "Copy transcript") {
                                copyTranscript()
                            }
                            if !live, !meeting.speakers.isEmpty {
                                PopMenuButton(items: meeting.speakers.map { speaker in
                                    PopMenuItem(title: meeting.name(for: speaker), icon: "person") { renaming = speaker }
                                }) {
                                    Image(systemName: "person.badge.plus").font(.system(size: 13))
                                        .frame(width: 28, height: 28).foregroundStyle(Theme.iconFaint)
                                }
                                .help("Assign speaker names")
                            }
                        }
                        if live, !tipDismissed {
                            HStack {
                                Text("After the meeting, Onword will improve the transcript & label speakers")
                                Spacer()
                                Button { tipDismissed = true } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                                    .buttonStyle(.plainPointer)
                            }
                            .font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
                            .padding(.init(top: 6, leading: 12, bottom: 6, trailing: 8))
                            .background(UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8).fill(Theme.buttonFill))
                        }
                    }
                    .padding(.init(top: 24, leading: 12, bottom: 14, trailing: 20))

                    if lines.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                            TranscriptGroup(name: group.name, color: group.color, texts: group.texts, interim: group.interim, query: query) {
                                if !live, group.speaker != "Them", group.speaker != "You" { renaming = group.speaker }
                            }
                            .padding(.leading, 16).padding(.top, 16)
                        }
                        Color.clear.frame(height: 160).id("bottom")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: recorder.liveSegments.count) { _, _ in
                if live { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
        .sheet(item: Binding(get: { renaming.map(SpeakerKey.init) }, set: { renaming = $0?.value })) { key in
            RenameSpeakerSheet(meeting: meeting, speaker: key.value) { renaming = nil }
        }
    }

    private var label: String {
        if live { return TimeFormat.clock(recorder.elapsed) }
        let range = meeting.duration > 0
            ? "\(meeting.startedAt.formatted(date: .omitted, time: .shortened)) – \(meeting.startedAt.addingTimeInterval(meeting.duration).formatted(date: .omitted, time: .shortened))"
            : meeting.startedAt.formatted(date: .omitted, time: .shortened)
        let count = meeting.speakers.count
        return count > 0 ? "\(count) speaker\(count == 1 ? "" : "s") • \(range)" : range
    }

    private struct Line { let speaker: String; let text: String; let interim: Bool }

    private var lines: [Line] {
        var result = meeting.segments.map { Line(speaker: $0.speaker, text: $0.text, interim: false) }
        if live {
            result += recorder.liveSegments.map { Line(speaker: $0.speaker == "me" ? "You" : "Them", text: $0.text, interim: false) }
        }
        return result
    }

    private var groups: [(speaker: String, name: String, color: Color, texts: [String], interim: Bool)] {
        let order = meeting.speakers.filter { $0 != "me" }
        var result: [(String, String, Color, [String], Bool)] = []
        for line in lines {
            if let last = result.last, last.0 == line.speaker {
                result[result.count - 1].3.append(line.text)
                continue
            }
            let name: String, color: Color
            switch line.speaker {
            case "You", "Them": name = line.speaker; color = Theme.ink
            case "me": name = meeting.name(for: "me"); color = Theme.ink
            default:
                name = meeting.name(for: line.speaker)
                let index = order.firstIndex(of: line.speaker) ?? 0
                color = Color(hex: NT.speakerPalette[index % NT.speakerPalette.count])
            }
            result.append((line.speaker, name, color, [line.text], line.interim))
        }
        return result.map { (speaker: $0.0, name: $0.1, color: $0.2, texts: $0.3, interim: $0.4) }
    }

    private var matches: Int {
        guard !query.isEmpty else { return 0 }
        return lines.reduce(0) { $0 + $1.text.lowercased().components(separatedBy: query.lowercased()).count - 1 }
    }

    @ViewBuilder private var emptyState: some View {
        if live {
            VStack(spacing: 4) {
                Text("Welcome to Notetaker!").font(Theme.sans(12, .medium)).foregroundStyle(Theme.inkTertiary)
                Text("Try saying “Hi Notetaker”").font(Theme.sans(18, .semibold)).foregroundStyle(Theme.inkTertiary)
            }
            .frame(maxWidth: .infinity).padding(.top, 60)
        } else if meeting.status == .processing {
            Text("The transcript appears when processing finishes.")
                .font(Theme.sans(15)).foregroundStyle(Theme.inkTertiary).frame(maxWidth: .infinity).padding(.top, 60)
        } else {
            Text(meeting.status == .draft ? "Start Notetaker to transcribe this meeting." : (meeting.statusDetail ?? "No speech was detected."))
                .font(Theme.sans(15)).foregroundStyle(Theme.inkTertiary).frame(maxWidth: .infinity).padding(.top, 60)
        }
    }

    private func copyTranscript() {
        let text = lines.map { line -> String in
            let name: String = line.speaker == "You" || line.speaker == "Them" ? line.speaker : meeting.name(for: line.speaker)
            return name + ": " + line.text
        }
        .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

private struct SpeakerKey: Identifiable {
    let value: String
    var id: String { value }
}

/// One speaker's turn: the name, then chat-style bubbles.
private struct TranscriptGroup: View {
    let name: String
    let color: Color
    let texts: [String]
    let interim: Bool
    let query: String
    let rename: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: rename) {
                Text(name).font(Theme.sans(15, .medium)).foregroundStyle(color)
            }
            .buttonStyle(.plainPointer)
            .padding(.bottom, 4)
            ForEach(Array(texts.enumerated()), id: \.offset) { index, text in
                highlighted(text)
                    .font(Theme.sans(15, .medium)).lineSpacing(3)
                    .foregroundStyle(interim ? NT.neutral500 : Theme.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(bubble(index).fill(Theme.frame))
                    .opacity(interim ? 0.5 : 1)
                    .padding(.trailing, 24)
            }
        }
    }

    private func bubble(_ index: Int) -> UnevenRoundedRectangle {
        let first = index == 0
        let last = index == texts.count - 1
        let top: CGFloat = first ? 12 : 4
        let bottom: CGFloat = last ? 12 : 4
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                      bottomTrailingRadius: 12, topTrailingRadius: 12)
    }

    private func highlighted(_ text: String) -> Text {
        guard !query.isEmpty else { return Text(text) }
        var attributed = AttributedString(text)
        var searchStart = attributed.startIndex
        while let range = attributed[searchStart...].range(of: query, options: .caseInsensitive) {
            attributed[range].backgroundColor = Color(hex: 0xFEF08A)
            attributed[range].foregroundColor = Color(hex: 0x1A1A1A)
            searchStart = range.upperBound
        }
        return Text(attributed)
    }
}

/// "Assign speakers": name a voice; a name another speaker has merges them.
private struct RenameSpeakerSheet: View {
    let meeting: Meeting
    let speaker: String
    let done: () -> Void
    @State private var name = ""

    private var suggestions: [String] {
        let used = Set(meeting.speakers.filter { $0 != speaker }.map { meeting.name(for: $0).lowercased() })
        var seen = Set<String>()
        return ((meeting.attendees ?? []) + (meeting.participants ?? []))
            .filter { !used.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Who is “\(meeting.name(for: speaker))”?").font(Theme.serif(24))
            Text("Name this voice and the whole transcript is relabelled.").font(Theme.sans(13)).foregroundStyle(Theme.inkTertiary)
            TextField("Name", text: $name).textFieldStyle(.plain).font(Theme.sans(15))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                .onSubmit(save)
            if !suggestions.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(suggestions, id: \.self) { s in
                        Button(s) { name = s }.buttonStyle(PillButtonStyle(prominent: name == s)).controlSize(.small)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).buttonStyle(.pillQuiet).keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(.pill).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(Theme.panel)
        .onAppear { name = meeting.name(for: speaker) }
    }

    private func save() {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        MeetingStore.shared.update(meeting.id) { m in
            if let existing = m.speakers.first(where: { $0 != speaker && m.name(for: $0).caseInsensitiveCompare(clean) == .orderedSame }) {
                m.segments = TranscriptMerger.reassign(m.segments, from: speaker, to: existing)
                m.speakerNames[speaker] = nil
            } else {
                m.speakerNames[speaker] = clean
            }
        }
        done()
    }
}

// MARK: - Summary

private struct SummaryPanel: View {
    let meeting: Meeting
    @ObservedObject private var summarizer = MeetingSummarizer.shared
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MultitoolBar(icon: "lightbulb", label: label) {
                    if meeting.summary != nil {
                        BarAction(icon: copied ? "checkmark" : "doc.on.doc", help: "Copy summary") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(summaryMarkdown, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 14)

                GenerationCard(meeting: meeting, floating: false).padding(.horizontal, 12).padding(.bottom, 12)

                if meeting.summary != nil {
                    summaryBody.padding(.horizontal, 12).transition(.opacity)
                } else if meeting.status == .recording || meeting.status == .draft {
                    VStack(spacing: 4) {
                        Text("Summaries appear when a meeting ends").font(Theme.sans(12, .medium)).foregroundStyle(Theme.inkTertiary)
                        Text("No summary yet").font(Theme.sans(18, .semibold)).foregroundStyle(Theme.inkTertiary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 32)
                } else if meeting.summaryDeferred == true || (meeting.status == .ready && !summarizer.working.contains(meeting.id)) {
                    VStack(spacing: 12) {
                        if let error = meeting.summaryError ?? (meeting.segments.isEmpty ? nil : summarizer.unavailableReason) {
                            Text(error).font(Theme.sans(15)).foregroundStyle(Theme.inkTertiary).multilineTextAlignment(.center)
                        }
                        if !meeting.segments.isEmpty, summarizer.unavailableReason == nil { GenerateSummaryButton(meeting: meeting) }
                    }
                    .frame(maxWidth: .infinity).padding(.top, 32)
                }
                Color.clear.frame(height: 160)
            }
            .padding(.top, 24)
        }
        .scrollIndicators(.hidden)
        .animation(.easeOut(duration: 0.4), value: meeting.summary)
    }

    private var label: String {
        if let summary = meeting.summary {
            let words = summary.split(separator: " ").count + (meeting.decisions ?? []).joined(separator: " ").split(separator: " ").count
            return "\(max(1, Int((Double(words) / 200).rounded(.up)))) min read"
        }
        if meeting.summaryDeferred == true { return "Not auto-generated" }
        if meeting.status == .ready && meeting.segments.isEmpty { return "No transcript or audio available for a summary" }
        return "Summary"
    }

    private var summaryBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary = meeting.summary {
                Text("Overview").font(Theme.sans(15, .bold)).frame(height: 28)
                Text(summary).font(Theme.sans(15, .medium)).lineSpacing(8).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let decisions = meeting.decisions, !decisions.isEmpty {
                Text("Decisions").font(Theme.sans(15, .bold)).frame(height: 28).padding(.top, 14)
                ForEach(decisions, id: \.self) { bullet($0) }
            }
            let todos = meeting.activeTodos
            if !todos.isEmpty {
                Text("Next steps").font(Theme.sans(15, .bold)).frame(height: 28).padding(.top, 14)
                ForEach(todos) { todo in
                    bullet(todo.task + (todo.owner.map { " — \($0)" } ?? ""))
                }
            }
            Text("Written on this Mac by Apple Intelligence. Check it against the transcript.")
                .font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary).padding(.top, 20)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(Theme.ink).frame(width: 5, height: 5).offset(y: -3)
            Text(text).font(Theme.sans(15, .medium)).lineSpacing(8).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private var summaryMarkdown: String {
        var md = "## Overview\n\n\(meeting.summary ?? "")\n"
        if let decisions = meeting.decisions, !decisions.isEmpty { md += "\n## Decisions\n\n" + decisions.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !meeting.activeTodos.isEmpty { md += "\n## Next steps\n\n" + meeting.activeTodos.map(\.markdown).joined(separator: "\n") + "\n" }
        return md
    }
}

/// "Generate summary": a black rounded button with a sparkle (short meetings aren't summarized automatically).
struct GenerateSummaryButton: View {
    let meeting: Meeting
    @ObservedObject private var summarizer = MeetingSummarizer.shared

    var body: some View {
        let working = summarizer.working.contains(meeting.id)
        Button {
            MeetingStore.shared.update(meeting.id) { $0.summaryDeferred = nil }
            summarizer.summarize(meeting.id)
        } label: {
            HStack(spacing: 8) {
                if working { ProgressView().controlSize(.mini).tint(Theme.onPrimary) } else {
                    Image(systemName: "sparkle").font(.system(size: 13, weight: .semibold))
                }
                Text(working ? "Generating summary…" : meeting.summary == nil ? "Generate summary" : "Update Summary")
            }
            .font(Theme.sans(15, .medium)).foregroundStyle(Theme.onPrimary)
            .padding(.horizontal, 24).frame(height: 40)
            .background(Capsule().fill(Theme.primary))
        }
        .buttonStyle(.plainPointer)
        .disabled(working)
    }
}

/// The three-step card while a meeting is processed: rotating titles, "step N of 3", then "Your notes are ready".
struct GenerationCard: View {
    let meeting: Meeting
    let floating: Bool
    @ObservedObject private var summarizer = MeetingSummarizer.shared
    @State private var doneUntil: Date?

    private var stage: Int? {
        if summarizer.working.contains(meeting.id) { return 3 }
        guard meeting.status == .processing else { return nil }
        let detail = meeting.statusDetail ?? ""
        return detail.contains("Identifying") ? 2 : 1
    }

    var body: some View {
        Group {
            if let stage {
                card(stage: stage)
            } else if meeting.status == .failed {
                errorCard
            } else if let doneUntil, doneUntil > Date() {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Color(hex: 0x065F46))
                    Text("Your notes are ready").font(Theme.sans(15, .medium)).foregroundStyle(Color(hex: 0x1A1A1A))
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xECFDF5)))
            }
        }
        .padding(.horizontal, floating ? 12 : 0)
        .onChange(of: meeting.summary) { old, new in
            if old == nil, new != nil {
                doneUntil = Date().addingTimeInterval(3)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { doneUntil = nil }
            }
        }
        .animation(.easeOut(duration: 0.3), value: stage)
    }

    private func card(stage: Int) -> some View {
        HStack(spacing: 12) {
            SpinningStar(stage: stage)
            RollingText(phrases: titles(stage), interval: 4, font: Theme.sans(15, .medium), color: Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 20)
            Text("step \(stage) of 3").font(Theme.sans(15).monospacedDigit()).foregroundStyle(Theme.inkTertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.frame))
    }

    private var errorCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 14)).foregroundStyle(Color(hex: 0xC2410C))
            Text("We hit a snag processing your meeting").font(Theme.sans(15, .medium)).foregroundStyle(Color(hex: 0x1A1A1A))
            Spacer()
            Button("Retry") { MeetingRecorder.shared.process(meeting.id) }
                .buttonStyle(.plainPointer).font(Theme.sans(15, .medium)).foregroundStyle(Color(hex: 0xC2410C))
                .padding(.horizontal, 6).frame(height: 28)
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xFFF7ED)))
    }

    private func titles(_ stage: Int) -> [String] {
        let minutes = max(1, Int((meeting.duration / 60).rounded()))
        switch stage {
        case 1: return ["Turning your \(minutes)-minute meeting into a two-minute read", "So you never replay this meeting again",
                        "Catching every word, so nothing slips"]
        case 2: return ["Getting every word \(max(2, meeting.speakers.count)) speakers said", "Noting who said what",
                        "You can stop trying to hold it all in your head"]
        default:
            let words = meeting.wordCount
            return ["Finding the action items and decisions", "\(words) words down, none of them typed by you",
                    "Pulling out what you'll actually act on"]
        }
    }
}

private struct SpinningStar: View {
    let stage: Int
    @State private var angle: Double = 0

    var body: some View {
        Text(stage == 1 ? "✶" : stage == 2 ? "✸" : "✺")
            .font(.system(size: stage == 3 ? 20 : 16)).foregroundStyle(Theme.ink)
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: stage == 3 ? 3 : 1.5).repeatForever(autoreverses: false)) { angle = 360 }
            }
    }
}

// MARK: - Tasks

private struct TasksPanel: View {
    let meeting: Meeting
    @State private var adding = false
    @State private var newTask = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2) {
                    Spacer()
                    toolbarButton("checkmark.circle", "Mark all as completed") {
                        MeetingStore.shared.update(meeting.id) { m in m.todos = m.todos?.map { var t = $0; t.done = true; return t } }
                    }
                    toolbarButton("archivebox", "Archive all") {
                        MeetingStore.shared.update(meeting.id) { m in m.todos = m.todos?.map { var t = $0; t.archived = true; return t } }
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 4)
                if meeting.activeTodos.isEmpty {
                    Text("No remaining action items for this meeting").font(Theme.sans(15)).foregroundStyle(NT.neutral500)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                }
                VStack(spacing: 2) {
                    ForEach(meeting.activeTodos) { todo in TaskRow(meetingID: meeting.id, todo: todo) }
                }
                if adding {
                    TextField("Action item", text: $newTask).textFieldStyle(.plain).font(Theme.sans(15))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .onSubmit {
                            let task = newTask.trimmingCharacters(in: .whitespaces)
                            if !task.isEmpty {
                                MeetingStore.shared.update(meeting.id) { $0.todos = ($0.todos ?? []) + [MeetingTodo(task: task)] }
                            }
                            newTask = ""
                            adding = false
                        }
                } else {
                    Button { adding = true } label: {
                        Label("Add action item", systemImage: "plus").font(Theme.sans(15)).foregroundStyle(NT.neutral500)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    .buttonStyle(.plainPointer)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.frame))
            .padding(.horizontal, 12).padding(.vertical, 24)
            Color.clear.frame(height: 140)
        }
        .scrollIndicators(.hidden)
    }

    private func toolbarButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(NT.neutral500).frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .help(help)
    }
}

private struct TaskRow: View {
    let meetingID: UUID
    let todo: MeetingTodo
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                MeetingStore.shared.update(meetingID) { m in
                    if let i = m.todos?.firstIndex(where: { $0.id == todo.id }) { m.todos?[i].done.toggle() }
                }
            } label: {
                RoundedRectangle(cornerRadius: 4)
                    .fill(todo.done ? NT.checkFill : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(todo.done ? NT.checkFill : Theme.buttonFill, lineWidth: 1.5))
                    .overlay { if todo.done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) } }
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plainPointer)
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.task).font(Theme.sans(15)).strikethrough(todo.done)
                    .foregroundStyle(todo.done ? NT.neutral500 : Theme.ink)
                let details = [todo.owner, todo.due.map { "due \($0)" }].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
                }
            }
            Spacer()
            if hovering {
                Button {
                    MeetingStore.shared.update(meetingID) { m in
                        if let i = m.todos?.firstIndex(where: { $0.id == todo.id }) { m.todos?[i].archived = true }
                    }
                } label: { Image(systemName: "archivebox").font(.system(size: 12)).foregroundStyle(NT.neutral500) }
                .buttonStyle(.plainPointer).help("Archive")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? NT.sand200 : .clear))
        .onHover { hovering = $0 }
    }
}

// MARK: - Docs

private struct DocsPanel: View {
    let meeting: Meeting

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(meeting.docs ?? []) { doc in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(doc.title).font(Theme.sans(15, .semibold))
                            Spacer()
                            BarAction(icon: "doc.on.doc", help: "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(doc.body, forType: .string)
                            }
                            BarAction(icon: "trash", help: "Delete") {
                                MeetingStore.shared.update(meeting.id) { $0.docs?.removeAll { $0.id == doc.id } }
                            }
                        }
                        Text(doc.body).font(Theme.sans(15)).lineSpacing(5).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.frame))
                }
                Color.clear.frame(height: 140)
            }
            .padding(.horizontal, 12).padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Composer

/// The pill at the bottom: the record toggle and the Ask box, quick-prompt chips, and the chat drawer.
struct NoteComposer: View {
    let meeting: Meeting
    var inHub = false
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var chat = MeetingChat.shared
    @State private var question = ""
    @State private var drawerOpen = false
    @FocusState private var askFocused: Bool

    private var live: Bool { recorder.currentID == meeting.id }
    private var messages: [ChatMessage] { meeting.chat ?? [] }
    private var showChips: Bool { askFocused && question.isEmpty && messages.isEmpty }
    private var elevated: Bool { drawerOpen || showChips }

    var body: some View {
        VStack(spacing: 0) {
            if live && !elevated {
                Text("Always get consent when transcribing others.")
                    .font(Theme.sans(12)).foregroundStyle(NT.neutral500)
                    .padding(.top, 6).padding(.bottom, 8)
                    .transition(.opacity)
            }
            VStack(spacing: 0) {
                if drawerOpen { ChatDrawer(meeting: meeting) { drawerOpen = false } }
                if showChips { chips }
                HStack(alignment: .bottom, spacing: 8) {
                    RecordPill(meeting: meeting, collapsed: elevated, inHub: inHub)
                    askBox
                }
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 32).fill(Theme.page))
            .clipShape(RoundedRectangle(cornerRadius: 32))
            .overlay(RoundedRectangle(cornerRadius: 32).strokeBorder(elevated ? Theme.border : .clear))
            .shadow(color: .black.opacity(elevated ? 0.1 : 0), radius: 8, y: 4)
        }
        .padding(.horizontal, 12)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: elevated)
        .onChange(of: askFocused) { _, focused in if focused && !messages.isEmpty { drawerOpen = true } }
    }

    private var askBox: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("", text: $question, prompt: Text("Ask anything").foregroundStyle(NT.neutral500.opacity(0.5)), axis: .vertical)
                .textFieldStyle(.plain).font(Theme.sans(15)).lineLimit(1...3)
                .focused($askFocused)
                .padding(.vertical, 13)
                .onSubmit { send(question) }
            if chat.answering.contains(meeting.id) {
                Button { chat.stop(meeting.id) } label: {
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 10, height: 10)
                        .frame(width: 24, height: 24).background(Circle().fill(Color(hex: 0xA39D8E)))
                }
                .buttonStyle(.plainPointer).padding(.bottom, 12)
            } else if question.isEmpty {
                let chip = live ? "What did I miss?" : "Write a follow-up email"
                Button { send(chip) } label: {
                    Text(chip).font(Theme.sans(12, .medium)).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Capsule().fill(Theme.frame))
                        .overlay(Capsule().strokeBorder(Theme.buttonFill))
                }
                .buttonStyle(.plainPointer).padding(.vertical, 9)
            } else {
                Button { send(question) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.onPrimary)
                        .frame(width: 26, height: 26).background(Circle().fill(Theme.primary))
                }
                .buttonStyle(.plainPointer).padding(.bottom, 11)
            }
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 25).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(askFocused ? NT.neutral500 : Theme.border))
        .shadow(color: askFocused ? Theme.mutedCard : .clear, radius: 0, x: 0, y: 0)
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(live ? MeetingChat.livePrompts : MeetingChat.afterPrompts, id: \.self) { prompt in
                    Button { send(prompt) } label: {
                        Text(prompt).font(Theme.sans(12, .medium)).foregroundStyle(Theme.inkTertiary)
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(Capsule().fill(Theme.shortcutPill))
                            .overlay(Capsule().strokeBorder(Theme.buttonFill))
                    }
                    .buttonStyle(.plainPointer)
                }
            }
            .padding(.init(top: 12, leading: 10, bottom: 6, trailing: 10))
        }
        .scrollIndicators(.hidden)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        drawerOpen = true
        chat.ask(text, about: meeting.id)
    }
}

/// Start / Stop / Resume / "Finishing up…": a 48-pt round pill that shows its label unless the drawer is open.
private struct RecordPill: View {
    let meeting: Meeting
    let collapsed: Bool
    let inHub: Bool
    @ObservedObject private var recorder = MeetingRecorder.shared
    @State private var hovering = false

    private enum Phase { case start, stop, resume, finishing }

    private var phase: Phase {
        if recorder.currentID == meeting.id { return .stop }
        switch meeting.status {
        case .draft: return .start
        case .processing: return .finishing
        case .recording: return .finishing
        case .ready, .failed: return .resume
        }
    }

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                icon
                if !collapsed {
                    Text(label).font(Theme.sans(15, .semibold)).lineLimit(1).fixedSize()
                        .transition(.opacity)
                }
            }
            .foregroundStyle(Theme.inkSecondary)
            .padding(15)
            .frame(minWidth: 48, minHeight: 48)
            .background(Capsule().fill(hovering && phase != .finishing ? NT.recordingFill : Theme.panel))
            .overlay(Capsule().strokeBorder(hovering && phase != .finishing ? NT.recordingStroke : Theme.border))
        }
        .buttonStyle(.plainPointer)
        .disabled(phase == .finishing || (phase == .start && recorder.isRecording))
        .onHover { hovering = $0 }
        .animation(.linear(duration: 0.1), value: collapsed)
        .help(phase == .stop ? "Stop listening" : phase == .resume ? "Take notes" : "")
    }

    @ViewBuilder private var icon: some View {
        switch phase {
        case .start, .resume: RecordDot(size: 16, color: NT.recordingStroke)
        case .stop: RoundedRectangle(cornerRadius: 2).fill(NT.recordingStroke).frame(width: 13, height: 13).frame(width: 16, height: 16)
        case .finishing: ProgressView().controlSize(.small).frame(width: 16, height: 16)
        }
    }

    private var label: String {
        switch phase {
        case .start: "Start"
        case .stop: "Stop"
        case .resume: "Resume"
        case .finishing: "Finishing up…"
        }
    }

    private func act() {
        switch phase {
        case .stop: recorder.stop()
        case .start: NotetakerFlow.shared.beginRecording(event: nil, into: meeting.id)
        case .resume:
            if inHub { NotepadWindow.shared.show(meeting.id, focus: true) }
            NotetakerFlow.shared.resume(meeting.id)
        case .finishing: break
        }
    }
}

/// The chat inside the pill: a drag handle, "New chat" / minimise, and the conversation.
private struct ChatDrawer: View {
    let meeting: Meeting
    let minimize: () -> Void
    @ObservedObject private var chat = MeetingChat.shared
    @State private var height: CGFloat = 280

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule().fill(Theme.buttonFill).frame(width: 40, height: 4).frame(height: 14)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { value in height = max(120, min(560, height - value.translation.height)) })
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                HStack {
                    Text("Chat").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.inkTertiary)
                    Spacer()
                    BarAction(icon: "square.and.pencil", help: "New chat") { chat.clear(meeting.id) }
                    BarAction(icon: "minus", help: "Minimize", action: minimize)
                }
                .frame(minHeight: 32)
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if (meeting.chat ?? []).isEmpty {
                            Text("Ask anything about this meeting").font(Theme.sans(15)).foregroundStyle(NT.neutral500)
                                .frame(maxWidth: .infinity).padding(.top, 30)
                        }
                        ForEach(meeting.chat ?? []) { message in ChatBubble(message: message).id(message.id) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.init(top: 12, leading: 16, bottom: 12, trailing: 8))
                }
                .onChange(of: meeting.chat?.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .frame(height: height)
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.text).font(Theme.sans(15)).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.frame))
            }
        } else if message.text.isEmpty {
            ProgressView().controlSize(.small)
        } else {
            Text((try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                 ?? AttributedString(message.text))
                .font(Theme.sans(15)).lineSpacing(4).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - More actions

/// The ⋯ menu: Copy as Markdown, Audio settings (while recording), Delete.
struct NoteMoreMenu: View {
    let meeting: Meeting
    var onDelete: () -> Void = {}
    @State private var confirmDelete = false

    var body: some View {
        PopMenuButton(items: items) {
            Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .help("More actions")
        .alert("Delete meeting?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDelete()
                MeetingStore.shared.delete(meeting.id)
            }
        } message: {
            Text("This will permanently delete the note and transcript. This action cannot be undone")
        }
    }

    private var items: [PopMenuItem] {
        var items: [PopMenuItem] = [
            .init(title: "Copy as Markdown", icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(meeting.markdown, forType: .string)
            },
        ]
        if MeetingRecorder.shared.currentID == meeting.id {
            items.append(.init(title: "Audio settings", icon: "slider.horizontal.3") {
                WindowManager.shared.show()
                HubRouter.shared.settingsTab = .general
            })
        }
        if meeting.status != .recording {
            items.append(.init(title: "Show recording", icon: "waveform") {
                let recording = MeetingAudio.recordingURL(meeting)
                NSWorkspace.shared.activateFileViewerSelecting(
                    [FileManager.default.fileExists(atPath: recording.path) ? recording : meeting.folder])
            })
            items.append(.init(title: "Delete", icon: "trash", destructive: true) { confirmDelete = true })
        }
        return items
    }
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
