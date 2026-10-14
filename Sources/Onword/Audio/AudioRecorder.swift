import AVFoundation
import CoreAudio
import os

/// Records a microphone and converts it to what Whisper wants: 16 kHz mono Float32.
///
/// Survives microphones changing under it. AirPods are the classic case: using their mic switches
/// Bluetooth into headset mode about a second after recording starts, which makes macOS reconfigure
/// (and stop) the audio engine. So:
/// - every recording gets a fresh `AVAudioEngine` bound to the current device;
/// - a configuration change, a new default microphone, or 1.5 s without audio restarts the engine;
/// - gaps are filled with silence, so a meeting's mic track stays in sync with the call track.
/// Must be used from the main thread.
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case noInputDevice
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .noInputDevice: "No microphone input is available."
            case .converterUnavailable: "Couldn't convert microphone audio to 16 kHz."
            }
        }
    }

    static let sampleRate = Resampler.sampleRate

    /// Test hook: launch with `ONWORD_TEST_AUDIO=/path/to.wav` to use that file instead of the microphone.
    /// Everything else (hotkey, transcription, insertion) stays real.
    private let testAudioURL = ProcessInfo.processInfo.environment["ONWORD_TEST_AUDIO"].map(URL.init(fileURLWithPath:))

    /// Also called (on the audio thread) with every converted chunk, e.g. to stream a meeting to disk.
    var onSamples: (([Float]) -> Void)?
    /// Keep everything in memory for `stop()`. Meetings turn this off and write to disk instead.
    var keepsSamples = true
    /// The microphone chosen in the menu (Core Audio UID), or nil to follow the system default.
    var preferredDeviceUID: String? { UserDefaults.standard.string(forKey: Self.microphoneKey) }
    static let microphoneKey = "microphoneUID"

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var currentDeviceID: AudioDeviceID?
    private var watchdog: Timer?
    private var isRunning = false
    private var restartAttempts = 0
    private var pendingSwitch: DispatchWorkItem?
    private var lastRestart = Date.distantPast

    private let lock = NSLock()
    private var samples: [Float] = []
    private var currentLevel: Float = 0
    private var startedAt = Date()
    private var sampleCount = 0
    private var lastBufferAt = Date()
    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "audio")

    /// Recent loudness, 0…1, for the level meter.
    var level: Float { lock.withLock { currentLevel } }

    /// Name of the microphone being recorded, for the UI.
    private(set) var deviceName: String?

    func start() throws {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            currentLevel = 0
            sampleCount = 0
            startedAt = Date()
            lastBufferAt = Date()
        }
        if let testAudioURL, keepsSamples {
            log.notice("Test mode: using \(testAudioURL.lastPathComponent, privacy: .public) instead of the microphone")
            return
        }
        isRunning = true
        restartAttempts = 0
        do {
            try startEngine()
        } catch {
            isRunning = false
            throw error
        }
        // Follow the right microphone while recording: a new system default, or (in Automatic mode) a
        // headset being connected or disconnected.
        defaultInputListener = AudioDevices.addDefaultInputListener { [weak self] in self?.microphonesChanged() }
        deviceListListener = AudioDevices.addDeviceListListener { [weak self] in self?.microphonesChanged() }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            let silentFor = Date().timeIntervalSince(self.lock.withLock { self.lastBufferAt })
            if silentFor > 1.5, Date().timeIntervalSince(self.lastRestart) > 2 {
                self.restart(reason: "no audio for \(String(format: "%.1f", silentFor)) s")
                self.lastRestart = Date()
            }
        }
    }

    /// Stops recording and returns everything captured since `start()` (empty when `keepsSamples` is off).
    func stop() -> [Float] {
        if let testAudioURL, keepsSamples { return (try? AudioFileWriter.read(testAudioURL)) ?? [] }
        isRunning = false
        pendingSwitch?.cancel()
        pendingSwitch = nil
        watchdog?.invalidate()
        watchdog = nil
        if let defaultInputListener { AudioDevices.removeListener(defaultInputListener) }
        defaultInputListener = nil
        if let deviceListListener { AudioDevices.removeDeviceListListener(deviceListListener) }
        deviceListListener = nil
        stopEngine()
        return lock.withLock { samples }
    }

    // MARK: - Engine

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Pick the microphone: per the preference (system default, Automatic = headset if connected, or a
        // specific device), falling back to the system default.
        var device = AudioDevices.defaultInput
        if let chosen = AudioDevices.resolve(preference: preferredDeviceUID), chosen.id != device?.id,
           let unit = input.audioUnit {
            var id = chosen.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status == noErr { device = chosen } else { log.error("Couldn't select \(chosen.name, privacy: .public): \(status)") }
        }
        currentDeviceID = device?.id

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }

        // The tap converts with whatever format each buffer actually has, so a device that changes
        // sample rate mid-stream doesn't break conversion.
        var resampler: Resampler?
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            if resampler == nil || resampler?.inputFormat != buffer.format {
                resampler = Resampler(from: buffer.format)
            }
            guard let self, let resampler else { return }
            self.append(resampler.convert(buffer))
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restart(reason: "audio configuration changed")
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            configObserver = nil
            throw error
        }
        self.engine = engine
        deviceName = device?.name
        lock.withLock { lastBufferAt = Date() }
        log.notice("Recording from \(device?.name ?? "default microphone", privacy: .public) at \(format.sampleRate) Hz, \(format.channelCount) ch")
    }

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// Restarts on the newly preferred microphone if it differs from the one being recorded.
    /// macOS often announces one change twice, so this waits for things to settle.
    private func microphonesChanged() {
        guard isRunning else { return }
        pendingSwitch?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            let wanted = AudioDevices.resolve(preference: self.preferredDeviceUID)
            guard let wanted, wanted.id != self.currentDeviceID else { return }
            self.restart(reason: "microphone changed to \(wanted.name)")
        }
        pendingSwitch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Rebuilds the engine on the (possibly new) microphone. Devices mid-switch can briefly report no
    /// input, so failed attempts are retried for a few seconds.
    private func restart(reason: String) {
        guard isRunning else { return }
        log.notice("Restarting microphone: \(reason, privacy: .public)")
        lastRestart = Date()
        stopEngine()
        do {
            try startEngine()
            restartAttempts = 0
        } catch {
            restartAttempts += 1
            guard restartAttempts <= 10 else {
                log.error("Microphone did not come back after \(self.restartAttempts) attempts")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restart(reason: "retry \(self?.restartAttempts ?? 0)")
            }
        }
    }

    // MARK: - Samples (audio thread)

    private func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        // Fill any gap (device switch, engine restart) with silence so the timeline stays true.
        let gap: Int = lock.withLock {
            let expected = Int(Date().timeIntervalSince(startedAt) * Self.sampleRate)
            return expected - sampleCount - chunk.count
        }
        if gap > Int(0.3 * Self.sampleRate) {
            let silence = [Float](repeating: 0, count: min(gap, Int(30 * Self.sampleRate)))
            deliver(silence)
            log.notice("Filled a \(String(format: "%.1f", Double(silence.count) / Self.sampleRate), privacy: .public) s gap with silence")
        }
        deliver(chunk)
    }

    private func deliver(_ chunk: [Float]) {
        onSamples?(chunk)
        let rms = Resampler.rms(chunk)
        lock.withLock {
            if keepsSamples { samples.append(contentsOf: chunk) }
            sampleCount += chunk.count
            lastBufferAt = Date()
            currentLevel = min(1, rms * 8)
        }
    }

    /// Root-mean-square loudness of a whole recording; used to skip silent recordings
    /// (Whisper invents "Thank you." when given silence).
    static func rms(_ samples: [Float]) -> Float { Resampler.rms(samples) }
}
