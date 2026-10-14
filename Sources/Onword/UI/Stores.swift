import Foundation
import OnwordCore

/// Dictation history (history.jsonl) for the Dictation page.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    struct Item: Identifiable, Equatable {
        let id: Int          // line number in history.jsonl
        let entry: HistoryEntry
        static func == (a: Item, b: Item) -> Bool { a.id == b.id && a.entry.date == b.entry.date }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var stats = DictationStats(totalWords: 0, wordsPerMinute: 0, dayStreak: 0)

    private init() {
        reload()
        NotificationCenter.default.addObserver(forName: .historyChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HistoryStore.shared.reload() }
        }
    }

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = (try? String(contentsOf: AppPaths.history, encoding: .utf8))?.split(separator: "\n") ?? []
        items = lines.enumerated().compactMap { index, line in
            (try? decoder.decode(HistoryEntry.self, from: Data(line.utf8))).map { Item(id: index, entry: $0) }
        }
        .reversed()
        stats = DictationStats(items.map { .init(date: $0.entry.date, text: $0.entry.text, seconds: $0.entry.seconds) })
    }

    /// Newest first, grouped by day ("Today", "Yesterday", "Monday, Oct 12").
    func grouped(matching query: String) -> [(day: String, items: [Item])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? items : items.filter { $0.entry.text.localizedCaseInsensitiveContains(q) }
        var groups: [(String, [Item])] = []
        for item in filtered {
            let label = Self.dayLabel(item.entry.date)
            if groups.last?.0 == label { groups[groups.count - 1].1.append(item) } else { groups.append((label, [item])) }
        }
        return groups.map { (day: $0.0, items: $0.1) }
    }

    func delete(_ item: Item) {
        var lines = (try? String(contentsOf: AppPaths.history, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        guard item.id < lines.count else { return }
        lines.remove(at: item.id)
        try? lines.joined(separator: "\n").write(to: AppPaths.history, atomically: true, encoding: .utf8)
        reload()
    }

    static func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

/// The dictionary file as editable lists for the Dictionary and Snippets pages.
@MainActor
final class DictionaryStore: ObservableObject {
    static let shared = DictionaryStore()

    @Published private(set) var dictionary = UserDictionary()

    private init() {
        AppPaths.ensureDictionary()
        dictionary = UserDictionary.load(from: AppPaths.dictionary)
        migrateSnippetsIfNeeded()
    }

    /// Files from before Snippets existed kept snippets among the corrections. Once, move the entries
    /// that look like snippets (long text, emails, links) to Snippets.
    private func migrateSnippetsIfNeeded() {
        guard let raw = try? String(contentsOf: AppPaths.dictionary, encoding: .utf8), !raw.contains("\"snippets\"") else { return }
        update { d in
            for (spoken, written) in d.replacements
            where written.count > 30 || written.contains("@") || written.contains("http") || written.contains("\n") {
                d.snippets[spoken] = written
                d.replacements[spoken] = nil
            }
        }
    }

    func reload() { dictionary = UserDictionary.load(from: AppPaths.dictionary) }

    func update(_ change: (inout UserDictionary) -> Void) {
        change(&dictionary)
        try? dictionary.save(to: AppPaths.dictionary)
    }

    // Words and corrections shown together on the Dictionary page.
    enum Entry: Identifiable, Hashable {
        case word(String)
        case correction(from: String, to: String)
        var id: String {
            switch self {
            case .word(let w): "w:\(w)"
            case .correction(let from, _): "c:\(from)"
            }
        }
        var sortKey: String {
            switch self {
            case .word(let w): w.lowercased()
            case .correction(let from, _): from.lowercased()
            }
        }
    }

    func entries(matching query: String) -> [Entry] {
        let words = dictionary.vocabulary.map(Entry.word)
        let corrections = dictionary.replacements.map { Entry.correction(from: $0.key, to: $0.value) }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return (words + corrections)
            .filter { entry in
                guard !q.isEmpty else { return true }
                switch entry {
                case .word(let w): return w.lowercased().contains(q)
                case .correction(let a, let b): return a.lowercased().contains(q) || b.lowercased().contains(q)
                }
            }
            .sorted { $0.sortKey < $1.sortKey }
    }

    func snippets(matching query: String) -> [(trigger: String, text: String)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return dictionary.snippets
            .filter { q.isEmpty || $0.key.lowercased().contains(q) || $0.value.lowercased().contains(q) }
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { (trigger: $0.key, text: $0.value) }
    }

    func remove(_ entry: Entry) {
        update { d in
            switch entry {
            case .word(let w): d.vocabulary.removeAll { $0 == w }
            case .correction(let from, _): d.replacements[from] = nil
            }
        }
    }
}
