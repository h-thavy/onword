import AVFoundation
import OnwordCore
import os

/// A meeting's audio on disk. While recording and processing it's two raw 16 kHz tracks (mic.caf, system.caf);
/// once the notes are written they're compressed into one AAC file, recording.m4a, with you on the left
/// channel and the call on the right (about 30 MB an hour instead of about 460 MB). Re-processing and Resume
/// read the channels back.
enum MeetingAudio {
    private static let log = Logger(subsystem: "io.github.h-thavy.onword", category: "meetings")
    static let sampleRate = Resampler.sampleRate

    static func recordingURL(_ meeting: Meeting) -> URL { meeting.folder.appendingPathComponent("recording.m4a") }

    /// Both tracks as 16 kHz mono samples, from the raw tracks or else the compressed recording beside them.
    static func load(micURL: URL, systemURL: URL) -> (mic: [Float], system: [Float]) {
        let fm = FileManager.default
        if fm.fileExists(atPath: micURL.path) || fm.fileExists(atPath: systemURL.path) {
            return ((try? AudioFileWriter.read(micURL)) ?? [], (try? AudioFileWriter.read(systemURL)) ?? [])
        }
        return readRecording(micURL.deletingLastPathComponent().appendingPathComponent("recording.m4a")) ?? ([], [])
    }

    /// Writes recording.m4a from the raw tracks and deletes them. Keeps the raw tracks if anything fails.
    @discardableResult
    static func compress(_ meeting: Meeting) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: meeting.micURL.path) || fm.fileExists(atPath: meeting.systemURL.path) else { return false }
        let mic = (try? AudioFileWriter.read(meeting.micURL)) ?? []
        let system = (try? AudioFileWriter.read(meeting.systemURL)) ?? []
        guard !mic.isEmpty || !system.isEmpty else { return false }
        let url = recordingURL(meeting)
        let temp = url.deletingLastPathComponent().appendingPathComponent("recording-writing.m4a")
        try? fm.removeItem(at: temp)
        do {
            try write(left: mic, right: system, to: temp)
            // Check it reads back before deleting the originals.
            guard let back = readRecording(temp), abs(back.mic.count - max(mic.count, system.count)) < Int(sampleRate) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try? fm.removeItem(at: url)
            try fm.moveItem(at: temp, to: url)
            try? fm.removeItem(at: meeting.micURL)
            try? fm.removeItem(at: meeting.systemURL)
            log.notice("Compressed meeting audio to recording.m4a (\(attributes(url)) bytes)")
            return true
        } catch {
            try? fm.removeItem(at: temp)
            log.error("Couldn't compress meeting audio: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Puts the raw tracks back from recording.m4a (before resuming a finished meeting).
    static func restoreTracks(_ meeting: Meeting) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: meeting.micURL.path), let tracks = readRecording(recordingURL(meeting)) else { return }
        if let writer = try? AudioFileWriter(url: meeting.micURL) { writer.append(tracks.mic) }
        if !tracks.system.isEmpty, let writer = try? AudioFileWriter(url: meeting.systemURL) { writer.append(tracks.system) }
        try? fm.removeItem(at: recordingURL(meeting))
    }

    /// Compresses finished meetings recorded before recordings were compressed, one at a time in the background.
    @MainActor
    static func compressOldRecordings() {
        let pending = MeetingStore.shared.meetings.filter {
            ($0.status == .ready || $0.status == .failed) && MeetingRecorder.shared.currentID != $0.id
                && FileManager.default.fileExists(atPath: $0.micURL.path)
        }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .background) {
            for meeting in pending { compress(meeting) }
        }
    }

    // MARK: - AAC

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

    /// Left/right channels at 16 kHz (a mono file is all "mic").
    private static func readRecording(_ url: URL) -> (mic: [Float], system: [Float])? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { return nil }
        let n = Int(buffer.frameLength)
        func channel(_ i: Int) -> [Float] {
            let samples = Array(UnsafeBufferPointer(start: data[i], count: n))
            guard file.processingFormat.sampleRate != sampleRate else { return samples }
            // Resample one channel through a mono buffer.
            guard let mono = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 1),
                  let single = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(n)) else { return samples }
            single.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { single.floatChannelData![0].update(from: $0.baseAddress!, count: n) }
            return Resampler(from: mono)?.convert(single) ?? samples
        }
        let mic = channel(0)
        let system = file.processingFormat.channelCount > 1 ? channel(1) : []
        return (mic, system)
    }

    private static func attributes(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
