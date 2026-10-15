import AVFoundation

/// Converts live audio buffers of any format to mono Float32: 16 kHz by default (what Whisper and SpeakerKit
/// expect), or another rate (48 kHz for the meeting recording you listen to).
final class Resampler {
    static let sampleRate: Double = 16_000
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    private let converter: AVAudioConverter
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat

    init?(from inputFormat: AVAudioFormat, to rate: Double = Resampler.sampleRate) {
        guard let output = rate == Self.sampleRate ? Self.targetFormat
                : AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: output) else { return nil }
        converter.downmix = true
        self.converter = converter
        self.inputFormat = inputFormat
        outputFormat = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    static func rms(_ samples: some Collection<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
}

/// Appends 16 kHz mono samples to a CAF file as they arrive, so a crash mid-meeting loses nothing.
final class AudioFileWriter {
    let url: URL
    private let file: AVAudioFile
    private let lock = NSLock()
    private(set) var frameCount: Int64 = 0

    init(url: URL) throws {
        self.url = url
        file = try AVAudioFile(forWriting: url, settings: Resampler.targetFormat.settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Resampler.targetFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        lock.withLock {
            try? file.write(from: buffer)
            frameCount += Int64(samples.count)
        }
    }

    /// Reads a whole file back as 16 kHz mono Float32.
    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return [] }
        try file.read(into: buffer)
        if file.processingFormat == Resampler.targetFormat, let channel = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return Resampler(from: file.processingFormat)?.convert(buffer) ?? []
    }
}

/// Writes a meeting track at listening quality, 48 kHz mono AAC, as the audio arrives. The 16 kHz tracks are
/// what transcription uses; these become the recording you play back (the call as clear as you heard it).
final class HighQualityWriter {
    static let sampleRate: Double = 48_000
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private let file: AVAudioFile
    private let lock = NSLock()

    init(url: URL) throws {
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        lock.withLock { try? file.write(from: buffer) }
    }
}
