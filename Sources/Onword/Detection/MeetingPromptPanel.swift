import AppKit
import SwiftUI

/// A small "Record this call?" card in the top-right corner. It accepts clicks but never takes
/// keyboard focus from the call app.
@MainActor
final class MeetingPromptPanel {
    private var panel: NSPanel?
    private var hideTimer: Timer?

    func show(title: String, message: String, acceptTitle: String = "Record", onChoice: @escaping (Bool) -> Void) {
        hide()
        let size = NSSize(width: 320, height: 104)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PromptCard(title: title, message: message, acceptTitle: acceptTitle) { [weak self] accepted in
            self?.hide()
            onChoice(accepted)
        })
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        // Unanswered prompts go away on their own.
        hideTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct PromptCard: View {
    let title: String
    let message: String
    let acceptTitle: String
    let choose: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle").foregroundStyle(.red)
                Text(title).font(.headline)
            }
            Text(message).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not now") { choose(false) }
                Button(acceptTitle) { choose(true) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
