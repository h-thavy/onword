import Foundation

/// Turns a raw Whisper transcript into text ready to insert, using rules only (no LLM).
///
/// Order matters: strip model artifacts → voice commands → fillers → dictionary →
/// whitespace/punctuation tidy-up → fit to the text around the cursor.
public struct TextCleaner {
    public var removeFillers: Bool
    public var smartSpacing: Bool
    /// Spoken form → written form, matched case-insensitively on word boundaries.
    public var replacements: [String: String]

    public init(removeFillers: Bool = true, smartSpacing: Bool = true, replacements: [String: String] = [:]) {
        self.removeFillers = removeFillers
        self.smartSpacing = smartSpacing
        self.replacements = replacements
    }

    /// - Parameters:
    ///   - before: text immediately before the cursor in the target field (may be empty/unknown)
    ///   - after: text immediately after the cursor
    public func clean(_ raw: String, before: String = "", after: String = "") -> String {
        var text = raw
        text = Self.stripArtifacts(text)
        text = Self.applyScratchThat(text)
        text = Self.applyLineCommands(text)
        if removeFillers { text = Self.stripFillers(text) }
        text = Self.applyReplacements(text, replacements)
        text = Self.tidy(text)
        if text.isEmpty { return "" }
        if smartSpacing { text = Self.fitToContext(text, before: before, after: after) }
        return text
    }

    /// Whisper's well-known outputs for silence or noise. Only meaningful for very short or quiet audio.
    public static func isLikelyHallucination(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return normalized.isEmpty || hallucinations.contains(normalized)
    }

    static let hallucinations: Set<String> = [
        "you", "thank you", "thanks", "thank you very much", "thanks for watching",
        "thank you for watching", "bye", "okay", "so", "subtitles by the amaraorg community",
    ]

    // MARK: - Steps

    /// `[BLANK_AUDIO]`, `[Music]`, `(upbeat music)`, `*coughs*`, and so on. Text that is nothing but one
    /// parenthesised description, like "(Bell chimes)", is Whisper describing a sound, not speech.
    static func stripArtifacts(_ text: String) -> String {
        if text.range(of: #"^\s*\([^()]*\)[.!]?\s*$"#, options: .regularExpression) != nil { return "" }
        var t = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\*[^*]+\*"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(
            of: #"\((?:[^)]*\b(?:music|applause|laughs?|laughter|silence|noise|inaudible|coughs?|sighs?)\b[^)]*)\)"#,
            with: " ", options: [.regularExpression, .caseInsensitive])
        return t
    }

    /// "Send it Monday. Scratch that. Send it Tuesday." → "Send it Tuesday."
    /// Removes the sentence spoken immediately before "scratch that".
    static func applyScratchThat(_ text: String) -> String {
        let marker = #"[,.!?]?\s*\bscratch that\b[,.!?]?\s*"#
        guard let regex = try? NSRegularExpression(pattern: marker, options: .caseInsensitive) else { return text }
        var result = text
        while let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
              let range = Range(match.range, in: result) {
            var head = String(result[..<range.lowerBound])
            let tail = String(result[range.upperBound...])
            // Drop the last sentence of `head`.
            if let lastStop = head.trimmingCharacters(in: .whitespaces)
                .lastIndex(where: { ".!?\n".contains($0) }) {
                head = String(head[...lastStop])
            } else {
                head = ""
            }
            // What follows "scratch that" starts a new sentence.
            result = head.isEmpty ? tail : head + " " + capitalizeFirst(tail)
        }
        return result
    }

    /// "new line" / "new paragraph" spoken as commands. Keeps the punctuation before the command and
    /// drops the punctuation Whisper adds after it ("Dear Sam, new paragraph. Thanks" → "Dear Sam,\n\nThanks").
    static func applyLineCommands(_ text: String) -> String {
        var t = text.replacingOccurrences(
            of: #"\s*\bnew paragraph\b[,.!?]?\s*"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(
            of: #"\s*\bnew ?line\b[,.!?]?\s*"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        return t
    }

    static func stripFillers(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\b(?:u+m+|u+h+m*|e+r+m+|h+m+)\b[,.]?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    static func applyReplacements(_ text: String, _ replacements: [String: String]) -> String {
        // Longest phrases first so "open ai api" wins over "open ai".
        replacements.keys.sorted { $0.count > $1.count }.reduce(text) { acc, spoken in
            guard !spoken.isEmpty, let written = replacements[spoken] else { return acc }
            let pattern = #"(?<![\w])"# + NSRegularExpression.escapedPattern(for: spoken) + #"(?![\w])"#
            return acc.replacingOccurrences(
                of: pattern, with: NSRegularExpression.escapedTemplate(for: written),
                options: [.regularExpression, .caseInsensitive])
        }
    }

    /// Collapse spaces (but keep newlines), remove space before punctuation, capitalize after newlines.
    static func tidy(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #" +([,.!?;:])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"([,.!?;:])\1+"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^[,.;:]\s*"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespaces)
        t = t.split(separator: "\n", omittingEmptySubsequences: false)
            .map { capitalizeFirst(String($0)) }
            .joined(separator: "\n")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Match casing and spacing to what is already in the text field.
    static func fitToContext(_ text: String, before: String, after: String) -> String {
        var t = text
        let prev = before.last
        // Trims spaces/tabs only, so a trailing newline still counts as a sentence boundary.
        let lastNonSpace = before.trimmingCharacters(in: .whitespaces).last

        if let lastNonSpace, !".!?\n".contains(lastNonSpace) {
            t = lowercaseFirst(t)
        } else {
            t = capitalizeFirst(t)
        }

        // Leading space when gluing onto a word or punctuation.
        if let prev, !prev.isWhitespace, !"([{\"'“‘/".contains(prev) {
            t = " " + t
        }

        // Inserting before existing text: drop our final period and separate with a space.
        if let next = after.first, next.isLetter || next.isNumber {
            if t.hasSuffix(".") { t.removeLast() }
            t += " "
        }
        return t
    }

    static func capitalizeFirst(_ s: String) -> String {
        guard let i = s.firstIndex(where: { $0.isLetter }) else { return s }
        return s.replacingCharacters(in: i...i, with: s[i].uppercased())
    }

    /// Lowercase the first word unless it looks like "I", an acronym or a proper noun we can't know about.
    static func lowercaseFirst(_ s: String) -> String {
        guard let i = s.firstIndex(where: { $0.isLetter }) else { return s }
        let word = s[i...].prefix { $0.isLetter || $0 == "'" }
        if word == "I" || word.hasPrefix("I'") { return s }
        if word.count > 1, word.dropFirst().contains(where: { $0.isUppercase }) { return s }
        return s.replacingCharacters(in: i...i, with: s[i].lowercased())
    }
}
