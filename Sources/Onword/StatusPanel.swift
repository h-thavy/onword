import AppKit
import SwiftUI

/// The floating "pill" near the bottom of the screen. It's a non-activating panel that ignores the
/// mouse, so it never steals focus from the app you're dictating into.
@MainActor
final class StatusPanel {
    private let panel: NSPanel
    private let size = NSSize(width: 150, height: 44)

    init(controller: DictationController) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: StatusPill(controller: controller))
    }

    func show() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// The Flow Bar: a small near-black pill with thin white waveform bars while listening and
/// pulsing dots while transcribing.
private struct StatusPill: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        HStack(spacing: 8) {
            switch controller.state {
            case .recording:
                if controller.isHandsFree {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                }
                Waveform(level: controller.level)
            case .transcribing:
                ThinkingDots()
            default:
                Text(controller.statusText).font(Theme.sans(12, .medium)).foregroundStyle(.white).lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Capsule().fill(Color(white: 0.1)).overlay(Capsule().strokeBorder(.white.opacity(0.12))))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Waveform: View {
    var level: Float
    // Fixed per-bar shape so the waveform looks like speech, scaled by the live level.
    private let shape: [Float] = [0.35, 0.6, 0.9, 0.7, 1.0, 0.8, 0.55, 0.85, 0.6, 0.4, 0.7, 0.5]
    @State private var phase = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(shape.indices, id: \.self) { i in
                    let wobble = Float(0.75 + 0.25 * sin(t * 9 + Double(i) * 0.9))
                    let height = 3 + 17 * CGFloat(min(1, level * 1.8 * shape[i] * wobble))
                    Capsule().fill(.white).frame(width: 2.5, height: height)
                }
            }
            .frame(height: 20)
            .animation(.easeOut(duration: 0.08), value: level)
        }
    }
}

private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(.white)
                        .frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.8)))
                }
            }
            .frame(width: 60, height: 20)
        }
    }
}
