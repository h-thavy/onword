import AppKit
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
    private var expectedOthers: Int?
    /// Attendees and dictionary words, to correct misheard names.
    private var knownNames: [String] = []
    private var yourLanguages: [String] = []

    /// Below this loudness a track is treated as silent.
    private let silenceRMS: Float = 0.003

    /// Returns the transcript and names for diarized speakers read from the call app ("s1" → "Samantha").
    /// - Parameter otherPeople: how many others the calendar invited (an upper bound for the voices on the call).
    func process(micURL: URL, systemURL: URL, speakersURL: URL, model: Transcriber.Model, fallback: Transcriber.Model? = nil,
                 language: String?, languages: [String] = [],
                 replacements: [String: String], otherPeople: Int? = nil, names: [String] = [],
                 progress: @Sendable (String) async -> Void) async throws -> ([TranscriptSegment], [String: String]) {
        expectedOthers = otherPeople
        knownNames = names
        yourLanguages = languages
        let segments = try await transcribe(micURL: micURL, systemURL: systemURL, model: model, fallback: fallback, language: language,
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

    private func transcribe(micURL: URL, systemURL: URL, model: Transcriber.Model, fallback: Transcriber.Model?,
                            language: String?, replacements: [String: String],
                            progress: @Sendable (String) async -> Void) async throws -> [TranscriptSegment] {
        let mic = (try? AudioFileWriter.read(micURL)) ?? []
        let system = (try? AudioFileWriter.read(systemURL)) ?? []
        let micHasSpeech = Resampler.rms(mic) >= silenceRMS
        let systemHasSpeech = Resampler.rms(system) >= silenceRMS
        let micSeconds = mic.count / 16_000, systemSeconds = system.count / 16_000
        log.notice("Processing meeting: mic \(micSeconds) s, system \(systemSeconds) s")

        let transcriber = Self.transcriber
        await progress("Loading speech model…")
        do {
            try await transcriber.load(model, downloadBase: AppPaths.models)
        } catch {
            guard let fallback, fallback != model else { throw error }
            log.error("Meeting model \(model.rawValue, privacy: .public) unavailable (\(error.localizedDescription, privacy: .public)); using \(fallback.rawValue, privacy: .public)")
            try await transcriber.load(fallback, downloadBase: AppPaths.models)
        }

        // Each side in the language it's mostly spoken in, from your languages (you might speak Khmer while
        // the call is in English).
        let systemLanguage = language == nil ? await transcriber.detectLanguage(system, among: yourLanguages, windows: 3) : language
        let micLanguage = language == nil ? await transcriber.detectLanguage(mic, among: yourLanguages, windows: 3) : language
        if language == nil, !yourLanguages.isEmpty {
            log.notice("Languages: mic \(micLanguage ?? "auto", privacy: .public), call \(systemLanguage ?? "auto", privacy: .public)")
        }

        if systemHasSpeech {
            await progress("Transcribing the other speakers…")
            let others = withoutHallucinations(try await transcriber.transcribeLong(system, language: systemLanguage))
            await progress("Identifying speakers…")
            let tagged = try await diarize(system, transcription: others)

            var mine: [TranscriptSegment] = []
            if micHasSpeech {
                await progress("Transcribing your microphone…")
                mine = segments(from: withoutHallucinations(try await transcriber.transcribeLong(mic, language: micLanguage)), speaker: "me")
                let before = mine.count
                // The call leaking from the speakers: a faint copy of the call audio, or mostly the same words.
                mine = mine.filter { !EchoDetector.isEcho(mic: mic, system: system, start: $0.start, end: $0.end) }
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
        let all = withoutHallucinations(try await transcriber.transcribeLong(mic, language: micLanguage))
        await progress("Identifying speakers…")
        return applyDictionary(TranscriptMerger.merge([try await diarize(mic, transcription: all)]), replacements)
    }

    /// Final pass: strips Whisper artifacts like "[BLANK_AUDIO]" and applies dictionary replacements
    /// ("flow light" → "Onword"). Fillers are kept in transcripts. Drops segments left empty.
    private func applyDictionary(_ segments: [TranscriptSegment], _ replacements: [String: String]) -> [TranscriptSegment] {
        let cleaner = TextCleaner(removeFillers: false, smartSpacing: false, replacements: replacements)
        let corrector = NameCorrector(names: knownNames) { word in
            NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
        }
        return segments
            .map { var s = $0; s.text = corrector.correct(cleaner.clean(ScriptFilter.clean(s.text, languages: yourLanguages))); return s }
            .filter { !$0.text.isEmpty }
    }

    private func diarize(_ samples: [Float], transcription: [TranscriptionResult]) async throws -> [TranscriptSegment] {
        if speakerKit == nil {
            speakerKit = try await SpeakerKit(SpeakerModels.config(load: true))
        }
        guard let speakerKit else { return [] }
        let threshold = ProcessInfo.processInfo.environment["ONWORD_DIARIZE_THRESHOLD"].flatMap(Float.init)
        var diarization = try await speakerKit.diarize(audioArray: samples,
                                                       options: PyannoteDiarizationOptions(clusterDistanceThreshold: threshold))
        log.notice("Diarization found \(diarization.speakerCount) speaker(s)")
        // More voices than the people invited: one person was split in two. Cluster again with that limit.
        if let others = expectedOthers, others >= 1, diarization.speakerCount > others {
            diarization = try await speakerKit.diarize(audioArray: samples, options: PyannoteDiarizationOptions(
                numberOfSpeakers: others, clusterDistanceThreshold: threshold))
            log.notice("Re-clustered to the \(others) invited speaker(s)")
        }

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
        // Debug aid: ONWORD_DEBUG_MEETING=1 logs every raw segment with its confidence.
        if ProcessInfo.processInfo.environment["ONWORD_DEBUG_MEETING"] != nil {
            for segment in results.flatMap(\.segments) {
                log.notice("raw \(segment.start, format: .fixed(precision: 1))-\(segment.end, format: .fixed(precision: 1)) lp=\(segment.avgLogprob, format: .fixed(precision: 2)) ns=\(segment.noSpeechProb, format: .fixed(precision: 2)) cr=\(segment.compressionRatio, format: .fixed(precision: 2)) \(segment.text, privacy: .public)")
            }
        }
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

/// The speaker-separation models (about 11 MB), used to tell voices apart in meeting notes.
/// Like the speech model, they're used straight from disk once downloaded, so meetings work offline.
enum SpeakerModels {
    static var folder: URL { AppPaths.models.appending(path: "models/argmaxinc/speakerkit-coreml") }
    private static let parts = ["speaker_segmenter", "speaker_embedder", "speaker_clusterer"]

    /// All three models are fully on disk.
    static var isDownloaded: Bool {
        parts.allSatisfy { part in
            let enumerator = FileManager.default.enumerator(at: folder.appending(path: part), includingPropertiesForKeys: nil)
            return (enumerator?.allObjects as? [URL] ?? []).contains { $0.lastPathComponent == "coremldata.bin" }
        }
    }

    static func config(load: Bool) -> PyannoteConfig {
        isDownloaded
            ? PyannoteConfig(downloadBase: AppPaths.models.path, modelFolder: folder.path, download: false,
                             load: load, verbose: false)
            : PyannoteConfig(downloadBase: AppPaths.models.path, download: true, load: load, verbose: false)
    }

    /// Downloads the models if they aren't on disk yet.
    static func download() async throws {
        guard !isDownloaded else { return }
        _ = try await SpeakerKit(config(load: false))
        guard isDownloaded else { throw CocoaError(.fileReadCorruptFile) }
    }
}
