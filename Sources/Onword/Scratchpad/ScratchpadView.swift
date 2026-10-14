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
                    HStack(spacing: 6) {
                        KeyChip(text: "⌃⌥S")
                        Text("to open").font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                .buttonStyle(.plain)
                .help("Open the Scratchpad window from anywhere")
            }
            HeroCard(before: "For quick thoughts ", italic: "you", after: " want to come back to",
                     message: "Drop a to-do list, polish a message before you send it, brain-dump an idea. Hold \(dictation.hotkey.title) in a note to dictate.") {
                Button("Start new note") { ScratchpadWindow.shared.newNote() }.buttonStyle(.pill)
            }

            HStack {
                Text("Recents").font(Theme.sans(13, .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.selected))
                Spacer()
                Button { ScratchpadWindow.shared.newNote() } label: { Label("New note", systemImage: "plus") }
                    .buttonStyle(.pillQuiet)
            }
            SearchField(prompt: "Search your notes", text: $query)

            let notes = store.visible(matching: query)
            VStack(spacing: 2) {
                ForEach(notes) { note in
                    HoverRow {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                if note.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.onAccent) }
                                Text(note.title).font(Theme.sans(14, .semibold)).lineLimit(1)
                            }
                            HStack(spacing: 6) {
                                Text(note.updated, format: .relative(presentation: .named))
                                if !note.preview.isEmpty { Text("·"); Text(note.preview).lineLimit(1) }
                            }
                            .font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
                        }
                    } actions: {
                        HStack(spacing: 2) {
                            IconButton(systemImage: note.pinned ? "pin.slash" : "pin", help: note.pinned ? "Unpin" : "Pin") {
                                store.togglePin(note.id)
                            }
                            IconButton(systemImage: "trash", help: "Delete") { ScratchpadWindow.shared.delete(note.id) }
                        }
                    }
                    .onTapGesture { ScratchpadWindow.shared.open(note.id) }
                    .help("Open in the Scratchpad window")
                }
                if notes.isEmpty {
                    Text(query.isEmpty ? "No notes yet." : "No notes found.").foregroundStyle(Theme.inkTertiary).padding(12)
                }
            }
        }
    }
}
