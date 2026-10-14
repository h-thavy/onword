import AppKit
import SwiftUI

/// The upcoming-meetings drawer that opens above the Flow Bar from the chevron beside the Notetaker
/// button (Wispr Flow's "join drawer"): today's and tomorrow's meetings with Join + Start, plus Start new note.
@MainActor
final class FlowBarDrawer {
    static let shared = FlowBarDrawer()

    private var panel: NSPanel?
    private var outsideClick: Any?
    var isOpen: Bool { panel?.isVisible == true }
    /// Called when the drawer closes on its own (outside click, an action).
    var onClose: (() -> Void)?

    /// Opens the drawer with its bottom edge at `bottom`, centred on `centerX` (screen coordinates).
    func show(centerX: CGFloat, bottom: CGFloat, on screen: NSScreen?) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let size = panel.contentView?.fittingSize ?? NSSize(width: 340, height: 200)
        var origin = NSPoint(x: centerX - size.width / 2, y: bottom)
        if let area = screen?.visibleFrame {
            origin.x = min(max(area.minX + 8, origin.x), area.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        // Clicking anywhere else closes it.
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { FlowBarDrawer.shared.close() }
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
        onClose?()
    }

    private func makePanel() -> NSPanel {
        let panel = DrawerPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = FirstClickHostingView(rootView: MeetingsDrawerView())
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }
}

/// Never takes focus from the app you're in.
private final class DrawerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons work on the first click, without the panel having to become active first.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The drawer's content.
private struct MeetingsDrawerView: View {
    @ObservedObject private var calendar = CalendarService.shared
    @ObservedObject private var google = GoogleCalendar.shared
    @ObservedObject private var recorder = MeetingRecorder.shared

    private var days: [(label: String, meetings: [UpcomingMeeting])] {
        let cal = Calendar.current
        let now = Date()
        let soon = calendar.upcoming.filter { $0.end > now }
        let today = soon.filter { cal.isDateInToday($0.start) || $0.isNow }
        let tomorrow = soon.filter { cal.isDateInTomorrow($0.start) && !$0.isNow }
        return [("Today", Array(today.prefix(4))), ("Tomorrow", Array(tomorrow.prefix(3)))].filter { !$0.meetings.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Upcoming meetings").font(Theme.sans(15, .semibold))
                Spacer()
                Button { FlowBarDrawer.shared.close() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plainPointer).foregroundStyle(Theme.inkTertiary).help("Collapse")
            }

            if calendar.source == .none {
                Text("Connect a calendar to see your meetings here and join them in one click.")
                    .font(Theme.sans(13)).foregroundStyle(Theme.inkTertiary).fixedSize(horizontal: false, vertical: true)
                Button("Connect calendar") {
                    FlowBarDrawer.shared.close()
                    WindowManager.shared.show()
                    HubRouter.shared.settingsTab = .connections
                }
                .buttonStyle(.pillQuiet)
            } else if days.isEmpty {
                Text("You’re all done for today!").font(Theme.sans(14)).foregroundStyle(Theme.inkTertiary)
                    .padding(.vertical, 6)
            } else {
                ForEach(days, id: \.label) { day in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(day.label.uppercased()).font(Theme.sans(11, .semibold)).tracking(0.8)
                            .foregroundStyle(Theme.inkTertiary)
                        ForEach(day.meetings) { row($0) }
                    }
                }
            }

            Rectangle().fill(Theme.border).frame(height: 1)
            Button {
                FlowBarDrawer.shared.close()
                NotetakerFlow.shared.newNote(source: "flow_bar_drawer")
            } label: {
                Label("Start new note", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.pillQuiet)
            .disabled(recorder.isRecording)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .padding(20)   // room for the shadow inside the transparent panel
        .font(Theme.sans(14))
        .foregroundStyle(Theme.ink)
        .environment(\.colorScheme, Appearance.current == .dark ? .dark : .light)
    }

    private func row(_ meeting: UpcomingMeeting) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: meeting.calendarColor)).frame(width: 4, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).font(Theme.sans(14, .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if meeting.isNow {
                        Text("Now").font(Theme.sans(11, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color(red: 0x10 / 255, green: 0xB9 / 255, blue: 0x81 / 255)))
                    }
                    Text("\(meeting.start.formatted(date: .omitted, time: .shortened)) – \(meeting.end.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
                }
            }
            Spacer(minLength: 8)
            Button(meeting.joinURL != nil ? "Join + Start" : "Start notes") {
                FlowBarDrawer.shared.close()
                NotetakerFlow.shared.joinAndStart(meeting)
            }
            .buttonStyle(meeting.isNow ? PillButtonStyle() : PillButtonStyle(prominent: false))
            .controlSize(.small)
            .disabled(recorder.isRecording)
        }
    }
}
