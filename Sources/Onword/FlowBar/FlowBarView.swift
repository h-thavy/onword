import SwiftUI

/// Draws the Flow Bar inside its transparent canvas. Everything is positioned from `FlowBarLayout`, the same
/// geometry `FlowBar` uses for hit-testing, so what you see is what you can click.
struct FlowBarView: View {
    @ObservedObject var model: FlowBarModel

    private static let ink = Color(white: 0.07)
    private static let rim = Color.white.opacity(0.22)
    private static let restFill = Color(white: 0.12).opacity(0.55)
    private static let restRim = Color.white.opacity(0.35)
    private static let error = Color(red: 0.94, green: 0.27, blue: 0.27)

    var body: some View {
        let layout = model.layout
        ZStack(alignment: .topLeading) {
            Color.clear
            if !(model.concealed && (model.mode == .rest || model.mode == .ready)) {
                pill(layout)
                if let record = layout.record {
                    recordButton
                        .frame(width: record.width, height: record.height)
                        .offset(x: record.minX, y: record.minY)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            if let tooltip = model.tooltip {
                TooltipBubble(tooltip: tooltip, anchor: layout.anchor(for: tooltip.target))
                    .transition(.opacity)
            }
        }
        .frame(width: FlowBarLayout.canvas.width, height: FlowBarLayout.canvas.height, alignment: .topLeading)
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.12), value: model.tooltip)
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.12), value: model.hover)
    }

    // MARK: Pill

    @ViewBuilder
    private func pill(_ layout: FlowBarLayout) -> some View {
        let rect = layout.pill
        ZStack {
            // The rim is the outer capsule; the fill is inset by the rim width, so the outline can't overhang.
            if model.mode == .rest {
                // Translucent, so the rim is a stroke rather than a capsule underneath.
                Capsule().fill(Self.restFill)
                Capsule().strokeBorder(rimColor, lineWidth: 1)
            } else {
                Capsule().fill(rimColor)
                Capsule().fill(Self.ink).padding(model.mode == .meeting ? 2 : 1.5)
            }
            content(layout).clipShape(Capsule())
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }

    private var rimColor: Color {
        switch model.mode {
        case .rest: Self.restRim
        case .error: Self.error
        case .meeting: Color(red: 0x10 / 255, green: 0xB9 / 255, blue: 0x81 / 255)   // #10B981 while Notetaker records
        default: model.hover == .mic || model.hover == .meetingNote ? Color.white.opacity(0.4) : Self.rim
        }
    }

    @ViewBuilder
    private func content(_ layout: FlowBarLayout) -> some View {
        let pill = layout.pill
        switch model.mode {
        case .rest:
            EmptyView()
        case .ready:
            // The mic: click for hands-free dictation.
            Image(systemName: "mic")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
        case .listening:
            Waveform(meter: model.dictationMeter, bars: 9, width: 45, reduceMotion: model.reduceMotion)
        case .handsFree:
            ZStack(alignment: .topLeading) {
                Color.clear
                if let cancel = layout.cancel {
                    roundButton("xmark", filled: false, hovered: model.hover == .cancel)
                        .frame(width: cancel.width, height: cancel.height)
                        .offset(x: cancel.minX - pill.minX, y: cancel.minY - pill.minY)
                }
                Waveform(meter: model.dictationMeter, bars: 8, width: 40, reduceMotion: model.reduceMotion)
                    .frame(width: pill.width, height: pill.height)
                if let finish = layout.finish {
                    roundButton("checkmark", filled: true, hovered: model.hover == .finish)
                        .frame(width: finish.width, height: finish.height)
                        .offset(x: finish.minX - pill.minX, y: finish.minY - pill.minY)
                }
            }
        case .processing:
            ThinkingDots(reduceMotion: model.reduceMotion)
        case .error:
            Text("Try again")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        case .meeting:
            ZStack(alignment: .topLeading) {
                Color.clear
                Waveform(meter: model.meetingMeter, bars: 5, width: 24, reduceMotion: model.reduceMotion)
                    .frame(width: 24, height: 24)
                    .offset(x: 7, y: (pill.height - 24) / 2)
                if let stop = layout.meetingStop {
                    stopButton(hovered: model.hover == .meetingStop)
                        .frame(width: stop.width, height: stop.height)
                        .offset(x: stop.minX - pill.minX, y: stop.minY - pill.minY)
                }
            }
        }
    }

    // MARK: Buttons

    private func roundButton(_ symbol: String, filled: Bool, hovered: Bool) -> some View {
        ZStack {
            Circle().fill(filled ? Color.white : Color.white.opacity(hovered ? 0.28 : 0.16))
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(filled ? Self.ink : .white)
        }
        .opacity(filled && hovered ? 0.85 : 1)
    }

    private func stopButton(hovered: Bool) -> some View {
        ZStack {
            Circle().fill(Theme.recording.opacity(hovered ? 1 : 0.85))
            RoundedRectangle(cornerRadius: 1.5).fill(.white).frame(width: 7, height: 7)
        }
    }

    private var recordButton: some View {
        let hovered = model.hover == .record
        return ZStack {
            Circle().fill(Self.ink)
            Circle().strokeBorder(hovered ? Color.white.opacity(0.4) : Self.rim, lineWidth: 1.5)
            // A ring with a filled centre (Wispr's "disc" Notetaker icon), 14 pt.
            Circle().strokeBorder(.white, lineWidth: 1.5).frame(width: 14, height: 14)
            Circle().fill(.white).frame(width: 5, height: 5)
        }
        .opacity(hovered ? 1 : 0.9)
    }
}

// MARK: - Waveform

/// White bars whose height follows the meter's `audioScale` (≥ 1). With no meter, or before any audio has
/// arrived, the bars are dim, still dots.
private struct Waveform: View {
    let meter: LevelMeter?
    let bars: Int
    let width: CGFloat
    let reduceMotion: Bool

    /// A fixed speech-like profile, so the bars don't all move in lockstep.
    private static let profile: [CGFloat] = [0.45, 0.75, 1.0, 0.65, 0.9, 0.55, 0.8, 0.5, 0.7]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: meter == nil)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let scale = meter?.audioScale(at: time) ?? 1
            let active = meter?.micActive ?? false
            let barWidth: CGFloat = 2
            let spacing = bars > 1 ? (width - CGFloat(bars) * barWidth) / CGFloat(bars - 1) : 0
            HStack(spacing: spacing) {
                ForEach(0..<bars, id: \.self) { i in
                    let shape = Self.profile[i % Self.profile.count]
                    let wobble = reduceMotion ? 1 : 0.8 + 0.2 * sin(time * 8 + Double(i) * 1.3)
                    let lift = active ? (scale - 1) * 4 * shape * CGFloat(wobble) : 0
                    Capsule()
                        .fill(Color.white.opacity(active ? 0.95 : 0.45))
                        .frame(width: barWidth, height: min(16, barWidth + lift))
                }
            }
            .frame(width: width, height: 16)
        }
    }
}

/// Three dots pulsing in turn while transcribing.
private struct ThinkingDots: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(.white)
                        .frame(width: 4.5, height: 4.5)
                        .opacity(reduceMotion ? 0.7 : 0.3 + 0.7 * max(0, sin(t * 5 - Double(i) * 0.8)))
                }
            }
        }
    }
}

// MARK: - Tooltip

/// A dark label centred above the element it describes.
private struct TooltipBubble: View {
    let tooltip: FlowBarModel.Tooltip
    let anchor: (rect: CGRect, offset: CGFloat)

    @State private var size: CGSize = .zero

    var body: some View {
        text
            .font(.system(size: 11))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.1)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.15)))
            .background(GeometryReader { proxy in
                Color.clear.onAppear { size = proxy.size }.onChange(of: proxy.size) { _, new in size = new }
            })
            .offset(x: x, y: anchor.rect.minY - anchor.offset - size.height)
            .opacity(size == .zero ? 0 : 1)
    }

    /// Centred on the anchor, kept inside the canvas.
    private var x: CGFloat {
        let centred = anchor.rect.midX - size.width / 2
        return min(max(4, centred), FlowBarLayout.canvas.width - size.width - 4)
    }

    private var text: Text {
        tooltip.runs.reduce(Text("")) { result, run in
            result + Text(run.text).fontWeight(run.bold ? .semibold : .regular).foregroundColor(run.color)
        }
    }
}
