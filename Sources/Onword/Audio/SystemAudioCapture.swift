import AVFoundation
import CoreAudio
import os

/// Records what the Mac is playing (the other people in a call) using a Core Audio process tap.
/// No bot joins the call and no virtual audio driver is needed.
/// Needs macOS 14.2+ and the "System Audio Recording" permission (NSAudioCaptureUsageDescription).
@available(macOS 14.2, *)
final class SystemAudioCapture {
    enum CaptureError: LocalizedError {
        case coreAudio(String, OSStatus)
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .coreAudio(let step, let status): "System audio capture failed (\(step): \(status))."
            case .unsupportedFormat: "System audio has an unsupported format."
            }
        }
    }

    /// Called on a background queue with 16 kHz mono samples.
    var onSamples: (([Float]) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var resampler: Resampler?
    private let queue = DispatchQueue(label: "com.onword.system-audio", qos: .userInitiated)
    private var startedAt = Date()
    private var sampleCount = 0
    /// Frames received since `rateCheckStart`, to catch audio arriving at a different rate than assumed.
    private var rateCheckStart: Date?
    private var rateCheckFrames = 0
    /// A rate measured once; switched to only if the next measurement agrees.
    private var suspectedRate: Double?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "system-audio")

    func start() throws {
        // 1. A mono tap of everything the Mac plays, except Onword's own sounds.
        let ownProcess = Self.processObject(for: getpid()).map { [$0] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: ownProcess)
        description.uuid = UUID()
        description.name = "Onword meeting audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check("create tap", AudioHardwareCreateProcessTap(description, &tapID))

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check("read tap format", AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription))
        guard let format = AVAudioFormat(streamDescription: &streamDescription),
              let resampler = Resampler(from: format) else { throw CaptureError.unsupportedFormat }
        tapFormat = format
        self.resampler = resampler

        // 2. A private aggregate device that exposes the tap as an input we can read.
        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Onword Meeting Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check("create aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        // The tap reports the output's usual rate, but the audio arrives at the device's current rate, which
        // differs when e.g. a Bluetooth headset is in call mode (24 or 16 kHz). Reading 24 kHz audio as 48 kHz
        // made the other people sound twice as fast. Use the device's rate, and follow it when it changes.
        if let rate = Self.nominalRate(aggregateID), rate != format.sampleRate {
            log.notice("System audio arrives at \(rate) Hz, not the tap's \(format.sampleRate) Hz")
            useRate(rate)
        }
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let rate = Self.nominalRate(self.aggregateID), rate != self.tapFormat?.sampleRate else { return }
            self.log.notice("System audio rate changed to \(rate) Hz")
            self.useRate(rate)
        }
        rateListener = listener
        AudioObjectAddPropertyListenerBlock(aggregateID, &rateAddress, queue, listener)

        // 3. Read buffers as they arrive.
        try check("create IO proc", AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
            [weak self] _, inputData, _, _, _ in
            guard let self, let format = self.tapFormat, let resampler = self.resampler,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
            else { return }
            self.checkRate(frames: Int(buffer.frameLength))
            let samples = resampler.convert(buffer)
            guard !samples.isEmpty else { return }
            // Keep this track on the same clock as the mic: pad late starts and dropouts with silence.
            let gap = Int(Date().timeIntervalSince(self.startedAt) * Resampler.sampleRate) - self.sampleCount - samples.count
            if gap > Int(0.3 * Resampler.sampleRate) {
                let silence = [Float](repeating: 0, count: min(gap, Int(30 * Resampler.sampleRate)))
                self.sampleCount += silence.count
                self.onSamples?(silence)
            }
            self.sampleCount += samples.count
            self.onSamples?(samples)
        })
        startedAt = Date()
        sampleCount = 0
        rateCheckStart = nil
        rateCheckFrames = 0
        try check("start device", AudioDeviceStart(aggregateID, ioProcID))
        log.notice("System audio capture started (\(self.tapFormat?.sampleRate ?? format.sampleRate) Hz)")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let rateListener {
            var rateAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(aggregateID, &rateAddress, queue, rateListener)
            self.rateListener = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else {
            log.error("\(step, privacy: .public) failed: \(status)")
            stop()
            throw CaptureError.coreAudio(step, status)
        }
    }

    // MARK: - Sample rate

    /// Reads the tap's buffers at `rate` from now on (same channels and layout).
    private func useRate(_ rate: Double) {
        guard let current = tapFormat, rate > 0,
              let format = AVAudioFormat(commonFormat: current.commonFormat, sampleRate: rate,
                                         channels: current.channelCount, interleaved: current.isInterleaved),
              let resampler = Resampler(from: format) else { return }
        tapFormat = format
        self.resampler = resampler
        rateCheckStart = nil
        rateCheckFrames = 0
        suspectedRate = nil
    }

    /// Safety net: every few seconds, compares how many frames arrived with the assumed rate. The device
    /// clock runs even in silence, so this measures the real rate; a big difference switches to the nearest
    /// standard rate.
    private func checkRate(frames: Int) {
        // Measured from the end of the first buffer, so the start-up delay doesn't count.
        guard let start = rateCheckStart else {
            rateCheckStart = Date()
            rateCheckFrames = 0
            return
        }
        rateCheckFrames += frames
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= 3, let assumed = tapFormat?.sampleRate else { return }
        let measured = Double(rateCheckFrames) / elapsed
        rateCheckStart = Date()
        rateCheckFrames = 0
        guard abs(measured - assumed) / assumed > 0.15,
              let nearest = Self.standardRates.min(by: { abs($0 - measured) < abs($1 - measured) }) else {
            suspectedRate = nil
            return
        }
        // Two measurements in a row must agree.
        guard suspectedRate == nearest else { suspectedRate = nearest; return }
        log.notice("System audio arriving at about \(Int(measured)) Hz, not \(assumed) Hz; reading it as \(nearest) Hz")
        useRate(nearest)
    }

    static let standardRates: [Double] = [8_000, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]

    static func nominalRate(_ device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    // MARK: - Core Audio lookups

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw CaptureError.coreAudio("default output device", status) }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw CaptureError.coreAudio("output device UID", status) }
        return uid.takeRetainedValue() as String
    }
}
