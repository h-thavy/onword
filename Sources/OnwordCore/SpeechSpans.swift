import Foundation

/// Where someone is speaking in a track: stretches louder than the track's background, with short pauses
/// bridged and a little padding. Models fine-tuned on short clips (like the Khmer one) invent text over long
/// silences, so they're given only these stretches.
public enum SpeechSpans {
    /// Sample ranges at `rate`, each at most `maxSeconds` long (longer speech is cut at its quietest moment).
    public static func find(_ samples: [Float], rate: Double = 16_000, maxSeconds: Double = 28) -> [Range<Int>] {
        let frame = Int(rate * 0.03)
        guard samples.count > frame else { return [] }
        let energy = stride(from: 0, to: samples.count - frame, by: frame).map { start -> Float in
            var sum: Float = 0
            for i in start..<start + frame { sum += samples[i] * samples[i] }
            return (sum / Float(frame)).squareRoot()
        }
        let loud = energy.sorted()[Int(Double(energy.count - 1) * 0.95)]
        let threshold = max(0.01, loud * 0.15)
        let bridge = 20, pad = Int(rate * 0.2), minimum = Int(rate * 0.5)

        var spans: [Range<Int>] = []
        var i = 0
        while i < energy.count {
            guard energy[i] > threshold else { i += 1; continue }
            var j = i
            while j < energy.count, energy[j] > threshold || energy[j..<min(energy.count, j + bridge)].contains(where: { $0 > threshold }) {
                j += 1
            }
            let span = max(0, i * frame - pad)..<min(samples.count, j * frame + pad)
            if span.count >= minimum { spans.append(span) }
            i = j
        }
        // Overlapping padding: join.
        var joined: [Range<Int>] = []
        for span in spans {
            if let last = joined.last, span.lowerBound <= last.upperBound {
                joined[joined.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else { joined.append(span) }
        }
        let maxCount = Int(rate * maxSeconds)
        return joined.flatMap { split($0, energy: energy, frame: frame, maxCount: maxCount) }
    }

    private static func split(_ span: Range<Int>, energy: [Float], frame: Int, maxCount: Int) -> [Range<Int>] {
        guard span.count > maxCount else { return [span] }
        // The quietest frame in the second half of the allowed length.
        let from = (span.lowerBound + maxCount / 2) / frame, to = min(energy.count, (span.lowerBound + maxCount) / frame)
        let cutFrame = (from..<max(from + 1, to)).min { energy[min($0, energy.count - 1)] < energy[min($1, energy.count - 1)] } ?? to
        let cut = min(span.upperBound, max(span.lowerBound + 1, cutFrame * frame))
        return [span.lowerBound..<cut] + split(cut..<span.upperBound, energy: energy, frame: frame, maxCount: maxCount)
    }
}
