import AppKit
import OnwordCore
import SwiftUI

/// The Hub's Scratchpad page: a list of notes and a launcher. Notes open in the floating Scratchpad
/// window (⌃⌥S), not here.
struct ScratchpadPage: View {
    @ObservedObject private var store = NotesStore.shared
    @ObservedObject private var dictation = DictationController.shared
    @State private var query = ""

    var body: some View {
        PageScroll {
            PageHeader(title: "Scratchpad", badge: "Beta") {
                Button { ScratchpadWindow.shared.show() } label: {
                    Text("⌃⌥S")
                        .font(Theme.sans(15, .medium)).foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(height: 36)
                        .background(Capsule().fill(Theme.shortcutPill))
                        .overlay(Capsule().strokeBorder(Theme.shortcutPillRing))
                }
                .buttonStyle(.plainPointer)
                .help("Open the Scratchpad window from anywhere")
            }
            HeroCard(before: "For quick thoughts ", italic: "you", after: " want to come back to",
                     message: "Drop a to-do list, polish a message before you send it, brain-dump an idea. Hold \(dictation.hotkey.title) in a note to dictate.") {
                Button("Start new note") { ScratchpadWindow.shared.newNote() }.buttonStyle(.pill)
            }

            HStack(spacing: 0) {
                UnderlineTab(title: "Recents")
                    .padding(.leading, -12)
                Spacer()
                Button { ScratchpadWindow.shared.newNote() } label: { Label("New note", systemImage: "plus") }
                    .buttonStyle(.pillQuiet)
                    .controlSize(.small)
            }
            .background(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            SearchField(prompt: "Search your notes", text: $query)

            let notes = store.visible(matching: query)
            if notes.isEmpty {
                EmptyState(title: query.isEmpty ? "No notes yet." : "No notes found",
                           detail: "Press ⌃⌥S anywhere to open the Scratchpad.")
            } else {
                VStack(spacing: 16) {
                    ForEach(notes) { note in
                        NoteCard(note: note)
                    }
                }
            }
        }
    }
}

/// A note card: white tile with a hairline border and a soft shadow; actions float in on hover.
private struct NoteCard: View {
    let note: Note
    @ObservedObject private var store = NotesStore.shared
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if note.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.onAccent)
                }
                Text(note.title).font(Theme.sans(14, .semibold)).lineLimit(1)
            }
            if !note.preview.isEmpty {
                Text(note.preview).font(Theme.sans(13)).foregroundStyle(Theme.inkFaint).lineLimit(3)
            }
            Spacer(minLength: 4)
            Text(note.updated, format: .relative(presentation: .named))
                .font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .shadow(color: Color(hex: 0x1A1A1A).opacity(0.1), radius: 1.5, y: 1)
        .overlay(alignment: .topTrailing) {
            if hovering {
                HStack(spacing: 6) {
                    IconButton(systemImage: note.pinned ? "pin.slash" : "pin",
                               help: note.pinned ? "Unpin" : "Pin", bordered: true) {
                        store.togglePin(note.id)
                    }
                    IconButton(systemImage: "trash", help: "Delete", bordered: true) {
                        ScratchpadWindow.shared.delete(note.id)
                    }
                }
                .padding(8)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onTapGesture { ScratchpadWindow.shared.open(note.id) }
        .help("Open in the Scratchpad window")
    }
}
