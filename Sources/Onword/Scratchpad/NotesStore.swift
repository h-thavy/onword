import Foundation
import OnwordCore

/// Scratchpad notes, one JSON file per note in Application Support/Onword/Notes.
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published private(set) var notes: [Note] = []
    @Published var selectedID: UUID?

    private var pendingSaves: [UUID: DispatchWorkItem] = [:]

    private init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: AppPaths.notes, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        notes = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Note.self, from: Data(contentsOf: $0)) }
            .sortedForList()
        selectedID = notes.first?.id
    }

    var selected: Note? { notes.first { $0.id == selectedID } }

    func visible(matching query: String) -> [Note] {
        notes.filter { $0.matches(query) }.sortedForList()
    }

    @discardableResult
    func create(body: String = "") -> Note {
        let note = Note(body: body)
        notes.insert(note, at: 0)
        selectedID = note.id
        write(note)
        return note
    }

    func update(_ id: UUID, body: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].body != body else { return }
        notes[index].body = body
        notes[index].updated = Date()
        scheduleSave(notes[index])
    }

    func togglePin(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].pinned.toggle()
        write(notes[index])
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        pendingSaves[id]?.cancel()
        try? FileManager.default.removeItem(at: url(for: id))
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func write(_ note: Note) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(note).write(to: url(for: note.id), options: .atomic)
    }

    private func url(for id: UUID) -> URL {
        AppPaths.notes.appendingPathComponent("\(id.uuidString).json")
    }
}
