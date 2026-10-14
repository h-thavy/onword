import Foundation

/// One stretch of speech by one speaker.
public struct TranscriptSegment: Codable, Equatable, Identifiable {
    public var id = UUID()
    /// Seconds from the start of the recording.
    public var start: Double
    public var end: Double
    /// Stable key such as "me", "s1", "s2". Display names live in `Meeting.speakerNames`.
    public var speaker: String
    public var text: String

    public init(start: Double, end: Double, speaker: String, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

public enum TranscriptMerger {
    /// Interleaves segments from several sources (e.g. microphone = "me", system audio = other speakers)
    /// by time, then joins consecutive segments from the same speaker separated by less than `joinGap` seconds.
    public static func merge(_ sources: [[TranscriptSegment]], joinGap: Double = 1.5) -> [TranscriptSegment] {
        let sorted = sources.flatMap { $0 }
            .map { segment -> TranscriptSegment in
                var s = segment
                s.text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return s
            }
            .filter { !$0.text.isEmpty }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        var merged: [TranscriptSegment] = []
        for segment in sorted {
            if var last = merged.last, last.speaker == segment.speaker, segment.start - last.end <= joinGap {
                last.end = max(last.end, segment.end)
                last.text += " " + segment.text
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    /// Drops "me" segments that are just the other side's audio picked up by the microphone
    /// (happens without headphones): same time window and mostly the same words.
    /// Words count as shared when they start the same (“analytic” / “analytics”), since echo is
    /// often transcribed a little differently.
    public static func removeEcho(me: [TranscriptSegment], others: [TranscriptSegment], threshold: Double = 0.5) -> [TranscriptSegment] {
        me.filter { mine in
            let overlapping = others.filter { $0.start < mine.end + 1 && $0.end > mine.start - 1 }
            guard !overlapping.isEmpty else { return true }
            let theirStems = Set(overlapping.flatMap { words($0.text) }.map(stem))
            let myWords = words(mine.text)
            guard !myWords.isEmpty else { return false }
            // "Thanks, bye" over "Thanks everyone": too few words to judge by text (loudness decides those).
            guard myWords.count >= 3 else { return true }
            let shared = myWords.filter { theirStems.contains(stem($0)) }.count
            return Double(shared) / Double(myWords.count) < threshold
        }
    }

    private static func stem(_ word: String) -> String { String(word.prefix(5)) }

    /// "Same person": moves every segment of `from` to `to` and re-joins adjacent turns.
    public static func reassign(_ segments: [TranscriptSegment], from: String, to: String) -> [TranscriptSegment] {
        merge([segments.map { var s = $0; if s.speaker == from { s.speaker = to }; return s }])
    }

    /// Drops Whisper's stock outputs for silence ("you", "Thank you.") when they are short and isolated.
    public static func dropHallucinations(_ segments: [TranscriptSegment], maxDuration: Double = 1.5) -> [TranscriptSegment] {
        segments.filter { !($0.end - $0.start <= maxDuration && TextCleaner.isLikelyHallucination($0.text)) }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

public enum TimeFormat {
    /// 75 → "1:15", 3725 → "1:02:05"
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

public enum TranscriptExporter {
    /// Markdown with one paragraph per speaker turn: **Name** [0:42]: text
    public static func markdown(title: String, date: Date, segments: [TranscriptSegment],
                                speakerNames: [String: String], summary: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var out = "# \(title)\n\n_\(formatter.string(from: date))_\n\n"
        if let summary, !summary.isEmpty { out += "## Summary\n\n\(summary)\n\n" }
        out += "## Transcript\n\n"
        for s in segments {
            out += "**\(speakerNames[s.speaker] ?? s.speaker)** [\(TimeFormat.clock(s.start))]: \(s.text)\n\n"
        }
        return out
    }
}

/// Where to cut a live audio buffer so a chunk ends in a pause, not mid-word.
public enum SilenceCut {
    /// Returns the sample index to cut at once `samples` holds at least `minChunk` seconds:
    /// the middle of the quietest `frame`-long stretch in the last `searchWindow` seconds.
    public static func index(in samples: [Float], sampleRate: Double = 16_000, minChunk: Double = 8,
                             searchWindow: Double = 3, frame: Double = 0.2) -> Int? {
        let count = samples.count
        guard Double(count) >= minChunk * sampleRate else { return nil }
        let frameLength = max(1, Int(frame * sampleRate))
        let searchStart = max(0, count - Int(searchWindow * sampleRate))
        var bestStart = count - frameLength
        var bestEnergy = Float.greatestFiniteMagnitude
        var start = searchStart
        while start + frameLength <= count {
            var energy: Float = 0
            for i in start..<(start + frameLength) { energy += samples[i] * samples[i] }
            if energy < bestEnergy {
                bestEnergy = energy
                bestStart = start
            }
            start += frameLength / 2
        }
        return bestStart + frameLength / 2
    }
}

/// Plain-text transcripts for language-model prompts.
public enum TranscriptText {
    /// One "Name: text" line per speaker turn.
    public static func lines(_ segments: [TranscriptSegment], name: (String) -> String) -> [String] {
        segments.map { "\(name($0.speaker)): \($0.text)" }
    }

    /// Groups lines into chunks of at most `maxCharacters` (a single over-long line is split on its own).
    public static func chunks(_ lines: [String], maxCharacters: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in lines {
            for piece in split(line, maxCharacters) {
                if !current.isEmpty, current.count + piece.count + 1 > maxCharacters {
                    chunks.append(current)
                    current = ""
                }
                current += current.isEmpty ? piece : "\n" + piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func split(_ line: String, _ max: Int) -> [String] {
        guard line.count > max else { return [line] }
        var pieces: [String] = []
        var rest = Substring(line)
        while rest.count > max {
            let limit = rest.index(rest.startIndex, offsetBy: max)
            let cut = rest[..<limit].lastIndex(of: " ") ?? limit
            pieces.append(String(rest[..<cut]))
            rest = rest[cut...].drop { $0 == " " }
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces
    }
}

/// Tells your own speech on the microphone from the call leaking out of the Mac's speakers: echo is a faint
/// copy of the call audio, while your voice is loud on your mic. Compares loudness frame by frame
/// (100 ms) while the call is active.
public enum EchoDetector {
    /// True when, during the segment, the call is playing most of the time and the mic is only a faint copy
    /// of it (median mic/call loudness below `ratio`).
    public static func isEcho(mic: [Float], system: [Float], start: Double, end: Double,
                              sampleRate: Double = 16_000, ratio: Float = 0.3) -> Bool {
        let frame = Int(sampleRate / 10)
        let first = max(0, Int(start * sampleRate)), last = min(mic.count, system.count, Int(end * sampleRate))
        guard last - first >= frame else { return false }
        var ratios: [Float] = []
        var active = 0, frames = 0
        var i = first
        while i + frame <= last {
            let callRMS = rms(system, i, frame), micRMS = rms(mic, i, frame)
            frames += 1
            if callRMS > 0.01 {
                active += 1
                ratios.append(micRMS / callRMS)
            }
            i += frame
        }
        guard frames > 0, Double(active) / Double(frames) >= 0.6, !ratios.isEmpty else { return false }
        ratios.sort()
        return ratios[ratios.count / 2] < ratio
    }

    private static func rms(_ x: [Float], _ start: Int, _ count: Int) -> Float {
        var sum: Float = 0
        for k in start..<(start + count) { sum += x[k] * x[k] }
        return (sum / Float(count)).squareRoot()
    }
}

/// Fixes names the speech model misheard ("Chantavi" → "Chanthavy", "Penompen" → "Phnom Penh") using the
/// people invited and your dictionary. Only words that aren't real words are touched, so "camper" stays
/// "camper" even if a "Kampot" is expected. One to three words are compared with each name (and the name's
/// own words), by spelling and rough sound.
public struct NameCorrector {
    private let names: [(name: String, key: String, words: Int)]
    private let isWord: (String) -> Bool

    /// - Parameter isWord: whether a word is ordinary vocabulary (e.g. the spell checker knows it).
    public init(names: [String], isWord: @escaping (String) -> Bool) {
        var seen = Set<String>()
        var list: [(String, String, Int)] = []
        for full in names {
            // Full names and each part of them ("Dara Sok" → also "Dara", "Sok").
            let parts = full.split(separator: " ").map(String.init)
            for candidate in [full] + (parts.count > 1 ? parts : []) {
                let key = Self.key(candidate)
                guard key.count >= 4, seen.insert(key).inserted else { continue }
                list.append((candidate, key, candidate.split(separator: " ").count))
            }
        }
        self.names = list
        self.isWord = isWord
    }

    public func correct(_ text: String) -> String {
        guard !names.isEmpty else { return text }
        var tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < tokens.count {
            var replaced = false
            for span in stride(from: 3, through: 1, by: -1) where i + span <= tokens.count {
                let window = Array(tokens[i..<(i + span)])
                let core = window.map { $0.trimmingCharacters(in: .punctuationCharacters) }
                let phrase = core.joined(separator: " ")
                let key = Self.key(phrase)
                guard key.count >= 4 else { continue }
                // Real words are left alone unless together they spell a name exactly ("launch darkly").
                let realWords = core.allSatisfy { $0.isEmpty || isWord($0.lowercased()) }
                // A near match never swallows real words at its edges ("CIMREAP is" → "Siem Reap is").
                let edgesAreWords = span > 1 && (isWord(core.first!.lowercased()) || isWord(core.last!.lowercased()))
                let match = realWords || edgesAreWords ? (span > 1 ? names.first { $0.key == key } : nil) : best(for: key)
                guard let match, match.name != phrase else { continue }
                let trailing = String(window.last!.reversed().prefix { $0.isPunctuation }.reversed())
                let leading = String(window.first!.prefix { $0.isPunctuation })
                tokens.replaceSubrange(i..<(i + span), with: [leading + match.name + trailing])
                replaced = true
                break
            }
            i += 1
            _ = replaced
        }
        return tokens.joined(separator: " ")
    }

    private func best(for key: String) -> (name: String, key: String, words: Int)? {
        var bestMatch: (name: String, key: String, words: Int)?
        var bestScore = Double.infinity
        for entry in names {
            let distance = Double(Self.levenshtein(key, entry.key)) / Double(max(key.count, entry.key.count))
            // Close in sound, and starting with the same sound.
            // Longer names can be a little further off ("Penompin" for "Phnom Penh").
            let limit = min(key.count, entry.key.count) >= 7 ? 0.4 : 0.34
            if distance <= limit, distance < bestScore, Self.sameSound(key.first, entry.key.first) {
                bestScore = distance
                bestMatch = entry
            }
        }
        return bestMatch
    }

    /// First letters that sound alike (Phnom / Penompen, Gary / Kerry).
    private static let soundGroups: [Set<Character>] = [["p", "f", "b", "v"], ["k", "g"], ["s"], ["t", "d"], ["m", "n"]]

    static func sameSound(_ a: Character?, _ b: Character?) -> Bool {
        guard let a, let b else { return false }
        return a == b || soundGroups.contains { $0.contains(a) && $0.contains(b) }
    }

    /// Letters only, lowercased, with common sound-alikes folded (ph→f, soft c→s, hard c/q→k, z→s, double
    /// letters, silent h…).
    static func key(_ text: String) -> String {
        var s = text.lowercased().filter(\.isLetter)
        for (from, to) in [("ph", "f"), ("th", "t"), ("ck", "k"), ("ce", "se"), ("ci", "si"), ("cy", "si"), ("q", "k"),
                           ("c", "k"), ("z", "s"), ("y", "i"), ("ee", "i"), ("ea", "i"), ("w", "v")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        s = s.replacingOccurrences(of: "h", with: "")
        var out = ""
        for ch in s where out.last != ch { out.append(ch) }
        return out
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let temp = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = temp
            }
        }
        return row[b.count]
    }
}
