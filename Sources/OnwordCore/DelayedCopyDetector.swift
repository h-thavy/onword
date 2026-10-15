import Accelerate
import Foundation

/// Finds your own voice coming back through the call: when the same call is also open on another device near
/// you (your phone, a colleague's laptop), its mic hears you and the call plays you back a moment later, so the
/// call track holds a delayed copy of your mic. A stretch of the call is compared with your mic 0.1–3 s
/// earlier, twice:
/// - its spectrum in 23 bands (10 ms steps): a returned copy scored about 0.5, other people at most 0.42;
/// - its fine harmonic detail (the pitch, which only the same voice saying the same thing shares): the copy
///   scored 0.18, other people at most 0.08.
/// Both must agree, over at least 0.8 s of sound.
public struct DelayedCopyDetector {
    private static let bands = 23, hop = 160, window = 400, fftSize = 512
    private let mic: [Float], call: [Float]   // frames × bands, log magnitude
    private let micSamples: [Float], callSamples: [Float]
    private let callLoudness: [Float]
    private let loudThreshold: Float
    private let threshold: Float

    public init(mic: [Float], system: [Float], threshold: Float = 0.35) {
        micSamples = mic
        callSamples = system
        self.mic = Self.spectrum(mic)
        let call = Self.spectrum(system)
        self.call = call
        callLoudness = (0..<call.count / Self.bands).map { f in
            var sum: Float = 0
            for b in 0..<Self.bands { sum += call[f * Self.bands + b] }
            return sum / Float(Self.bands)
        }
        let sorted = callLoudness.sorted()
        loudThreshold = sorted.isEmpty ? 0 : sorted[Int(Float(sorted.count - 1) * 0.6)]
        self.threshold = threshold
    }

    /// The call audio between these times (seconds) repeats your mic from a moment before.
    public func isCopyOfMic(start: Double, end: Double) -> Bool {
        score(start: start, end: end) >= threshold && harmonicScore(start: start, end: end) >= 0.12
    }

    /// The same comparison on harmonic detail: the log spectrum (31 Hz bins) minus its smooth outline.
    public func harmonicScore(start: Double, end: Double) -> Float {
        let rate = 16_000.0, look = 3.0
        let from = max(0, Int((start - look) * rate)), to = min(callSamples.count, micSamples.count, Int(end * rate))
        guard to - from > Int(look * rate) else { return 0 }
        let width = Self.fineBins
        let micFine = Self.spectrum(Array(micSamples[from..<to]), fine: true)
        let callFine = Self.spectrum(Array(callSamples[from..<to]), fine: true)
        let frames = min(micFine.count, callFine.count) / width
        let segStart = Int((start - Double(from) / rate) * 100), segEnd = frames
        guard segEnd - segStart >= 80 else { return 0 }
        let n = segEnd - segStart
        var y = Array(callFine[(segStart * width)..<(segEnd * width)])
        Self.center(&y, rows: n, width: width)
        let yy = y.reduce(0) { $0 + $1 * $1 }
        var best: Float = 0
        for lag in stride(from: 10, to: 300, by: 2) where segStart - lag >= 0 {
            var x = Array(micFine[((segStart - lag) * width)..<((segEnd - lag) * width)])
            Self.center(&x, rows: n, width: width)
            var xy: Float = 0, xx: Float = 0
            vDSP_dotpr(x, 1, y, 1, &xy, vDSP_Length(x.count))
            vDSP_dotpr(x, 1, x, 1, &xx, vDSP_Length(x.count))
            best = max(best, xy / ((xx * yy).squareRoot() + 1e-9))
        }
        return best
    }

    private static func center(_ m: inout [Float], rows: Int, width: Int) {
        for k in 0..<width {
            var sum: Float = 0
            for r in 0..<rows { sum += m[r * width + k] }
            let mean = sum / Float(rows)
            for r in 0..<rows { m[r * width + k] -= mean }
        }
    }

    public func score(start: Double, end: Double) -> Float {
        let b = Self.bands
        let first = max(0, Int(start * 100)), last = min(callLoudness.count, mic.count / b, Int(end * 100))
        let loud = (first..<max(first, last)).filter { callLoudness[$0] > loudThreshold }
        // Under 0.8 s of sound, some offset matches by chance (in testing "Perfect." scored 0.58), so short
        // stretches are never judged copies.
        guard loud.count >= 80 else { return 0 }
        // The call frames, centred per band.
        var y = [Float](repeating: 0, count: loud.count * b)
        var mean = [Float](repeating: 0, count: b)
        for (i, f) in loud.enumerated() { for k in 0..<b { y[i * b + k] = call[f * b + k]; mean[k] += call[f * b + k] } }
        for k in 0..<b { mean[k] /= Float(loud.count) }
        for i in 0..<loud.count { for k in 0..<b { y[i * b + k] -= mean[k] } }
        let yy = y.reduce(0) { $0 + $1 * $1 }
        var best: Float = 0
        var x = [Float](repeating: 0, count: y.count)
        for lag in stride(from: 10, to: 300, by: 2) {
            guard loud[0] - lag >= 0 else { break }
            var m = [Float](repeating: 0, count: b)
            for (i, f) in loud.enumerated() { for k in 0..<b { x[i * b + k] = mic[(f - lag) * b + k]; m[k] += x[i * b + k] } }
            for k in 0..<b { m[k] /= Float(loud.count) }
            var xy: Float = 0, xx: Float = 0
            for i in 0..<loud.count {
                for k in 0..<b {
                    let v = x[i * b + k] - m[k]
                    xy += v * y[i * b + k]
                    xx += v * v
                }
            }
            best = max(best, xy / ((xx * yy).squareRoot() + 1e-9))
        }
        return best
    }

    static let fineBins = 138

    /// Log magnitude in 23 bands from 200 Hz to 4.8 kHz, every 10 ms (16 kHz audio). `fine`: the 138 single
    /// bins instead, minus a 7-bin moving average (what's left is the harmonics).
    static func spectrum(_ samples: [Float], fine: Bool = false) -> [Float] {
        guard samples.count > window, let fft = vDSP.FFT(log2n: 9, radix: .radix2, ofType: DSPSplitComplex.self) else { return [] }
        let hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: window, isHalfWindow: false)
        let frames = (samples.count - window) / hop
        let width = fine ? fineBins : bands
        var out = [Float](repeating: 0, count: frames * width)
        var bins = [Float](repeating: 0, count: fineBins)
        var real = [Float](repeating: 0, count: fftSize / 2), imag = [Float](repeating: 0, count: fftSize / 2)
        var padded = [Float](repeating: 0, count: fftSize)
        let lowBin = 6, binsPerBand = 6   // 31.25 Hz bins: 187 Hz … 4.5 kHz
        for f in 0..<frames {
            let start = f * hop
            for i in 0..<window { padded[i] = samples[start + i] * hann[i] }
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                    padded.withUnsafeBufferPointer { p in
                        p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                    }
                    fft.forward(input: split, output: &split)
                }
            }
            if fine {
                for k in 0..<fineBins {
                    let bin = lowBin + k
                    bins[k] = log((real[bin] * real[bin] + imag[bin] * imag[bin]).squareRoot() + 1e-3)
                }
                for k in 0..<fineBins {
                    let lo = max(0, k - 3), hi = min(fineBins - 1, k + 3)
                    var sum: Float = 0
                    for j in lo...hi { sum += bins[j] }
                    out[f * width + k] = bins[k] - sum / Float(hi - lo + 1)
                }
                continue
            }
            for band in 0..<bands {
                var sum: Float = 0
                for k in 0..<binsPerBand {
                    let bin = lowBin + band * binsPerBand + k
                    sum += (real[bin] * real[bin] + imag[bin] * imag[bin]).squareRoot()
                }
                out[f * bands + band] = log(sum / Float(binsPerBand) + 1e-3)
            }
        }
        return out
    }
}
