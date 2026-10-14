import Foundation

/// The user's personal dictionary, stored as editable JSON.
///
/// - `vocabulary`: words Whisper should expect (names, jargon). Passed to the model as a prompt.
/// - `replacements`: corrections, heard → written ("flow light" → "Onword"). Shown in Dictionary.
/// - `snippets`: a trigger phrase you say → longer text it expands to ("my email" → "me@example.com").
public struct UserDictionary: Codable, Equatable {
    public var vocabulary: [String]
    public var replacements: [String: String]
    public var snippets: [String: String]

    public init(vocabulary: [String] = [], replacements: [String: String] = [:], snippets: [String: String] = [:]) {
        self.vocabulary = vocabulary
        self.replacements = replacements
        self.snippets = snippets
    }

    /// Older files have no `snippets` key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
        replacements = try c.decodeIfPresent([String: String].self, forKey: .replacements) ?? [:]
        snippets = try c.decodeIfPresent([String: String].self, forKey: .snippets) ?? [:]
    }

    /// Everything to substitute after transcription: corrections plus snippets.
    public var allReplacements: [String: String] {
        replacements.merging(snippets) { _, snippet in snippet }
    }

    public static let example = UserDictionary(
        vocabulary: ["Onword", "WhisperKit", "Claude"],
        replacements: ["flow light": "Onword"],
        snippets: ["my email": "me@example.com"]
    )

    /// Whisper only uses roughly the last 224 prompt tokens; keep the prompt short and most recent-first.
    public func whisperPrompt(maxCharacters: Int = 600) -> String? {
        var prompt = ""
        for word in vocabulary where !word.isEmpty {
            let next = prompt.isEmpty ? word : prompt + ", " + word
            if next.count > maxCharacters { break }
            prompt = next
        }
        return prompt.isEmpty ? nil : prompt
    }

    public static func load(from url: URL) -> UserDictionary {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode(UserDictionary.self, from: data) else { return UserDictionary() }
        return dict
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
