import AppKit
import SwiftUI

/// What the Flow Bar shows. `FlowBar` decides it; `FlowBarView` draws it.
@MainActor
final class FlowBarModel: ObservableObject {
    enum Mode: Equatable {
        /// The idle 40×8 sliver above the Dock.
        case rest
        /// Hovered: the mic pill plus the Notetaker record button.
        case ready
        /// Push-to-talk: the shortcut is held.
        case listening
        /// Hands-free: ✕, waveform, ✓.
        case handsFree
        /// Transcribing.
        case processing
        /// A red-bordered flash for 500 ms.
        case error
        /// Notetaker is recording.
        case meeting
    }

    /// The parts of the bar that react to the pointer.
    enum Target: Hashable {
        case mic, record, meetings, cancel, finish, meetingNote, meetingStop
    }

    /// A tooltip above `target`: runs of plain and bold text.
    struct Tooltip: Equatable {
        struct Run: Equatable {
            var text: String
            var bold = false
            var color: Color = .white
        }
        var target: Target
        var runs: [Run]
    }

    @Published var mode: Mode = .rest
    /// The resting bar is invisible ("Show Flow Bar at all times" is off, or it's hidden for an hour).
    @Published var concealed = false
    /// The element under the pointer.
    @Published var hover: Target?
    @Published var tooltip: Tooltip?
    /// The bar's own context menu is open, which keeps it expanded.
    @Published var menuOpen = false
    /// The upcoming-meetings drawer is open (keeps the bar expanded and the caret pill wide).
    @Published var drawerOpen = false

    let dictationMeter = LevelMeter(gain: 5) { DictationController.shared.level }
    let meetingMeter = LevelMeter(gain: 2) {
        max(MeetingRecorder.shared.micLevel, MeetingRecorder.shared.systemLevel)
    }
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var layout: FlowBarLayout {
        FlowBarLayout(mode: mode, caretOpen: drawerOpen || hover == .record || hover == .meetings)
    }
}

/// Where everything sits inside the bar's transparent canvas (top-left origin, points). The pill's bottom
/// edge is anchored 14 pt above the canvas bottom, which sits on the Dock (or the screen bottom), so the pill
/// grows upward and outward from its bottom centre.
struct FlowBarLayout {
    /// Room for the pill, the record button beside it and a tooltip above.
    static let canvas = CGSize(width: 560, height: 100)
    /// Pill bottom to Dock top.
    static let bottomInset: CGFloat = 14
    /// The hover zone around the pill, and how much it grows once expanded.
    static let hotPadding = CGSize(width: 10, height: 6)
    static let expandedSlack: CGFloat = 12

    let mode: FlowBarModel.Mode
    /// The caret pill behind the Notetaker button is widened to show the meetings chevron.
    var caretOpen = false

    /// Behind the Notetaker button: 30 pt wide, widening to 54 pt to reveal a chevron (Wispr's caret pill).
    var caret: CGRect? {
        guard let record else { return nil }
        return CGRect(x: record.minX, y: record.minY, width: caretOpen ? 54 : 30, height: 30)
    }

    /// The chevron that opens the upcoming-meetings drawer (only while the caret pill is wide).
    var meetingsChevron: CGRect? {
        guard caretOpen, let record else { return nil }
        return CGRect(x: record.maxX, y: record.minY, width: 24, height: 30)
    }

    var pillSize: CGSize {
        switch mode {
        case .rest: CGSize(width: 40, height: 8)
        case .ready: CGSize(width: 50, height: 30)
        case .listening: CGSize(width: 73, height: 30)
        case .handsFree: CGSize(width: 102.5, height: 30)
        case .processing: CGSize(width: 98, height: 30)
        case .error: CGSize(width: 91, height: 30)
        // fit-content: 2 border + 5 padding + 24 waveform + 12 gap + 19 stop + 5 padding + 2 border.
        case .meeting: CGSize(width: 69, height: 30)
        }
    }

    var pill: CGRect {
        let size = pillSize
        return CGRect(x: (Self.canvas.width - size.width) / 2,
                      y: Self.canvas.height - Self.bottomInset - size.height,
                      width: size.width, height: size.height)
    }

    /// The 30×30 Notetaker button, 2 pt right of the mic pill (READY only).
    var record: CGRect? {
        guard mode == .ready else { return nil }
        let pill = pill
        return CGRect(x: pill.maxX + 2, y: pill.midY - 15, width: 30, height: 30)
    }

    /// Hands-free ✕ and ✓: 18 pt circles at the pill's ends, 4 pt from the waveform.
    var cancel: CGRect? {
        guard mode == .handsFree else { return nil }
        let pill = pill
        return CGRect(x: pill.minX + 6.25, y: pill.midY - 9, width: 18, height: 18)
    }

    var finish: CGRect? {
        guard mode == .handsFree else { return nil }
        let pill = pill
        return CGRect(x: pill.maxX - 6.25 - 18, y: pill.midY - 9, width: 18, height: 18)
    }

    /// Notetaker pill: the 24×24 waveform (opens the note) and the 19×19 stop button.
    var meetingStop: CGRect? {
        guard mode == .meeting else { return nil }
        let pill = pill
        return CGRect(x: pill.maxX - 7 - 19, y: pill.midY - 9.5, width: 19, height: 19)
    }

    /// The area that catches the pointer: the pill (and record button) plus 6/10 pt, 12 pt more once expanded.
    func hotRect(expanded: Bool) -> CGRect {
        var rect = pill
        if let record { rect = rect.union(record) }
        if let caret { rect = rect.union(caret) }
        rect = rect.insetBy(dx: -Self.hotPadding.width, dy: -Self.hotPadding.height)
        return expanded ? rect.insetBy(dx: -Self.expandedSlack, dy: -Self.expandedSlack) : rect
    }

    /// The clickable element at `point`, if any.
    func target(at point: CGPoint) -> FlowBarModel.Target? {
        if let meetingsChevron, meetingsChevron.contains(point) { return .meetings }
        if let record, record.contains(point) { return .record }
        if let cancel, cancel.contains(point) { return .cancel }
        if let finish, finish.contains(point) { return .finish }
        if let meetingStop, meetingStop.contains(point) { return .meetingStop }
        guard pill.contains(point) else { return nil }
        switch mode {
        case .ready, .listening, .handsFree: return .mic
        case .meeting: return .meetingNote
        case .rest, .processing, .error: return nil
        }
    }

    /// The rect a target's tooltip points at, and its gap (4 pt for the pill and record button, 10 pt for the
    /// small round buttons).
    func anchor(for target: FlowBarModel.Target) -> (rect: CGRect, offset: CGFloat) {
        switch target {
        case .record: (record ?? pill, 4)
        case .meetings: (meetingsChevron ?? record ?? pill, 4)
        case .cancel: (cancel ?? pill, 10)
        case .finish: (finish ?? pill, 10)
        case .meetingStop: (meetingStop ?? pill, 10)
        case .mic, .meetingNote: (pill, 4)
        }
    }
}

/// Turns the recorder's 0…1 loudness into the waveform's `audioScale`, the way the Flow Bar does:
/// decibels above an adaptive floor (never below −60 dB) over a 20 dB range, averaged over 150 ms, then
/// smoothed with an 0.85 exponential moving average per 60 Hz frame. `audioScale = max(1, gain × smoothed)`.
@MainActor
final class LevelMeter {
    let gain: Float
    /// Recent loudness, 0…1 (`rms × 8`, as `AudioRecorder.level`).
    var source: () -> Float
    /// Whether any audio has arrived since `reset()` (bars stay dim, still dots until then).
    private(set) var micActive = false
    private var floorDB: Float = .infinity
    private var window: [(time: TimeInterval, level: Float)] = []
    private var smoothed: Float = 0
    private var lastTime: TimeInterval?
    private var scale: CGFloat = 1

    init(gain: Float, source: @escaping () -> Float) {
        self.gain = gain
        self.source = source
    }

    func reset() {
        micActive = false
        floorDB = .infinity
        window.removeAll()
        smoothed = 0
        lastTime = nil
        scale = 1
    }

    /// Call once per frame; repeated calls for the same frame return the same value.
    func audioScale(at time: TimeInterval) -> CGFloat {
        if let lastTime, time <= lastTime { return scale }
        let raw = source()
        if raw > 0 { micActive = true }
        let db = 20 * log10(max(raw / 8, 1e-5))
        floorDB = max(-60, min(floorDB, db))
        let level = min(1, max(0, (db - floorDB) / 20))
        window.append((time, level))
        window.removeAll { time - $0.time > 0.15 }
        let average = window.map(\.level).reduce(0, +) / Float(window.count)
        let frames = Float(lastTime.map { min(0.25, time - $0) * 60 } ?? 1)
        let keep = pow(Float(0.85), frames)
        smoothed = keep * smoothed + (1 - keep) * average
        lastTime = time
        scale = CGFloat(max(1, gain * smoothed))
        return scale
    }
}
