import Foundation
import OnwordCore
import os

/// Audio waiting to be transcribed live, filled from an audio thread.
final class LiveTrackBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Float] = []
    private var consumedSamples = 0

    func append(_ samples: [Float]) {
        lock.withLock { pending.append(contentsOf: samples) }
    }

    /// Takes the next chunk (≥ 8 s, cut at a pause) and its start time in the recording.
    func takeChunk() -> (samples: [Float], start: Double)? {
        lock.withLock {
            guard let cut = SilenceCut.index(in: pending) else { return nil }
            let chunk = Array(pending[..<cut])
            pending.removeFirst(cut)
            let start = Double(consumedSamples) / Resampler.sampleRate
            consumedSamples += cut
            return (chunk, start)
        }
    }
}

/// Shows a rough transcript while the meeting is still going: your mic is
/// "You"; the call is labelled with whoever the call app shows as speaking, or "Them". The accurate,
/// diarized transcript replaces it after the meeting.
@MainActor
final class LiveTranscriber {
    let mic = LiveTrackBuffer()
    let system = LiveTrackBuffer()

    /// Called on the main actor with the live transcript so far.
    var onUpdate: (([TranscriptSegment]) -> Void)?
    /// Who the call app showed as speaking at a moment (seconds into the recording).
    var speakerAt: ((Double) -> String?)?

    private var segments: [TranscriptSegment] = []
    private var queue: [(track: String, samples: [Float], start: Double)] = []
    private var busy = false
    private var timer: Timer?
    private var model: Transcriber.Model = .smallEnglish
    private var language: String?
    /// Your languages, when there are several: each chunk is transcribed in the one most likely spoken.
    private var languages: [String] = []
    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "live")

    func start(model: Transcriber.Model, language: String?, languages: [String] = []) {
        self.model = model
        self.language = language
        self.languages = languages
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.collect() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        queue.removeAll()
    }

    private func collect() {
        if let chunk = mic.takeChunk() { queue.append(("me", chunk.samples, chunk.start)) }
        if let chunk = system.takeChunk() { queue.append(("them", chunk.samples, chunk.start)) }
        processNext()
    }

    private func processNext() {
        guard !busy, !queue.isEmpty, timer != nil else { return }
        let job = queue.removeFirst()
        guard Resampler.rms(job.samples) >= 0.003 else { return processNext() }
        busy = true
        let model = model, language = language, languages = languages
        Task {
            defer {
                busy = false
                processNext()
            }
            do {
                let transcriber = MeetingProcessor.transcriber
                try await transcriber.load(model, downloadBase: AppPaths.models)
                let spoken: String? = if language == nil {
                    await transcriber.detectLanguage(job.samples, among: languages)
                } else { language }
                let results = try await transcriber.transcribeLong(job.samples, language: spoken)
                add(results.flatMap(\.segments).map {
                    TranscriptSegment(start: job.start + Double($0.start), end: job.start + Double($0.end),
                                      speaker: job.track, text: $0.text)
                })
            } catch {
                log.error("Live transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func add(_ new: [TranscriptSegment]) {
        let cleaner = TextCleaner(removeFillers: false, smartSpacing: false)
        var batch = TranscriptMerger.dropHallucinations(new)
            .map { segment -> TranscriptSegment in
                var s = segment
                s.text = TranscriptMerger.tidySpacing(cleaner.clean(ScriptFilter.clean(s.text, languages: languages)))
                if s.speaker == "them" { s.speaker = speakerAt?((s.start + s.end) / 2) ?? "Them" } else { s.speaker = "You" }
                return s
            }
            .filter { !$0.text.isEmpty }
        // Without headphones the mic hears the call too; drop those copies.
        let mine = batch.filter { $0.speaker == "You" }
        let theirs = (segments + batch).filter { $0.speaker != "You" }
        let keptMine = TranscriptMerger.removeEcho(me: mine, others: theirs)
        batch = batch.filter { $0.speaker != "You" } + keptMine
        segments = TranscriptMerger.merge([segments, batch])
        onUpdate?(segments)
    }
}
