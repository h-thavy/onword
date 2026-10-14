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

        // 3. Read buffers as they arrive.
        try check("create IO proc", AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
            [weak self] _, inputData, _, _, _ in
            guard let self, let format = self.tapFormat, let resampler = self.resampler,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
            else { return }
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
        try check("start device", AudioDeviceStart(aggregateID, ioProcID))
        log.notice("System audio capture started (\(format.sampleRate) Hz)")
    }

    func stop() {
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
