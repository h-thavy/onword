import Foundation
import OnwordCore

/// Scratchpad notes, one JSON file per note in Application Support/Onword/Notes.
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published private(set) var notes: [Note] = []
    @Published var selectedID: UUID?

    private var pendingSaves: [UUID: DispatchWorkItem] = [:]
    /// Test hook (ONWORD_TEST_SCRATCHPAD): sample notes kept in memory only, so snapshots never show,
    /// change or add to the real notes.
    private let inMemory = ProcessInfo.processInfo.environment["ONWORD_TEST_SCRATCHPAD"] != nil

    private init() {
        if inMemory {
            notes = Self.sampleNotes().sortedForList()
            selectedID = notes.first?.id
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: AppPaths.notes, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        notes = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Note.self, from: Data(contentsOf: $0)) }
            .sortedForList()
        selectedID = notes.first?.id
    }

    var selected: Note? { notes.first { $0.id == selectedID } }

    func note(_ id: UUID?) -> Note? { notes.first { $0.id == id } }

    /// Notes for the lists: pinned first, then newest. Blank notes (empty open tabs) are left out.
    func visible(matching query: String) -> [Note] {
        notes.filter { !$0.isBlank && $0.matches(query) }.sortedForList()
    }

    @discardableResult
    func create(body: String = "") -> Note {
        let note = Note(body: body)
        notes.insert(note, at: 0)
        selectedID = note.id
        // A blank note is only saved once something is typed in it (or it's renamed).
        if !note.isBlank { write(note) }
        return note
    }

    func update(_ id: UUID, body: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].body != body else { return }
        notes[index].body = body
        notes[index].updated = Date()
        scheduleSave(notes[index])
    }

    /// Names a note (renaming its Scratchpad tab). An empty name goes back to the first line.
    func rename(_ id: UUID, to title: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        notes[index].customTitle = trimmed.isEmpty ? nil : trimmed
        notes[index].updated = Date()
        write(notes[index])
    }

    /// Deletes a note that was opened but never written in, so closing empty tabs leaves no clutter.
    func discardIfBlank(_ id: UUID) {
        if note(id)?.isBlank == true { delete(id) }
    }

    func togglePin(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].pinned.toggle()
        write(notes[index])
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        pendingSaves[id]?.cancel()
        if !inMemory { try? FileManager.default.removeItem(at: url(for: id)) }
        if selectedID == id { selectedID = visible(matching: "").first?.id }
    }

    /// Saves everything immediately (e.g. when the window closes or the app quits).
    func flush() {
        for (id, work) in pendingSaves {
            work.cancel()
            if let note = notes.first(where: { $0.id == id }) { write(note) }
        }
        pendingSaves.removeAll()
    }

    // MARK: - Persistence

    private func scheduleSave(_ note: Note) {
        pendingSaves[note.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let latest = self.notes.first(where: { $0.id == note.id }) else { return }
                self.write(latest)
                self.pendingSaves[note.id] = nil
            }
        }
        pendingSaves[note.id] = work
        // Autosave after 2 s without typing (as Wispr Flow's Scratchpad); flush() saves sooner.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func write(_ note: Note) {
        guard !inMemory else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(note).write(to: url(for: note.id), options: .atomic)
    }

    private static func sampleNotes() -> [Note] {
        let now = Date()
        return [
            Note(body: "Groceries\n- oat milk\n- lemons\n- sourdough\n- coffee beans",
                 updated: now.addingTimeInterval(-300), pinned: true),
            Note(body: "Reply to Dara about Thursday\nThanks for the notes. Thursday at 3 works for me, and I'll bring the draft so we can go through it together.",
                 updated: now.addingTimeInterval(-60)),
            Note(body: "Ideas for the onboarding video\nShow the shortcut first, then a real dictation into Mail.",
                 updated: now.addingTimeInterval(-7200)),
            Note(body: "Shipped the Scratchpad window.\nNext: QA on full-screen Spaces.",
                 updated: now.addingTimeInterval(-90000), customTitle: "Standup notes"),
        ]
    }

    private func url(for id: UUID) -> URL {
        AppPaths.notes.appendingPathComponent("\(id.uuidString).json")
    }
}
