import AppKit
import OnwordCore
import os

/// Records a meeting as two separate tracks: your microphone and the Mac's audio output.
/// Keeping them separate is what makes "me vs. them" tagging reliable without any cloud service.
@MainActor
final class MeetingRecorder: ObservableObject {
    static let shared = MeetingRecorder()

    @Published private(set) var currentID: UUID?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var systemAudioWarning: String?
    /// Rough transcript while recording; replaced by the diarized one afterwards.
    @Published private(set) var liveSegments: [TranscriptSegment] = []
    /// When your microphone last picked up sound (for "Notetaker isn't hearing audio from your mic").
    private(set) var lastMicSound = Date()
    /// Called after a recording stops, before processing (the lifecycle banners hook in here).
    var onStopped: ((UUID) -> Void)?

    var isRecording: Bool { currentID != nil }

    private let mic = AudioRecorder()
    private var system: AnyObject?   // SystemAudioCapture on macOS 14.2+
    private var micWriter: AudioFileWriter?
    private var systemWriter: AudioFileWriter?
    /// The listening-quality copies (48 kHz AAC) of the two tracks.
    private var micHQWriter: HighQualityWriter?
    private var systemHQWriter: HighQualityWriter?
    private let levels = LevelBox()
    private var startedAt = Date()
    private var timer: Timer?
    private var speakerPoller: ActiveSpeakerPoller?
    private var live: LiveTranscriber?
    /// Recording into an existing note (Resume): the new audio goes to part files appended on stop.
    private var resumingDuration: TimeInterval?
    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "meetings")

    private init() {
        mic.keepsSamples = false
        mic.usesAutoDetect = true
    }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    /// - Parameters:
    ///   - title: explicit title; otherwise the calendar event happening now, otherwise the date.
    ///   - calendarMeeting: the event being recorded (defaults to whatever is on the calendar now).
    ///   - existing: record into this note: a draft opened from the calendar, or a stopped note (Resume).
    @discardableResult
    func start(title: String? = nil, calendarMeeting: UpcomingMeeting? = nil, into existing: UUID? = nil) -> UUID? {
        guard !isRecording else { return nil }
        startedAt = Date()
        resumingDuration = nil
        var meeting: Meeting
        if let existing, let found = MeetingStore.shared.meeting(existing) {
            meeting = found
            if found.status != .draft {
                // Resume: the clock and the speaker timeline continue where the last part ended. A finished
                // meeting's audio was compressed; put its tracks back so the new part can be appended.
                MeetingAudio.restoreTracks(found)
                resumingDuration = found.duration
                startedAt = Date().addingTimeInterval(-found.duration)
                meeting.resumedCount = (found.resumedCount ?? 0) + 1
            } else {
                meeting.startedAt = startedAt
            }
            meeting.status = .recording
            meeting.summaryDeferred = nil
        } else {
            let event = calendarMeeting ?? CalendarService.shared.currentMeeting()
            meeting = Meeting(title: title ?? event?.title ?? "", startedAt: startedAt)
            meeting.calendarEventID = event?.id
            meeting.attendees = event?.attendees
        }
        try? FileManager.default.createDirectory(at: meeting.folder, withIntermediateDirectories: true)
        let micURL = resumingDuration == nil ? meeting.micURL : meeting.partURL(meeting.micURL)
        let systemURL = resumingDuration == nil ? meeting.systemURL : meeting.partURL(meeting.systemURL)
        let micHQURL = resumingDuration == nil ? meeting.micHQURL : meeting.partURL(meeting.micHQURL)
        let systemHQURL = resumingDuration == nil ? meeting.systemHQURL : meeting.partURL(meeting.systemHQURL)
        lastMicSound = Date()
        let live = LiveTranscriber()
        self.live = live
        liveSegments = []
        let micBuffer = live.mic, systemBuffer = live.system

        do {
            let writer = try AudioFileWriter(url: micURL)
            micWriter = writer
            let high = try? HighQualityWriter(url: micHQURL)
            micHQWriter = high
            mic.onHighQuality = high.map { writer in { writer.append($0) } }
            let levels = levels
            mic.onSamples = { samples in
                writer.append(samples)
                micBuffer.append(samples)
                levels.mic = min(1, Resampler.rms(samples) * 8)
            }
            try mic.start()
        } catch {
            log.error("Meeting mic failed: \(error.localizedDescription)")
            NSSound.beep()
            if existing == nil { try? FileManager.default.removeItem(at: meeting.folder) }
            return nil
        }

        systemAudioWarning = nil
        if #available(macOS 14.2, *) {
            do {
                let writer = try AudioFileWriter(url: systemURL)
                let capture = SystemAudioCapture()
                let high = try? HighQualityWriter(url: systemHQURL)
                systemHQWriter = high
                capture.onHighQuality = high.map { writer in { writer.append($0) } }
                let levels = levels
                capture.onSamples = { samples in
                    writer.append(samples)
                    systemBuffer.append(samples)
                    levels.system = min(1, Resampler.rms(samples) * 8)
                }
                try capture.start()
                system = capture
                systemWriter = writer
                meeting.hasSystemAudio = true
            } catch {
                systemAudioWarning = "Only your microphone is being recorded: \(error.localizedDescription)"
                log.error("System audio unavailable: \(error.localizedDescription)")
            }
        } else {
            systemAudioWarning = "Recording other apps' audio needs macOS 14.2 or later; only your microphone is recorded."
        }

        // Read speaker names from the call app, if there is one.
        if let call = MeetingDetector.shared.findMeeting() {
            meeting.platform = call.platform.rawValue
            let poller = ActiveSpeakerPoller(meeting: call, startedAt: startedAt, output: meeting.speakersURL)
            poller.start()
            speakerPoller = poller
        }

        let controller = DictationController.shared
        live.speakerAt = { [weak speakerPoller] t in speakerPoller?.speaker(at: t) }
        live.onUpdate = { [weak self] segments in self?.liveSegments = segments }
        live.start(model: controller.model, language: controller.language == "auto" ? nil : controller.language,
                   languages: controller.selectedLanguages)

        currentID = meeting.id
        MeetingStore.shared.save(meeting)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
                self.micLevel = self.levels.mic
                self.systemLevel = self.levels.system
                if self.micLevel > 0.02 { self.lastMicSound = Date() }
            }
        }
        log.notice("Meeting recording started (system audio: \(meeting.hasSystemAudio), resumed: \(self.resumingDuration != nil))")
        return meeting.id
    }

    /// Records more into a stopped note.
    func resume(_ id: UUID) {
        start(into: id)
    }

    func stop() {
        guard let id = currentID else { return }
        timer?.invalidate()
        timer = nil
        _ = mic.stop()
        mic.onSamples = nil
        if #available(macOS 14.2, *) { (system as? SystemAudioCapture)?.stop() }
        system = nil
        mic.onHighQuality = nil
        micWriter = nil      // closes the files
        systemWriter = nil
        micHQWriter = nil
        systemHQWriter = nil
        let participants = speakerPoller?.stop() ?? []
        speakerPoller = nil
        live?.stop()
        live = nil
        currentID = nil
        micLevel = 0
        systemLevel = 0

        let duration = Date().timeIntervalSince(startedAt)
        if resumingDuration != nil, let meeting = MeetingStore.shared.meeting(id) {
            Self.appendPart(meeting.partURL(meeting.micURL), to: meeting.micURL)
            Self.appendPart(meeting.partURL(meeting.systemURL), to: meeting.systemURL)
            MeetingAudio.appendListeningPart(meeting.partURL(meeting.micHQURL), to: meeting.micHQURL)
            MeetingAudio.appendListeningPart(meeting.partURL(meeting.systemHQURL), to: meeting.systemHQURL)
        }
        resumingDuration = nil
        let liveWords = liveSegments.reduce(0) { $0 + $1.text.split(separator: " ").count }
        MeetingStore.shared.update(id) {
            $0.duration = duration
            $0.status = .processing
            if !participants.isEmpty { $0.participants = (($0.participants ?? []) + participants).uniqued() }
        }
        log.notice("Meeting recording stopped after \(Int(duration)) s (\(liveWords) live words)")
        onStopped?(id)
        process(id)
    }

    /// Words heard live in the recording that's running (or just stopped).
    var liveWordCount: Int { liveSegments.reduce(0) { $0 + $1.text.split(separator: " ").count } }

    /// Appends a resumed part's audio to the main track, then removes the part.
    private static func appendPart(_ part: URL, to track: URL) {
        guard let added = try? AudioFileWriter.read(part) else { return }
        let existing = (try? AudioFileWriter.read(track)) ?? []
        if let writer = try? AudioFileWriter(url: track) {
            writer.append(existing)
            writer.append(added)
        }
        try? FileManager.default.removeItem(at: part)
    }

    /// Names worth spelling right: the people invited, the call's participants, and your dictionary's words.
    static func knownNames(for meeting: Meeting, vocabulary: [String]) -> [String] {
        (meeting.attendees ?? []) + (meeting.participants ?? []) + vocabulary
    }

    /// Test hook: `ONWORD_TEST_MEETING=/folder` (containing mic.wav and/or system.wav) imports those
    /// tracks as a new meeting and processes it, exercising everything after the audio capture.
    func importForTesting(from folder: URL) {
        var meeting = Meeting(title: "Test meeting – \(folder.lastPathComponent)")
        // attendees.txt (one name per line) stands in for the calendar invite.
        if let names = try? String(contentsOf: folder.appendingPathComponent("attendees.txt"), encoding: .utf8) {
            meeting.attendees = names.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        try? FileManager.default.createDirectory(at: meeting.folder, withIntermediateDirectories: true)
        for (name, destination) in [("mic", meeting.micURL), ("system", meeting.systemURL)] {
            let source = folder.appendingPathComponent("\(name).wav")
            guard let samples = try? AudioFileWriter.read(source), let writer = try? AudioFileWriter(url: destination) else { continue }
            writer.append(samples)
            meeting.duration = max(meeting.duration, Double(samples.count) / Resampler.sampleRate)
            if name == "system" { meeting.hasSystemAudio = true }
        }
        meeting.status = .processing
        MeetingStore.shared.save(meeting)
        log.notice("Imported test meeting from \(folder.path, privacy: .public)")
        process(meeting.id)
    }

    /// Transcribes and speaker-tags a meeting. Also used by "Re-process".
    func process(_ id: UUID) {
        guard let meeting = MeetingStore.shared.meeting(id) else { return }
        let controller = DictationController.shared
        // Meetings are transcribed after the call, so they use the most accurate model (Large v3 Turbo, downloaded
        // once); in testing it cut word errors on call audio by about a quarter. Your dictation model is the
        // fallback when it can't be downloaded. Test hook: ONWORD_MEETING_MODEL=<raw value>.
        let model = ProcessInfo.processInfo.environment["ONWORD_MEETING_MODEL"].flatMap(Transcriber.Model.init(rawValue:)) ?? .largeTurbo
        let fallback = controller.model
        // An English-only dictation model means you speak English; tell the multilingual model so.
        let language = controller.language == "auto" ? (controller.model.isEnglishOnly ? "en" : nil) : controller.language
        let dictionary = UserDictionary.load(from: AppPaths.dictionary)
        let replacements = dictionary.allReplacements
        let names = Self.knownNames(for: meeting, vocabulary: dictionary.vocabulary)
        MeetingStore.shared.update(id) { $0.status = .processing; $0.statusDetail = "Starting…" }

        Task {
            do {
                let (segments, names) = try await MeetingProcessor.shared.process(
                    micURL: meeting.micURL, systemURL: meeting.systemURL, speakersURL: meeting.speakersURL,
                    model: model, fallback: fallback, language: language,
                    // Test hook: ONWORD_TEST_LANGUAGES=en,ja stands in for the languages picked in Settings.
                    languages: ProcessInfo.processInfo.environment["ONWORD_TEST_LANGUAGES"].map { $0.split(separator: ",").map(String.init) }
                        ?? controller.selectedLanguages,
                    replacements: replacements,
                    otherPeople: (meeting.attendees?.count).flatMap { $0 > 0 ? $0 : nil }, names: names
                ) { message in
                    await MainActor.run { MeetingStore.shared.update(id) { $0.statusDetail = message } }
                }
                MeetingStore.shared.update(id) { m in
                    m.segments = segments
                    // Names read from the call app, unless the user already named that speaker.
                    for (speaker, name) in names where m.speakerNames[speaker] == nil
                        || m.speakerNames[speaker]?.hasPrefix("Speaker ") == true {
                        m.speakerNames[speaker] = name
                    }
                    // Two diarized speakers given the same name are the same person.
                    for speaker in m.speakers {
                        guard let name = m.speakerNames[speaker],
                              let first = m.speakers.first(where: { m.speakerNames[$0] == name }), first != speaker else { continue }
                        m.segments = TranscriptMerger.reassign(m.segments, from: speaker, to: first)
                        m.speakerNames[speaker] = nil
                    }
                    // A 1:1: one other person invited and one other voice heard — that voice is them.
                    let others = m.speakers.filter { $0 != "me" && $0 != "unknown" }
                    if others.count == 1, m.speakerNames[others[0]] == nil || m.speakerNames[others[0]]?.hasPrefix("Speaker ") == true {
                        let invited = m.participants?.count == 1 ? m.participants : m.attendees
                        if let only = invited, only.count == 1 { m.speakerNames[others[0]] = only[0] }
                    }
                    // Keep names the user already set; default the rest.
                    var numbered = 0
                    for speaker in m.speakers where m.speakerNames[speaker] == nil {
                        if speaker == "me" { m.speakerNames[speaker] = "Me" /* shown as your current name */ } else if speaker == "unknown" {
                            m.speakerNames[speaker] = "Unknown"
                        } else {
                            numbered += 1
                            m.speakerNames[speaker] = "Speaker \(numbered)"
                        }
                    }
                    // Forget names of speakers that no longer appear (e.g. after re-processing).
                    let present = Set(m.speakers)
                    m.speakerNames = m.speakerNames.filter { present.contains($0.key) }
                    m.status = .ready
                    m.statusDetail = segments.isEmpty ? "No speech was detected." : nil
                }
                // Short meetings without your own notes wait for "Generate summary" (as in Wispr Flow).
                if let m = MeetingStore.shared.meeting(id), m.duration <= 300,
                   ProcessInfo.processInfo.environment["ONWORD_TEST_SUMMARIZE"] == nil,
                   m.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, m.summary == nil {
                    MeetingStore.shared.update(id) { $0.summaryDeferred = true }
                } else {
                    MeetingSummarizer.shared.summarize(id)
                }
                // Compress the two raw tracks into recording.m4a (you left, the call right).
                if let done = MeetingStore.shared.meeting(id), done.status == .ready {
                    Task.detached(priority: .utility) { MeetingAudio.compress(done) }
                }
                // Free the meeting model's memory until the next meeting (dictation keeps its own).
                if !isRecording { await MeetingProcessor.transcriber.unload() }
            } catch {
                log.error("Meeting processing failed: \(error.localizedDescription)")
                MeetingStore.shared.update(id) {
                    $0.status = .failed
                    $0.statusDetail = error.localizedDescription
                }
            }
        }
    }
}

/// Latest loudness per track, written from audio threads and read by the UI timer.
private final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _mic: Float = 0
    private var _system: Float = 0
    var mic: Float {
        get { lock.withLock { _mic } }
        set { lock.withLock { _mic = newValue } }
    }
    var system: Float {
        get { lock.withLock { _system } }
        set { lock.withLock { _system = newValue } }
    }
}

extension Meeting {
    /// Where a resumed part of a track is recorded before it's appended (mic.caf → mic-part.caf).
    func partURL(_ track: URL) -> URL {
        track.deletingPathExtension().appendingPathExtension("part").appendingPathExtension("caf")
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0.lowercased()).inserted }
    }
}
