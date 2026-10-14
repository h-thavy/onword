import AppKit
import Network
import OnwordCore
import os

/// Ties everything together: hotkey → record → transcribe on-device → clean up → insert.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case needsPermissions
        case loadingModel
        case idle
        case recording
        case transcribing
        case error(String)
    }

    static let shared = DictationController()

    @Published private(set) var state: State = .loadingModel
    @Published private(set) var level: Float = 0
    @Published private(set) var isHandsFree = false
    @Published private(set) var lastText: String?
    /// When the dictation shortcut was last pressed (setup shows "✓ Detected").
    @Published private(set) var lastHotkeyPress: Date?
    /// True while the dictation shortcut is physically held down (setup's key animation).
    @Published private(set) var hotkeyIsDown = false
    /// Setup's shortcut test: the key only animates on screen and doesn't start a dictation.
    var hotkeyTestMode = false
    /// When a too-short tap was ignored (setup reminds you to hold the key down).
    @Published private(set) var lastQuickTap: Date?
    /// When the last hands-free dictation finished (setup's hands-free practice).
    @Published private(set) var lastHandsFreeFinish: Date?
    /// When a recording was dropped because it was silent or nothing was understood (setup's mic hint).
    @Published private(set) var lastHeardNothing: Date?
    /// Whether the shortcut listener is actually running (Input Monitoring granted and the tap live).
    @Published private(set) var shortcutReady = false
    /// Setup's practice steps: receives each dictation (text, was hands-free) instead of inserting it,
    /// so the practice box fills even if another app is in front.
    private(set) var practiceSink: ((String, Bool) -> Void)?
    private var practiceOwner: UUID?

    func setPracticeSink(owner: UUID, _ sink: @escaping (String, Bool) -> Void) {
        practiceOwner = owner
        practiceSink = sink
    }

    /// Clears the sink only if `owner` still holds it (the next step may already have taken over).
    func clearPracticeSink(owner: UUID?) {
        guard owner == nil || owner == practiceOwner else { return }
        practiceOwner = nil
        practiceSink = nil
    }
    @Published private(set) var modelStatus = "Not loaded"
    /// Download progress of the speech model (0…1) while it's downloading, otherwise nil.
    @Published private(set) var modelProgress: Double?
    /// The speech model is loaded and dictation can run (setup's download step waits for this).
    @Published private(set) var modelReady = false
    enum SpeakerModelState: Equatable { case downloading, ready, failed(String) }
    /// The speaker-separation models for meeting notes.
    @Published private(set) var speakerModels: SpeakerModelState = SpeakerModels.isDownloaded ? .ready : .downloading
    private var speakerRetry: DispatchWorkItem?
    /// Why the speech model couldn't be loaded, in plain words; nil when fine.
    @Published private(set) var modelFailure: String?
    private var modelRetry: DispatchWorkItem?
    private var modelAttempts = 0
    private var modelLoadID = UUID()
    private var lastModelAttempt = Date.distantPast
    private var networkStarted = false
    private var wasOnline: Bool?
    private lazy var network: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in   // runs on the main queue (see scheduleModelRetry)
            let online = path.status == .satisfied
            MainActor.assumeIsolated { DictationController.shared.networkChanged(online: online) }
        }
        return monitor
    }()

    /// Back online after a failed download (offline → online): try again straight away.
    private func networkChanged(online: Bool) {
        defer { wasOnline = online }
        // Network paths can flap; don't retry more than every 10 s on their account.
        if online, wasOnline == false, modelFailure != nil, Date().timeIntervalSince(lastModelAttempt) > 10 { retryModel() }
        if online, wasOnline == false, case .failed = speakerModels { ensureSpeakerModels() }
    }

    @Published var hotkey: HotkeyMonitor.Key {
        didSet { UserDefaults.standard.set(hotkey.rawValue, forKey: "hotkey"); hotkeyMonitor.key = hotkey }
    }
    @Published var model: Transcriber.Model {
        didSet {
            UserDefaults.standard.set(model.rawValue, forKey: "model")
            if model != oldValue { loadModel() }
        }
    }
    /// ISO code, or "auto". Only used by multilingual models.
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    /// Microphone for dictation and meetings (Core Audio UID); nil follows the system default.
    @Published var microphoneUID: String? {
        didSet { UserDefaults.standard.set(microphoneUID, forKey: AudioRecorder.microphoneKey) }
    }
    @Published var removeFillers: Bool {
        didSet { UserDefaults.standard.set(removeFillers, forKey: "removeFillers") }
    }

    private let hotkeyMonitor = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private var gesture = HotkeyGesture()
    private lazy var panel = StatusPanel(controller: self)
    private var context = TextContext()
    private var recordingStartedAt = Date()
    private var levelTimer: Timer?
    private var permissionTimer: Timer?
    private var lastPermissionSummary = ""
    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "dictation")

    /// Whisper needs some audio to work with; anything shorter is treated as an accidental press.
    private let minimumSeconds = 0.4
    /// Below this loudness the recording is treated as silence (Whisper would hallucinate "Thank you.").
    private let silenceRMS: Float = 0.004
    private let maxSeconds: TimeInterval = 5 * 60

    private init() {
        AppPaths.migrateLegacySettings()
        let defaults = UserDefaults.standard
        hotkey = HotkeyMonitor.Key(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .recommendedDefault
        model = Transcriber.Model(rawValue: defaults.string(forKey: "model") ?? "") ?? .smallEnglish
        language = defaults.string(forKey: "language") ?? "auto"
        removeFillers = defaults.object(forKey: "removeFillers") as? Bool ?? true
        microphoneUID = defaults.string(forKey: AudioRecorder.microphoneKey)
    }

    var statusText: String {
        switch state {
        case .needsPermissions: "Permissions needed"
        case .loadingModel: "Loading model…"
        case .idle: "Ready – hold \(hotkey.title) to dictate"
        case .recording: isHandsFree ? "Listening (hands-free)…" : "Listening…"
        case .transcribing: "Transcribing…"
        case .error(let message): message
        }
    }

    // MARK: - Lifecycle

    func start() {
        AppPaths.ensureDictionary()
        hotkeyMonitor.key = hotkey
        hotkeyMonitor.onPress = { [weak self] in
            guard let self else { return }
            self.lastHotkeyPress = Date()
            self.hotkeyIsDown = true
            if !self.hotkeyTestMode { self.handle(self.gesture.press()) }
        }
        hotkeyMonitor.onRelease = { [weak self] in
            guard let self else { return }
            self.hotkeyIsDown = false
            if !self.hotkeyTestMode { self.handle(self.gesture.release()) }
        }
        hotkeyMonitor.onEscape = { [weak self] in self?.cancel() }
        // Test hook: ONWORD_TEST_HOTKEY=1 lets a script press the shortcut with a distributed notification
        // "io.github.h-thavy.onword.test-hotkey" (object "down" / "up"); synthetic key events are often
        // swallowed by other dictation apps.
        if ProcessInfo.processInfo.environment["ONWORD_TEST_HOTKEY"] != nil {
            DistributedNotificationCenter.default().addObserver(
                forName: .init("io.github.h-thavy.onword.test-hotkey"), object: nil, queue: .main
            ) { [weak self] note in
                let down = note.object as? String == "down"
                MainActor.assumeIsolated { down ? self?.hotkeyMonitor.onPress?() : self?.hotkeyMonitor.onRelease?() }
            }
        }
        refreshPermissions()
        loadModel()
        ensureSpeakerModels()
    }

    /// Re-checks permissions. While anything is missing this runs every 2 s on its own,
    /// so granting a permission in System Settings takes effect without restarting the app.
    func refreshPermissions() {
        if Permissions.inputMonitoring {
            // A tap created before the grant may never receive events; recreate it once.
            if hotkeyMonitor.isRunning && !hotkeyMonitor.createdWithAccess { hotkeyMonitor.stop() }
            hotkeyMonitor.start()
        }
        let ready = Permissions.allGranted && hotkeyMonitor.isRunning
        if shortcutReady != hotkeyMonitor.isRunning { shortcutReady = hotkeyMonitor.isRunning }

        let summary = """
            Permissions: mic=\(Permissions.microphone) accessibility=\(Permissions.accessibility) \
            inputMonitoring=\(Permissions.inputMonitoring) tap=\(hotkeyMonitor.isRunning)
            """
        if summary != lastPermissionSummary {
            log.notice("\(summary, privacy: .public)")
            lastPermissionSummary = summary
        }

        if !ready {
            if state == .idle { state = .needsPermissions }
            if permissionTimer == nil {
                permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshPermissions() }
                }
            }
        } else {
            permissionTimer?.invalidate()
            permissionTimer = nil
            if state == .needsPermissions { state = .idle }
        }
    }

    func requestPermissions() {
        Task {
            _ = await Permissions.requestMicrophone()
            if !Permissions.accessibility { Permissions.requestAccessibility() }
            if !Permissions.inputMonitoring {
                Permissions.requestInputMonitoring()
                // Trying to create the tap is what makes macOS list the app under Input Monitoring.
                hotkeyMonitor.start()
            }
            refreshPermissions()
        }
    }

    /// Loads the speech model, downloading it the first time. A failed download is retried on its own
    /// (after 5 s, 15 s, 30 s, then every minute) and as soon as the Mac is back online.
    func loadModel() {
        if !networkStarted {   // knowing whether the Mac is online makes the error message accurate
            networkStarted = true
            network.start(queue: .main)
        }
        modelRetry?.cancel()
        modelRetry = nil
        modelReady = false
        state = .loadingModel
        modelFailure = nil
        let model = self.model
        let downloaded = Transcriber.localFolder(for: model, downloadBase: AppPaths.models) != nil
        modelStatus = downloaded ? "Loading the speech model…" : "Downloading the speech model…"
        modelProgress = downloaded ? nil : 0
        let loadID = UUID()
        modelLoadID = loadID
        lastModelAttempt = Date()
        Task {
            do {
                try await transcriber.load(model, downloadBase: AppPaths.models) { fraction in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let controller = DictationController.shared
                            guard controller.modelLoadID == loadID, controller.state == .loadingModel else { return }
                            controller.modelProgress = fraction
                            controller.modelStatus = fraction < 1
                                ? "Downloading the speech model… \(Int(fraction * 100))%"
                                : "Preparing the speech model… (about a minute, only the first time)"
                        }
                    }
                }
                guard model == self.model, modelLoadID == loadID else { return }
                modelStatus = "\(model.rawValue) loaded"
                modelProgress = nil
                modelAttempts = 0
                modelReady = true
                log.notice("Model \(model.rawValue, privacy: .public) loaded")
                state = .idle
                refreshPermissions()
            } catch {
                guard model == self.model, modelLoadID == loadID else { return }
                let message = Self.describeModelError(error, online: wasOnline != false)
                log.error("Model load failed (attempt \(self.modelAttempts + 1)): \(error.localizedDescription, privacy: .public)")
                modelStatus = message
                modelProgress = nil
                modelFailure = message
                state = .error(message)
                scheduleModelRetry()
            }
        }
    }

    /// Downloads the speaker-separation models if needed, retrying every 15 s (and when back online).
    func ensureSpeakerModels() {
        speakerRetry?.cancel()
        speakerRetry = nil
        guard !SpeakerModels.isDownloaded else { speakerModels = .ready; return }
        speakerModels = .downloading
        Task {
            do {
                try await SpeakerModels.download()
                speakerModels = .ready
                log.notice("Speaker models downloaded")
            } catch {
                log.error("Speaker models download failed: \(error.localizedDescription, privacy: .public)")
                speakerModels = .failed(wasOnline == false
                    ? "You’re offline — it’ll download when you’re back online."
                    : "Couldn’t download — retrying.")
                let work = DispatchWorkItem { MainActor.assumeIsolated { DictationController.shared.ensureSpeakerModels() } }
                speakerRetry = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
            }
        }
    }

    /// Tries loading the model again now (the "Try again" buttons).
    func retryModel() {
        guard state != .loadingModel else { return }
        loadModel()
    }

    private func scheduleModelRetry() {
        let delays: [TimeInterval] = [5, 15, 30]
        let delay = modelAttempts < delays.count ? delays[modelAttempts] : 60
        modelAttempts += 1
        let work = DispatchWorkItem { MainActor.assumeIsolated { DictationController.shared.retryModel() } }
        modelRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// What went wrong, in plain words. The download library often hides the network error behind a generic
    /// "Download failed", so being offline is judged from the error chain and from the Mac's network status.
    static func describeModelError(_ error: Error, online: Bool) -> String {
        if let error = error as? Transcriber.TranscriberError { return error.localizedDescription }
        var errors: [NSError] = []
        var next: NSError? = error as NSError
        while let current = next, errors.count < 5 {
            errors.append(current)
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if errors.contains(where: { $0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteOutOfSpaceError }) {
            return "Not enough disk space for the speech model. Free up about 1 GB, then click Try again."
        }
        let offlineCodes: Set<Int> = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                                      NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff]
        if !online || errors.contains(where: { $0.domain == NSURLErrorDomain && offlineCodes.contains($0.code) }) {
            return "You’re offline. Onword needs to download its speech model once (about 500 MB) — it’ll start as soon as you’re back online."
        }
        return "Couldn’t download the speech model. Check your internet connection — Onword keeps retrying on its own."
    }

    // MARK: - Hotkey actions

    private func handle(_ action: HotkeyGesture.Action?) {
        switch action {
        case .startRecording: beginRecording()
        case .finishRecording: finishRecording()
        // Not cancel(): the gesture must keep remembering this tap so a second tap can start hands-free.
        case .discardRecording:
            lastQuickTap = Date()
            discardRecording()
        case .enterHandsFree:
            isHandsFree = true
        case .ignore, nil: break
        }
    }

    private func beginRecording() {
        if state == .needsPermissions { refreshPermissions() }
        guard state == .idle else {
            gesture.cancel()
            if state == .needsPermissions { NSSound.beep() }
            return
        }
        context = AX.readContext()
        if context.isSecureField {
            gesture.cancel()
            NSSound.beep()
            return
        }
        do {
            try recorder.start()
        } catch {
            gesture.cancel()
            state = .error(error.localizedDescription)
            return
        }
        recordingStartedAt = Date()
        isHandsFree = false
        state = .recording
        panel.show()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.level = self.recorder.level
                if Date().timeIntervalSince(self.recordingStartedAt) > self.maxSeconds {
                    self.gesture.cancel()
                    self.finishRecording()
                }
            }
        }
    }

    /// Esc, or anything else that aborts dictation outright.
    func cancel() {
        gesture.cancel()
        discardRecording()
    }

    private func discardRecording() {
        guard state == .recording else { return }
        _ = stopRecording()
        state = .idle
        panel.hide()
    }

    private func stopRecording() -> [Float] {
        levelTimer?.invalidate()
        levelTimer = nil
        level = 0
        isHandsFree = false
        return recorder.stop()
    }

    private func finishRecording() {
        guard state == .recording else { return }
        let wasHandsFree = isHandsFree
        let samples = stopRecording()
        let seconds = Double(samples.count) / AudioRecorder.sampleRate

        guard seconds >= minimumSeconds, AudioRecorder.rms(samples) >= silenceRMS else {
            log.notice("Skipped: \(seconds, format: .fixed(precision: 2)) s, too short or silent")
            if seconds >= minimumSeconds { lastHeardNothing = Date() }
            state = .idle
            panel.hide()
            return
        }

        state = .transcribing
        let dictionary = UserDictionary.load(from: AppPaths.dictionary)
        let cleaner = TextCleaner(removeFillers: removeFillers, replacements: dictionary.allReplacements)
        let language = language == "auto" ? nil : language
        let context = self.context

        Task {
            let started = Date()
            defer {
                state = .idle
                panel.hide()
            }
            do {
                let raw = try await transcriber.transcribe(samples, language: language, prompt: dictionary.whisperPrompt())
                if seconds < 3, TextCleaner.isLikelyHallucination(raw) { lastHeardNothing = Date(); return }
                if let practiceSink {
                    let text = cleaner.clean(raw, before: "", after: "")
                    guard !text.isEmpty else { lastHeardNothing = Date(); return }
                    log.notice("Practice dictation: \(seconds, format: .fixed(precision: 1)) s audio → \(text.count) chars, hands-free=\(wasHandsFree)")
                    lastText = text
                    if wasHandsFree { lastHandsFreeFinish = Date() }
                    practiceSink(text, wasHandsFree)
                    return
                }
                let text = cleaner.clean(raw, before: context.before, after: context.after)
                guard !text.isEmpty else { lastHeardNothing = Date(); return }

                let method: TextInserter.Method
                if context.isOwnApp {
                    method = OwnWindowInserter.insert(text) ? .ownWindow : TextInserter.copyOnly(text)
                } else {
                    method = TextInserter.insert(text, into: context)
                }
                if method == .copiedOnly { NSSound.beep() }
                log.notice("Dictation: \(seconds, format: .fixed(precision: 1)) s audio → \(text.count) chars via \(method.rawValue, privacy: .public) into \(context.bundleID ?? "?", privacy: .public)")
                lastText = text
                if wasHandsFree { lastHandsFreeFinish = Date() }
                History.append(HistoryEntry(
                    date: Date(), app: context.bundleID, raw: raw, text: text, seconds: seconds,
                    transcribeMs: Int(Date().timeIntervalSince(started) * 1000), method: method))
            } catch {
                log.error("Transcription failed: \(error.localizedDescription)")
                NSSound.beep()
            }
        }
    }

    // MARK: - Menu helpers

    func copyLastText() {
        guard let lastText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }

    func openDictionary() {
        AppPaths.ensureDictionary()
        NSWorkspace.shared.open(AppPaths.dictionary)
    }

    func openDataFolder() {
        NSWorkspace.shared.open(AppPaths.root)
    }
}
