import Foundation

/// A Scratchpad note. The body is plain text (Markdown-friendly); the title is its first line.
public struct Note: Codable, Equatable, Identifiable {
    public var id: UUID
    public var body: String
    public var created: Date
    public var updated: Date
    public var pinned: Bool

    public init(id: UUID = UUID(), body: String = "", created: Date = Date(), updated: Date = Date(), pinned: Bool = false) {
        self.id = id
        self.body = body
        self.created = created
        self.updated = updated
        self.pinned = pinned
    }

    /// First non-empty line without Markdown heading marks, capped at 60 characters.
    public var title: String {
        let line = body.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let cleaned = line.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
        if cleaned.isEmpty { return "New note" }
        return cleaned.count > 60 ? String(cleaned.prefix(60)) + "…" : cleaned
    }

    /// Second non-empty line, for the list preview.
    public var preview: String {
        body.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .dropFirst()
            .first ?? ""
    }

    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || body.localizedCaseInsensitiveContains(q)
    }
}

public extension Array where Element == Note {
    /// Pinned first, then most recently edited.
    func sortedForList() -> [Note] {
        sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updated > b.updated
        }
    }
}
