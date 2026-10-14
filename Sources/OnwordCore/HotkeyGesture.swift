import Foundation

/// Decides what a hotkey press/release means, independent of how the key is detected.
///
/// - Hold the key (≥ `minHold`) → push-to-talk: record while held, transcribe on release.
/// - Two quick taps → hands-free: keeps recording until the next press.
/// - One quick tap on its own → ignored (accidental touch), recording is discarded.
public struct HotkeyGesture {
    public enum Action: Equatable {
        case startRecording
        case finishRecording   // transcribe and insert
        case discardRecording  // stop, throw the audio away
        case enterHandsFree    // keep recording after release
        case ignore
    }

    public var minHold: TimeInterval
    public var doubleTapWindow: TimeInterval

    public private(set) var isRecording = false
    public private(set) var isHandsFree = false
    private var pressedAt: Date?
    private var lastQuickTapAt: Date?

    public init(minHold: TimeInterval = 0.3, doubleTapWindow: TimeInterval = 0.45) {
        self.minHold = minHold
        self.doubleTapWindow = doubleTapWindow
    }

    public mutating func press(at now: Date = Date()) -> Action {
        if isRecording && isHandsFree {
            reset()
            return .finishRecording
        }
        guard !isRecording else { return .ignore }
        isRecording = true
        pressedAt = now
        return .startRecording
    }

    public mutating func release(at now: Date = Date()) -> Action {
        guard isRecording, !isHandsFree, let pressedAt else { return .ignore }
        if now.timeIntervalSince(pressedAt) >= minHold {
            reset()
            return .finishRecording
        }
        // Quick tap.
        if let last = lastQuickTapAt, now.timeIntervalSince(last) <= doubleTapWindow {
            isHandsFree = true
            lastQuickTapAt = nil
            return .enterHandsFree
        }
        lastQuickTapAt = now
        isRecording = false
        self.pressedAt = nil
        return .discardRecording
    }

    /// Starts hands-free recording without a key press (the Flow Bar's mic button), so the next press finishes it.
    /// Returns false when a recording is already running.
    @discardableResult
    public mutating func startHandsFree() -> Bool {
        guard !isRecording else { return false }
        reset()
        isRecording = true
        isHandsFree = true
        return true
    }

    /// Escape, errors, or anything else that aborts the current recording.
    public mutating func cancel() {
        reset()
    }

    private mutating func reset() {
        isRecording = false
        isHandsFree = false
        pressedAt = nil
        lastQuickTapAt = nil
    }
}
