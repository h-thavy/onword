import AVFoundation
import OnwordCore
import os

/// A meeting's audio on disk. While recording it's two raw 16 kHz tracks for transcription (mic.caf,
/// system.caf) and the same two at listening quality, 48 kHz AAC (mic-hq.caf, system-hq.caf). Once the
/// notes are written they become two files:
/// - recording.m4a, to listen to and share: you and the call mixed, mono, so it plays in both ears;
/// - tracks.m4a, for Onword: 48 kHz stereo, you on the left and the call on the right, which Re-process and
///   Resume read back.
/// About 85 MB an hour together. (Earlier versions saved only the left/right file, as recording.m4a; those are
/// converted in the background.)
enum MeetingAudio {
    private static let log = Logger(subsystem: "io.github.h-thavy.onword", category: "meetings")
    static let sampleRate = Resampler.sampleRate

    static func recordingURL(_ meeting: Meeting) -> URL { meeting.folder.appendingPathComponent("recording.m4a") }
    static func tracksURL(_ meeting: Meeting) -> URL { meeting.folder.appendingPathComponent("tracks.m4a") }

    /// Both tracks as 16 kHz mono samples, from the raw tracks or else the compressed recording beside them.
    static func load(micURL: URL, systemURL: URL) -> (mic: [Float], system: [Float]) {
        let fm = FileManager.default
        if fm.fileExists(atPath: micURL.path) || fm.fileExists(atPath: systemURL.path) {
            return ((try? AudioFileWriter.read(micURL)) ?? [], (try? AudioFileWriter.read(systemURL)) ?? [])
        }
        let folder = micURL.deletingLastPathComponent()
        let tracks = folder.appendingPathComponent("tracks.m4a")
        return readRecording(fm.fileExists(atPath: tracks.path) ? tracks : folder.appendingPathComponent("recording.m4a")) ?? ([], [])
    }

    /// Writes recording.m4a and deletes the separate tracks. Keeps them if anything fails.
    @discardableResult
    static func compress(_ meeting: Meeting) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: meeting.micURL.path) || fm.fileExists(atPath: meeting.systemURL.path) else { return false }
        let mic = (try? AudioFileWriter.read(meeting.micURL)) ?? []
        var system = (try? AudioFileWriter.read(meeting.systemURL)) ?? []
        guard !mic.isEmpty || !system.isEmpty else { return false }
        let muted = returnedVoice(mic: mic, system: system)
        let url = recordingURL(meeting), tracksURL = tracksURL(meeting)
        let temp = url.deletingLastPathComponent().appendingPathComponent("tracks-writing.m4a")
        let mixTemp = url.deletingLastPathComponent().appendingPathComponent("recording-writing.m4a")
        try? fm.removeItem(at: temp)
        try? fm.removeItem(at: mixTemp)
        let listening = [meeting.micHQURL, meeting.systemHQURL].filter { fm.fileExists(atPath: $0.path) }
        let expected = Double(max(mic.count, system.count)) / sampleRate
        // It must read back about as long as the meeting before the tracks are deleted.
        func readsBack(_ file: URL = temp) -> Bool {
            guard let file = try? AVAudioFile(forReading: file) else { return false }
            return abs(Double(file.length) / file.processingFormat.sampleRate - expected) < 1.5
        }
        var usedListening = !listening.isEmpty
        do {
            if usedListening {
                // Listening copies cut off by a quit or crash can be unreadable or short: then use the 16 kHz tracks.
                if (try? writeListening(mic: meeting.micHQURL, system: meeting.systemHQURL, muting: muted, to: temp)) == nil || !readsBack() {
                    log.notice("Listening-quality tracks incomplete; saving the 16 kHz tracks instead")
                    try? fm.removeItem(at: temp)
                    usedListening = false
                }
            }
            if !usedListening {
                mute(&system, rate: sampleRate, spans: muted)
                try write(left: mic, right: system, to: temp)
            }
            guard readsBack() else { throw CocoaError(.fileWriteUnknown) }
            try writeMix(from: temp, to: mixTemp)
            guard readsBack(mixTemp) else { throw CocoaError(.fileWriteUnknown) }
            try? fm.removeItem(at: tracksURL)
            try fm.moveItem(at: temp, to: tracksURL)
            try? fm.removeItem(at: url)
            try fm.moveItem(at: mixTemp, to: url)
            for track in [meeting.micURL, meeting.systemURL, meeting.micHQURL, meeting.systemHQURL] { try? fm.removeItem(at: track) }
            log.notice("Saved meeting audio (\(usedListening ? "48" : "16", privacy: .public) kHz): recording.m4a \(attributes(url)) bytes, tracks.m4a \(attributes(tracksURL)) bytes")
            return true
        } catch {
            try? fm.removeItem(at: temp)
            try? fm.removeItem(at: mixTemp)
            log.error("Couldn't compress meeting audio: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Puts the tracks back from tracks.m4a (or an older recording.m4a) before resuming a finished meeting:
    /// the 16 kHz ones for transcription and the 48 kHz ones for listening.
    static func restoreTracks(_ meeting: Meeting) {
        let fm = FileManager.default
        let tracks = tracksURL(meeting)
        let recording = fm.fileExists(atPath: tracks.path) ? tracks : recordingURL(meeting)
        guard !fm.fileExists(atPath: meeting.micURL.path), fm.fileExists(atPath: recording.path) else { return }
        let mic = try? AudioFileWriter(url: meeting.micURL), system = try? AudioFileWriter(url: meeting.systemURL)
        let micHigh = try? HighQualityWriter(url: meeting.micHQURL), systemHigh = try? HighQualityWriter(url: meeting.systemHQURL)
        let ok = readChannels(recording, rate: sampleRate) { left, right in
            mic?.append(left)
            system?.append(right)
        } && readChannels(recording, rate: HighQualityWriter.sampleRate) { left, right in
            micHigh?.append(left)
            systemHigh?.append(right)
        }
        if ok {
            try? fm.removeItem(at: tracks)
            try? fm.removeItem(at: recordingURL(meeting))
        }
    }

    /// After a resumed part: adds its listening-quality track to the meeting's (re-encoding both into one file).
    static func appendListeningPart(_ part: URL, to track: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: part.path) else { return }
        guard fm.fileExists(atPath: track.path) else { try? fm.moveItem(at: part, to: track); return }
        let temp = track.deletingLastPathComponent().appendingPathComponent("joining-" + track.lastPathComponent)
        try? fm.removeItem(at: temp)
        // The writer must be gone (file finished) before the file is moved into place.
        func join() -> Bool {
            guard let writer = try? HighQualityWriter(url: temp) else { return false }
            return readChannels(track, rate: HighQualityWriter.sampleRate) { left, _ in writer.append(left) }
                && readChannels(part, rate: HighQualityWriter.sampleRate) { left, _ in writer.append(left) }
        }
        guard join() else { try? fm.removeItem(at: temp); return }
        try? fm.removeItem(at: track)
        try? fm.moveItem(at: temp, to: track)
        try? fm.removeItem(at: part)
    }

    /// In the background, one at a time: compresses finished meetings still in raw tracks, and gives recordings
    /// saved as left/right only (before tracks.m4a) their two-ear mix.
    @MainActor
    static func compressOldRecordings() {
        let fm = FileManager.default
        let finished = MeetingStore.shared.meetings.filter {
            ($0.status == .ready || $0.status == .failed) && MeetingRecorder.shared.currentID != $0.id
        }
        let pending = finished.filter { fm.fileExists(atPath: $0.micURL.path) }
        let unmixed = finished.filter {
            !fm.fileExists(atPath: $0.micURL.path) && !fm.fileExists(atPath: tracksURL($0).path)
                && fm.fileExists(atPath: recordingURL($0).path)
        }
        guard !pending.isEmpty || !unmixed.isEmpty else { return }
        Task.detached(priority: .background) {
            for meeting in pending { compress(meeting) }
            for meeting in unmixed { addMix(meeting) }
        }
    }

    /// An older recording.m4a (you left, the call right) becomes tracks.m4a, and recording.m4a the two-ear mix.
    @discardableResult
    static func addMix(_ meeting: Meeting) -> Bool {
        let fm = FileManager.default
        let url = recordingURL(meeting), tracks = tracksURL(meeting)
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.channelCount == 2 else { return false }
        let expected = Double(file.length) / file.processingFormat.sampleRate
        let mixTemp = url.deletingLastPathComponent().appendingPathComponent("recording-writing.m4a")
        try? fm.removeItem(at: mixTemp)
        do {
            try writeMix(from: url, to: mixTemp)
            guard let mixed = try? AVAudioFile(forReading: mixTemp),
                  abs(Double(mixed.length) / mixed.processingFormat.sampleRate - expected) < 1.5 else { throw CocoaError(.fileWriteUnknown) }
            try fm.moveItem(at: url, to: tracks)
            try fm.moveItem(at: mixTemp, to: url)
            log.notice("Added a two-ear mix to an older recording (\(Int(expected)) s)")
            return true
        } catch {
            try? fm.removeItem(at: mixTemp)
            log.error("Couldn't mix an older recording: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The listening file: both channels of a you/call file mixed into one, mono AAC (plays in both ears),
    /// at the file's own rate.
    private static func writeMix(from tracks: URL, to url: URL) throws {
        let rate = try AVAudioFile(forReading: tracks).processingFormat.sampleRate
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: rate >= 44_100 ? 96_000 : 48_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        else { throw CocoaError(.fileWriteUnknown) }
        var failure: Error?
        let ok = readChannels(tracks, rate: rate) { left, right in
            guard failure == nil else { return }
            let n = max(left.count, right.count)
            guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
            buffer.frameLength = AVAudioFrameCount(n)
            let out = buffer.floatChannelData![0]
            for i in 0..<n {
                let sum = (i < left.count ? left[i] : 0) + (i < right.count ? right[i] : 0)
                // Soft limit when both speak at once.
                let size = abs(sum)
                out[i] = size <= 0.9 ? sum : (sum < 0 ? -1 : 1) * (0.9 + 0.1 * tanh((size - 0.9) / 0.1))
            }
            do { try file.write(from: buffer) } catch { failure = error }
        }
        if let failure { throw failure }
        guard ok else { throw CocoaError(.fileReadCorruptFile) }
    }

    // MARK: - Your voice coming back through the call

    /// Where the call track is your own voice coming back a moment later (the call also open on a device near
    /// you), in seconds, so the recording doesn't have you twice.
    private static func returnedVoice(mic: [Float], system: [Float]) -> [Range<Double>] {
        guard !mic.isEmpty, !system.isEmpty else { return [] }
        let detector = DelayedCopyDetector(mic: mic, system: system)
        if ProcessInfo.processInfo.environment["ONWORD_DEBUG_COPY"] != nil {
            for span in SpeechSpans.find(system) {
                let a = Double(span.lowerBound) / sampleRate, b = Double(span.upperBound) / sampleRate
                log.notice("Span copy score \(detector.score(start: a, end: b), format: .fixed(precision: 2)) harmonic \(detector.harmonicScore(start: a, end: b), format: .fixed(precision: 2)) at \(a, format: .fixed(precision: 1))–\(b, format: .fixed(precision: 1))")
            }
        }
        let spans = SpeechSpans.find(system)
            .map { Double($0.lowerBound) / sampleRate..<Double($0.upperBound) / sampleRate }
            .filter { detector.isCopyOfMic(start: $0.lowerBound, end: $0.upperBound) }
        let muted = spans.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        if muted > 0 { log.notice("Muted \(muted, format: .fixed(precision: 1)) s of your own voice coming back through the call") }
        return spans
    }

    /// Silences `spans` (seconds) in samples at `rate`, starting at `offset` samples, with 10 ms fades.
    private static func mute(_ samples: inout [Float], rate: Double, spans: [Range<Double>], offset: Int = 0) {
        let fade = Int(rate * 0.01)
        for span in spans {
            let first = Int(span.lowerBound * rate), last = Int(span.upperBound * rate)
            let from = max(first, offset), to = min(last, offset + samples.count)
            guard from < to else { continue }
            for i in from..<to {
                let edge = min(i - first, last - 1 - i)
                samples[i - offset] *= edge < fade ? 1 - Float(edge) / Float(fade) : 0
            }
        }
    }

    // MARK: - Writing

    /// recording.m4a from the listening-quality tracks, in 10-second pieces (an hour is too big to hold).
    private static func writeListening(mic: URL, system: URL, muting: [Range<Double>], to url: URL) throws {
        let micFile = try? AVAudioFile(forReading: mic), systemFile = try? AVAudioFile(forReading: system)
        let stereo = micFile != nil && systemFile != nil
        let rate = HighQualityWriter.sampleRate
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: stereo ? 2 : 1, AVEncoderBitRateKey: stereo ? 160_000 : 96_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = AVAudioFrameCount(rate * 10)
        guard let left = AVAudioPCMBuffer(pcmFormat: HighQualityWriter.format, frameCapacity: chunk),
              let right = AVAudioPCMBuffer(pcmFormat: HighQualityWriter.format, frameCapacity: chunk),
              let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { throw CocoaError(.fileWriteUnknown) }
        var position = 0
        while true {
            let a = read(micFile, into: left, count: chunk), b = read(systemFile, into: right, count: chunk)
            let n = max(a, b)
            guard n > 0 else { break }
            var call = Array(UnsafeBufferPointer(start: right.floatChannelData![0], count: n))
            if b < n { for i in b..<n { call[i] = 0 } }
            mute(&call, rate: rate, spans: muting, offset: position)
            out.frameLength = AVAudioFrameCount(n)
            let channels = stereo ? [(left, a, false), (right, n, true)] : [(micFile != nil ? left : right, n, micFile == nil)]
            for (index, (source, valid, isCall)) in channels.enumerated() {
                let destination = out.floatChannelData![index]
                for i in 0..<n {
                    destination[i] = isCall ? call[i] : (i < valid ? source.floatChannelData![0][i] : 0)
                }
            }
            try file.write(from: out)
            position += n
        }
    }

    /// Reads up to `count` frames (fewer at the end, 0 when done or there's no file).
    private static func read(_ file: AVAudioFile?, into buffer: AVAudioPCMBuffer, count: AVAudioFrameCount) -> Int {
        guard let file, file.framePosition < file.length else { buffer.frameLength = 0; return 0 }
        do { try file.read(into: buffer, frameCount: count) } catch { buffer.frameLength = 0 }
        return Int(buffer.frameLength)
    }

    /// The 16 kHz version (older meetings, or when the listening copies are missing).
    private static func write(left: [Float], right: [Float], to url: URL) throws {
        let stereo = !right.isEmpty && !left.isEmpty
        let channels: AVAudioChannelCount = stereo ? 2 : 1
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: stereo ? 64_000 : 40_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let total = max(left.count, right.count)
        let chunk = 16_384
        var offset = 0
        while offset < total {
            let count = min(chunk, total - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            let sources = stereo ? [left, right] : [left.isEmpty ? right : left]
            for (channel, source) in sources.enumerated() {
                let destination = buffer.floatChannelData![channel]
                for i in 0..<count { destination[i] = offset + i < source.count ? source[offset + i] : 0 }
            }
            try file.write(from: buffer)
            offset += count
        }
    }

    // MARK: - Reading

    /// Left/right channels at 16 kHz (a mono file is all "mic").
    private static func readRecording(_ url: URL) -> (mic: [Float], system: [Float])? {
        var mic: [Float] = [], system: [Float] = []
        guard readChannels(url, rate: sampleRate, { left, right in
            mic.append(contentsOf: left)
            system.append(contentsOf: right)
        }) else { return nil }
        return (mic, system)
    }

    /// Streams a file's left and right channels (right is empty for a mono file), converted to `rate`, in
    /// 10-second pieces. False if it can't be read.
    private static func readChannels(_ url: URL, rate: Double, _ body: ([Float], [Float]) -> Void) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let format = file.processingFormat
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)
        else { return false }
        let chunk = AVAudioFrameCount(format.sampleRate * 10)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let single = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: chunk) else { return false }
        let channels = min(2, Int(format.channelCount))
        let converters = (0..<channels).map { _ in format.sampleRate == rate ? nil : Resampler(from: mono, to: rate) }
        while file.framePosition < file.length {
            guard (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
            let n = Int(buffer.frameLength)
            var out: [[Float]] = []
            for c in 0..<channels {
                let samples = buffer.floatChannelData![c]
                if let converter = converters[c] {
                    single.frameLength = buffer.frameLength
                    single.floatChannelData![0].update(from: samples, count: n)
                    out.append(converter.convert(single))
                } else {
                    out.append(Array(UnsafeBufferPointer(start: samples, count: n)))
                }
            }
            body(out[0], channels > 1 ? out[1] : [])
        }
        return true
    }

    private static func attributes(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
