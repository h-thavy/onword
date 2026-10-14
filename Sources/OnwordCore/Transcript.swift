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
    public static func removeEcho(me: [TranscriptSegment], others: [TranscriptSegment], threshold: Double = 0.6) -> [TranscriptSegment] {
        me.filter { mine in
            let overlapping = others.filter { $0.start < mine.end && $0.end > mine.start }
            guard !overlapping.isEmpty else { return true }
            let theirWords = Set(overlapping.flatMap { words($0.text) })
            let myWords = words(mine.text)
            guard !myWords.isEmpty else { return false }
            let shared = myWords.filter { theirWords.contains($0) }.count
            return Double(shared) / Double(myWords.count) < threshold
        }
    }

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
