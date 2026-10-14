import AppKit
import OnwordCore
import SwiftUI

/// Contents of the floating Scratchpad window: a top bar with tabs, a 48 pt rail that opens the notes
/// list, and the note on a rounded card. Sizes and colours follow Wispr Flow's Scratchpad.
struct ScratchpadWindowView: View {
    @ObservedObject private var window = ScratchpadWindow.shared
    @ObservedObject private var store = NotesStore.shared

    static let rail: CGFloat = 48

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                TopBar(window: window, store: store)
                HStack(spacing: 0) {
                    NotesSidebar(window: window, store: store,
                                 width: window.sidebarOpen ? Self.rail + min(max(proxy.size.width * 0.25, 120), 200) : Self.rail)
                    EditorCard(window: window, store: store)
                        .padding(.trailing, 8).padding(.bottom, 8)
                }
            }
        }
        .background(Theme.frame)
        .overlay { if let id = window.confirmingDelete { DeleteConfirmation(id: id, window: window) } }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .font(Theme.sans(12, .medium))
        .foregroundStyle(Theme.ink)
        .ignoresSafeArea()
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @ObservedObject var window: ScratchpadWindow
    @ObservedObject var store: NotesStore

    var body: some View {
        HStack(spacing: 8) {
            LogoMark(size: 16).frame(width: ScratchpadWindowView.rail)
            TabStrip {
                ForEach(window.tabs.ids, id: \.self) { id in
                    TabItem(id: id, window: window, store: store, showsUnderline: window.tabs.ids.count > 1)
                }
            }
            .layoutPriority(1)
            ToolbarButton(systemImage: "plus", help: "New tab (⌘T)") { window.newTab() }
                .disabled(window.tabs.isFull)
            if let toast = window.toast {
                Label(toast, systemImage: "checkmark")
                    .labelStyle(ToastLabelStyle())
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(2)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            ToolbarButton(systemImage: window.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          help: window.isExpanded ? "Compact window" : "Expand window") { window.toggleExpanded() }
            ToolbarButton(systemImage: "xmark", help: "Close") { window.closeAll() }
        }
        .padding(.vertical, 8)
        .padding(.trailing, 12)
        .frame(height: 44)
        .background(WindowDragArea())
    }
}

private struct ToastLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11, weight: .semibold))
            configuration.title
        }
        .font(Theme.sans(12, .medium))
        .foregroundStyle(Theme.scratchpadHoverInk)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.scratchpadActive))
    }
}

private struct TabItem: View {
    let id: UUID
    @ObservedObject var window: ScratchpadWindow
    @ObservedObject var store: NotesStore
    let showsUnderline: Bool
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var isActive: Bool { window.tabs.activeID == id }

    var body: some View {
        HStack(spacing: 5) {
            if window.renamingID == id {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.sans(12, .semibold))
                    .frame(width: 110)
                    .focused($fieldFocused)
                    .onSubmit { window.rename(id, to: draft) }
                    .onExitCommand { window.renamingID = nil; window.focusEditor() }
                    .onChange(of: draft) { _, value in if value.count > 100 { draft = String(value.prefix(100)) } }
                    .onAppear {
                        draft = store.note(id).map(Self.title) ?? ""
                        DispatchQueue.main.async { fieldFocused = true }
                    }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused, window.renamingID == id { window.rename(id, to: draft) }
                    }
            } else {
                Text(store.note(id).map(Self.title) ?? "Untitled")
                    .lineLimit(1).truncationMode(.tail)
            }
            Button { window.closeTab(id) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .foregroundStyle(Theme.scratchpadMuted)
                    .background(RoundedRectangle(cornerRadius: 3).fill(closeHover ? Theme.scratchpadActive : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { closeHover = $0 }
            .opacity(hovering || isActive ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .font(Theme.sans(12, isActive ? .semibold : .medium))
        .foregroundStyle(isActive ? Theme.ink : (hovering ? Theme.scratchpadHoverInk : Theme.scratchpadMuted))
        .padding(.leading, 10).padding(.trailing, 6)
        .padding(.top, 4).padding(.bottom, isActive && showsUnderline ? 2 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)   // TabStrip decides the width
        .background(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
            .fill(isActive || hovering ? Theme.frame : .clear))
        .overlay(alignment: .bottom) {
            if isActive && showsUnderline { Rectangle().fill(Theme.ink).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { window.activate(id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { window.renamingID = id })
        .onHover { hovering = $0 }
        .help("Double-click to rename")
    }

    @State private var closeHover = false

    /// Tabs read "Untitled" until the note has words or a name.
    static func title(_ note: Note) -> String {
        note.isBlank ? "Untitled" : note.title
    }
}

/// 28 pt icon button for the top bar.
private struct ToolbarButton: View {
    let systemImage: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 28, height: 28)
                .foregroundStyle(hovering || active ? Theme.ink : Theme.scratchpadIcon)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Theme.scratchpadActive : (hovering ? Theme.scratchpadActive.opacity(0.6) : .clear)))
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

/// Lays tabs out at their natural width (40–160 pt). When they don't fit, the widest ones shrink first.
private struct TabStrip: Layout {
    var spacing: CGFloat = 2
    static let minWidth: CGFloat = 40
    static let maxWidth: CGFloat = 160

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(fitting: proposal.width, subviews)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: widths.reduce(0, +) + gaps(subviews), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(fitting: bounds.width, subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func gaps(_ subviews: Subviews) -> CGFloat { spacing * CGFloat(max(0, subviews.count - 1)) }

    private func widths(fitting available: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { min(Self.maxWidth, max(Self.minWidth, $0.sizeThatFits(.unspecified).width)) }
        guard let available, available.isFinite else { return ideal }
        let room = available - gaps(subviews)
        guard ideal.reduce(0, +) > room else { return ideal }
        // The largest common cap that fits: binary search between the minimum and maximum widths.
        var low = Self.minWidth, high = Self.maxWidth
        for _ in 0..<20 {
            let cap = (low + high) / 2
            if ideal.map({ min($0, cap) }).reduce(0, +) > room { high = cap } else { low = cap }
        }
        return ideal.map { min($0, low) }
    }
}

/// Drags the window from the top bar's empty space (the panel has no title bar).
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

// MARK: - Notes sidebar

private struct NotesSidebar: View {
    @ObservedObject var window: ScratchpadWindow
    @ObservedObject var store: NotesStore
    let width: CGFloat
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            RailButton(systemImage: "sidebar.left", label: "Collapse Notes", help: "Notes (⌘E)",
                       expanded: window.sidebarOpen, active: window.sidebarOpen) { window.toggleSidebar() }
                .padding(.top, 8)
            VStack(spacing: 4) {
                RailButton(systemImage: "square.and.pencil", label: "New note", help: "New note",
                           expanded: window.sidebarOpen) { window.newNote() }
                if window.sidebarOpen {
                    searchBar
                } else {
                    RailButton(systemImage: "magnifyingglass", label: "Search notes", help: "Search notes",
                               expanded: false) { window.startSearch() }
                }
            }
            .padding(.vertical, 4)
            if window.sidebarOpen {
                Rectangle().fill(Theme.border).frame(height: 1)
                    .padding(.horizontal, 8).padding(.bottom, 10)
                notesList
            }
            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .leading)
        .clipped()
        .animation(.easeInOut(duration: 0.15), value: window.sidebarOpen)
        .onChange(of: window.searchFocusRequest) { _, _ in
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: window.sidebarOpen) { _, open in if !open { query = "" } }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.scratchpadMuted)
            TextField("Search notes…", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.sans(12))
                .focused($searchFocused)
                .onExitCommand { query = ""; searchFocused = false; window.focusEditor() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.scratchpadMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(searchFocused ? Theme.scratchpadCard : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(searchFocused ? Theme.border : .clear))
        .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 6)
    }

    private var notesList: some View {
        let notes = store.visible(matching: query)
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(notes) { note in
                    NoteRow(note: note, query: query, active: note.id == window.tabs.activeID, window: window, store: store)
                }
                if notes.isEmpty {
                    Text(query.isEmpty ? "No notes yet" : "No matching notes")
                        .font(Theme.sans(12)).foregroundStyle(Theme.scratchpadMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16).padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .scrollIndicators(.never)
    }
}

/// Full-width 36 pt rail button: a 48 pt icon cell, plus its label when the sidebar is open.
private struct RailButton: View {
    let systemImage: String
    let label: String
    let help: String
    let expanded: Bool
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: systemImage).font(.system(size: 14))
                    .frame(width: ScratchpadWindowView.rail)
                if expanded {
                    Text(label).font(Theme.sans(12, .medium)).lineLimit(1).padding(.trailing, 8)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 36)
            .foregroundStyle(hovering || active ? Theme.ink : Theme.scratchpadIcon)
            .background(Rectangle().fill(active || hovering ? Theme.scratchpadActive : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .onHover { hovering = $0 }
    }
}

private struct NoteRow: View {
    let note: Note
    let query: String
    let active: Bool
    @ObservedObject var window: ScratchpadWindow
    @ObservedObject var store: NotesStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            if note.pinned {
                Image(systemName: "pin").font(.system(size: 11)).foregroundStyle(Theme.scratchpadMuted)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(highlighted(note.title)).font(Theme.sans(12, .medium)).lineLimit(1)
                Text(note.updated, format: .relative(presentation: .named))
                    .font(Theme.sans(11)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
                if let snippet {
                    Text(highlighted(snippet)).font(Theme.sans(11)).foregroundStyle(Theme.scratchpadMuted)
                        .lineLimit(1).padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hovering {
                HStack(spacing: 0) {
                    RowAction(systemImage: note.pinned ? "pin.slash" : "pin", help: note.pinned ? "Unpin" : "Pin") {
                        store.togglePin(note.id)
                    }
                    RowAction(systemImage: "trash", help: "Delete") { window.confirmingDelete = note.id }
                }
                .padding(.leading, 4)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(active ? Theme.scratchpadActive : (hovering ? Theme.scratchpadActive.opacity(0.5) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture { if !active { window.open(note.id) } }
        .onHover { hovering = $0 }
    }

    /// The line containing the match, when searching the body.
    private var snippet: String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        return note.body.split(separator: "\n").map(String.init)
            .first { $0.localizedCaseInsensitiveContains(q) && $0.trimmingCharacters(in: .whitespaces) != note.title }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Marks search matches with a soft yellow.
    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return result }
        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let range = result[searchStart...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            result[range].backgroundColor = Theme.searchHighlight
            searchStart = range.upperBound
        }
        return result
    }
}

private struct RowAction: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 11))
                .frame(width: 24, height: 24)
                .foregroundStyle(hovering ? Theme.ink : Theme.scratchpadMuted)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.border : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Editor

private struct EditorCard: View {
    @ObservedObject var window: ScratchpadWindow
    @ObservedObject var store: NotesStore
    @ObservedObject private var dictation = DictationController.shared

    /// Figtree 14 pt at weight 550 (it's a variable font), falling back to the system font.
    static let font: NSFont = {
        guard let base = NSFont(name: "Figtree", size: 14) else { return .systemFont(ofSize: 14, weight: .medium) }
        let variation = NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let descriptor = base.fontDescriptor.addingAttributes([variation: [0x7767_6874: 550]])   // 'wght'
        return NSFont(descriptor: descriptor, size: 14) ?? base
    }()

    var body: some View {
        let note = window.activeNote
        ZStack(alignment: .topLeading) {
            if let note {
                PlainTextEditor(
                    text: Binding(get: { store.note(note.id)?.body ?? "" },
                                  set: { store.update(note.id, body: $0) }),
                    font: Self.font,
                    documentID: note.id,
                    lineHeight: 28,
                    textColor: NSColor(Theme.ink),
                    caretColor: Theme.caret,
                    inset: NSSize(width: 11, height: 12),
                    bottomOverscroll: 50)
                if note.body.isEmpty {
                    HStack(spacing: 8) {
                        Text(dictation.hotkey.chip)
                            .font(Theme.sans(12, .semibold))
                            .frame(minWidth: 16)
                            .padding(.horizontal, 4)
                            .frame(height: 20)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.frame))
                        Text("to dictate").font(Theme.sans(15, .medium))
                    }
                    .foregroundStyle(Theme.scratchpadMuted)
                    .frame(height: 28)
                    .padding(.top, 12).padding(.leading, 19)   // just clear of the caret
                    .allowsHitTesting(false)
                    .accessibilityLabel("\(dictation.hotkey.chip) to dictate")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            if let note {
                HStack(spacing: 8) {
                    if !note.isBlank {
                        Button { window.confirmingDelete = note.id } label: {
                            Image(systemName: "trash").font(.system(size: 13))
                                .frame(width: 32, height: 32)
                                .foregroundStyle(Theme.scratchpadIcon)
                                .background(Circle().fill(Theme.scratchpadFloating))
                                .overlay(Circle().strokeBorder(Theme.border))
                                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Delete note")
                    }
                    Button { window.copyActiveNote() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc").font(.system(size: 12))
                            Text("Copy").font(Theme.sans(12, .medium))
                        }
                        .foregroundStyle(Theme.scratchpadOnPill)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Capsule().fill(Theme.scratchpadPill))
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(note.body.isEmpty)
                    .opacity(note.body.isEmpty ? 0.4 : 1)
                    .help("Copy note")
                }
                .padding(.trailing, 20).padding(.bottom, 12)
            }
        }
        .background(Theme.scratchpadCard)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Delete confirmation

private struct DeleteConfirmation: View {
    let id: UUID
    @ObservedObject var window: ScratchpadWindow

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .onTapGesture { window.confirmingDelete = nil }
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Are you sure you want to delete this note?").font(Theme.sans(14, .semibold))
                    Text("Once deleted it cannot be recovered").font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { window.confirmingDelete = nil }.buttonStyle(.pillQuiet)
                        .keyboardShortcut(.cancelAction)
                    Button("Delete") { window.delete(id) }.buttonStyle(PillButtonStyle(tint: Theme.recording))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(maxWidth: 380)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.scratchpadFloating)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            .padding(16)
        }
    }
}
