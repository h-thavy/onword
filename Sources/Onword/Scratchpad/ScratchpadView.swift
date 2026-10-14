import AppKit
import OnwordCore
import SwiftUI

/// Scratchpad: recent notes, and an editor you can type or dictate into.
struct ScratchpadPage: View {
    @ObservedObject private var store = NotesStore.shared
    @ObservedObject private var dictation = DictationController.shared
    @State private var query = ""
    @State private var openNoteID: UUID?

    var body: some View {
        Group {
            if let id = openNoteID, let note = store.notes.first(where: { $0.id == id }) {
                NoteEditor(note: note) { openNoteID = nil }
            } else {
                notesList
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openNote)) { notification in
            openNoteID = notification.object as? UUID
        }
        .onDisappear { store.flush() }
    }

    private var notesList: some View {
        PageScroll {
            PageHeader(title: "Scratchpad", badge: "Beta") {
                HStack(spacing: 6) {
                    Text("Open from anywhere").font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
                    KeyChip(text: "⌃⌥S")
                }
            }
            HeroCard(before: "For quick thoughts ", italic: "you", after: " want to come back to",
                     message: "Drop a to-do list, polish a message before you send it, brain-dump an idea. Hold \(dictation.hotkey.title) in a note to dictate.") {
                Button("Start new note") { newNote() }.buttonStyle(.pill)
            }

            HStack {
                Text("Recents").font(Theme.sans(13, .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.selected))
                Spacer()
                Button { newNote() } label: { Label("New note", systemImage: "plus") }.buttonStyle(.pillQuiet)
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
                            IconButton(systemImage: "trash", help: "Delete") { store.delete(note.id) }
                        }
                    }
                    .onTapGesture { openNoteID = note.id }
                }
                if notes.isEmpty {
                    Text(query.isEmpty ? "No notes yet." : "No notes found.").foregroundStyle(Theme.inkTertiary).padding(12)
                }
            }
        }
    }

    private func newNote() {
        // Reuse an empty note rather than piling them up.
        if let empty = store.notes.first(where: { $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            openNoteID = empty.id
        } else {
            openNoteID = store.create().id
        }
    }
}

extension Notification.Name {
    /// Opens a note in the Scratchpad page (object: the note's UUID).
    static let openNote = Notification.Name("Onword.openNote")
}

private struct NoteEditor: View {
    let note: Note
    let close: () -> Void
    @ObservedObject private var store = NotesStore.shared
    @ObservedObject private var dictation = DictationController.shared
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: close) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("All notes").font(Theme.sans(13, .medium))
                    }
                    .foregroundStyle(Theme.inkSecondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(note.updated, format: .relative(presentation: .named))
                    .font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
                IconButton(systemImage: note.pinned ? "pin.fill" : "pin", help: note.pinned ? "Unpin" : "Pin") {
                    store.togglePin(note.id)
                }
                IconButton(systemImage: copied ? "checkmark" : "doc.on.doc", help: "Copy note") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note.body, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                IconButton(systemImage: "trash", help: "Delete note") {
                    store.delete(note.id)
                    close()
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            Divider().overlay(Theme.border)

            PlainTextEditor(
                text: Binding(get: { store.notes.first { $0.id == note.id }?.body ?? "" },
                              set: { store.update(note.id, body: $0) }),
                font: NSFont(name: "Figtree", size: 16) ?? .systemFont(ofSize: 16),
                placeholder: "Start typing, or hold \(dictation.hotkey.title) and speak…",
                documentID: note.id
            )
            .padding(.horizontal, 24)
        }
    }
}
