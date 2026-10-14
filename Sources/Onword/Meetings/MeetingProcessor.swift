import Foundation
import OnwordCore
import SpeakerKit
import WhisperKit
import os

/// Turns a meeting's two audio tracks into a speaker-tagged transcript, entirely on this Mac.
///
///   mic.caf    → Whisper                         → segments tagged "me"
///   system.caf → Whisper + SpeakerKit diarization → segments tagged "s1", "s2", …
///   → drop mic segments that are just the call echoing through your speakers
///   → interleave by time
///
/// With no system audio (an in-person meeting), the mic track is diarized instead.
actor MeetingProcessor {
    static let shared = MeetingProcessor()
    /// One Whisper instance for meetings (live and final), separate from dictation's so neither waits.
    static let transcriber = Transcriber()

    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "meetings")
    private var speakerKit: SpeakerKit?

    /// Below this loudness a track is treated as silent.
    private let silenceRMS: Float = 0.003

    /// Returns the transcript and names for diarized speakers read from the call app ("s1" → "Samantha").
    func process(micURL: URL, systemURL: URL, speakersURL: URL, model: Transcriber.Model, language: String?,
                 replacements: [String: String],
                 progress: @Sendable (String) async -> Void) async throws -> ([TranscriptSegment], [String: String]) {
        let segments = try await transcribe(micURL: micURL, systemURL: systemURL, model: model, language: language,
                                            replacements: replacements, progress: progress)
        let observations = Self.loadObservations(speakersURL)
        let names = SpeakerNames.assign(segments: segments, observations: observations)
        log.notice("Speaker names from call app: \(names.count) of \(Set(segments.map(\.speaker)).subtracting(["me"]).count) speaker(s), \(observations.count) observation(s)")
        return (segments, names)
    }

    static func loadObservations(_ url: URL) -> [SpeakerObservation] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(SpeakerObservation.self, from: Data($0.utf8)) }
    }

    private func transcribe(micURL: URL, systemURL: URL, model: Transcriber.Model, language: String?, replacements: [String: String],
                            progress: @Sendable (String) async -> Void) async throws -> [TranscriptSegment] {
        let mic = (try? AudioFileWriter.read(micURL)) ?? []
        let system = (try? AudioFileWriter.read(systemURL)) ?? []
        let micHasSpeech = Resampler.rms(mic) >= silenceRMS
        let systemHasSpeech = Resampler.rms(system) >= silenceRMS
        let micSeconds = mic.count / 16_000, systemSeconds = system.count / 16_000
        log.notice("Processing meeting: mic \(micSeconds) s, system \(systemSeconds) s")

        let transcriber = Self.transcriber
        await progress("Loading speech model…")
        try await transcriber.load(model, downloadBase: AppPaths.models)

        if systemHasSpeech {
            await progress("Transcribing the other speakers…")
            let others = withoutHallucinations(try await transcriber.transcribeLong(system, language: language))
            await progress("Identifying speakers…")
            let tagged = try await diarize(system, transcription: others)

            var mine: [TranscriptSegment] = []
            if micHasSpeech {
                await progress("Transcribing your microphone…")
                mine = segments(from: withoutHallucinations(try await transcriber.transcribeLong(mic, language: language)), speaker: "me")
                let before = mine.count
                mine = TranscriptMerger.removeEcho(me: mine, others: tagged)
                log.notice("Mic: \(mine.count) segment(s) kept, \(before - mine.count) dropped as echo")
            }
            let merged = applyDictionary(TranscriptMerger.merge([mine, tagged]), replacements)
            log.notice("Transcript: \(merged.count) turn(s), speakers \(Set(merged.map(\.speaker)).sorted().joined(separator: ","), privacy: .public)")
            return merged
        }

        guard micHasSpeech else { return [] }
        // In-person meeting: everyone is on the microphone, so diarize that.
        await progress("Transcribing…")
        let all = withoutHallucinations(try await transcriber.transcribeLong(mic, language: language))
        await progress("Identifying speakers…")
        return applyDictionary(TranscriptMerger.merge([try await diarize(mic, transcription: all)]), replacements)
    }

    /// Final pass: strips Whisper artifacts like "[BLANK_AUDIO]" and applies dictionary replacements
    /// ("flow light" → "Onword"). Fillers are kept in transcripts. Drops segments left empty.
    private func applyDictionary(_ segments: [TranscriptSegment], _ replacements: [String: String]) -> [TranscriptSegment] {
        let cleaner = TextCleaner(removeFillers: false, smartSpacing: false, replacements: replacements)
        return segments
            .map { var s = $0; s.text = cleaner.clean(s.text); return s }
            .filter { !$0.text.isEmpty }
    }

    private func diarize(_ samples: [Float], transcription: [TranscriptionResult]) async throws -> [TranscriptSegment] {
        if speakerKit == nil {
            let config = PyannoteConfig(
                downloadBase: AppPaths.models.path, download: true, load: true, verbose: false)
            speakerKit = try await SpeakerKit(config)
        }
        guard let speakerKit else { return [] }
        let diarization = try await speakerKit.diarize(audioArray: samples)
        log.notice("Diarization found \(diarization.speakerCount) speaker(s)")

        let tagged = diarization.addSpeakerInfo(to: transcription).flatMap { $0 }.map { segment in
            let id = segment.speaker.speakerId ?? segment.speaker.speakerIds.first
            return TranscriptSegment(
                start: Double(segment.startTime), end: Double(segment.endTime),
                speaker: id.map { "s\($0 + 1)" } ?? "unknown", text: segment.text)
        }
        return TranscriptMerger.dropHallucinations(tagged)
    }

    /// Removes Whisper's stock silence outputs ("you", "Thank you.") at the raw-segment level, before
    /// speaker alignment can glue them onto a real sentence.
    private func withoutHallucinations(_ results: [TranscriptionResult]) -> [TranscriptionResult] {
        for result in results {
            result.segments.removeAll { $0.end - $0.start <= 1.5 && TextCleaner.isLikelyHallucination($0.text) }
        }
        return results
    }

    private func segments(from results: [TranscriptionResult], speaker: String) -> [TranscriptSegment] {
        TranscriptMerger.dropHallucinations(results.flatMap(\.segments).map {
            TranscriptSegment(start: Double($0.start), end: Double($0.end), speaker: speaker, text: $0.text)
        })
    }
}
