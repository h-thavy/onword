import AppKit
import ApplicationServices
import OnwordCore
import SwiftUI

/// The floating Notepad (Wispr Flow's "Meeting Recorder" window): opens on the right 30% of the screen
/// (at least 500 wide), full height, when Notetaker starts. A normal window, not always on top.
@MainActor
final class NotepadWindow: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = NotepadWindow()

    @Published private(set) var showingMeetingID: UUID?
    @Published var tab: NoteTab = .notes
    private var window: NSWindow?
    /// The app that was in front before Onword (the meeting app, for split screen).
    private var lastOtherApp: NSRunningApplication?

    override private init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                          queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { NotepadWindow.shared.lastOtherApp = app }
        }
    }

    var isVisible: Bool { window?.isVisible == true }

    /// Shows a note. `focus` brings it to the front; otherwise it appears without taking focus from the call.
    func show(_ id: UUID, focus: Bool = true, tab: NoteTab? = nil) {
        let isNew = window == nil
        let window = window ?? makeWindow()
        self.window = window
        if showingMeetingID != id || tab != nil {
            let meeting = MeetingStore.shared.meeting(id)
            self.tab = tab ?? (meeting?.status == .ready || meeting?.status == .processing ? .summary : .notes)
        }
        showingMeetingID = id
        if isNew || !window.isVisible { window.setFrame(Self.defaultFrame(), display: true) }
        window.title = "Meeting Recorder"
        if focus {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    func close() {
        window?.orderOut(nil)
        showingMeetingID = nil
    }

    /// Back to the Hub's Notetaker page; the Notepad closes unless it's recording.
    func goHome() {
        if let id = showingMeetingID, MeetingRecorder.shared.currentID != id { close() }
        WindowManager.shared.show(.notetaker)
        HubRouter.shared.selectedMeetingID = nil
    }

    /// Right edge of the work area, 30% wide (at least 500), full height.
    private static func defaultFrame() -> NSRect {
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(area.width, max(500, (area.width * 0.3).rounded()))
        return NSRect(x: area.maxX - width, y: area.minY, width: width, height: area.height)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: Self.defaultFrame(),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let hosting = NSHostingController(rootView: NotepadView(window: self))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar gives the 52-pt header with the traffic lights centred in it.
        let toolbar = NSToolbar(identifier: "OnwordNotepad")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 500, height: 600)
        window.backgroundColor = NSColor(Theme.page)
        window.appearance = Appearance.current.nsAppearance
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        showingMeetingID = nil
    }

    // MARK: - Split screen

    /// "Split screen with meeting": the meeting app on the left, the Notepad docked on the right.
    func splitScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        guard AXIsProcessTrusted() else {
            FlowBarIsland.shared.show(.init(title: "Allow Accessibility access for Onword to arrange windows.",
                                            kind: .condensed, timeout: 5))
            return
        }
        let area = screen.visibleFrame
        let width = min(area.width / 2, max(500, (area.width * 0.3).rounded()))
        let pid = MeetingDetector.shared.findMeeting()?.pid ?? lastOtherApp?.processIdentifier
        if let pid {
            let app = AXUIElementCreateApplication(pid)
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
               let target = focused, CFGetTypeID(target) == AXUIElementGetTypeID() {
                let element = target as! AXUIElement
                // AX positions are measured from the top-left of the main screen.
                let mainHeight = NSScreen.screens.first?.frame.height ?? area.maxY
                var origin = CGPoint(x: area.minX, y: mainHeight - area.maxY)
                var size = CGSize(width: area.width - width - 1, height: area.height)
                if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) }
                if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            window.setFrame(NSRect(x: area.maxX - width, y: area.minY, width: width, height: area.height), display: true, animate: true)
        }
    }
}

/// The Notepad's content: a 52-pt header, then the title, pills, tabs and composer in a 744-pt column.
private struct NotepadView: View {
    @ObservedObject var window: NotepadWindow
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var calendar = CalendarService.shared

    var body: some View {
        ZStack(alignment: .top) {
            Theme.page.ignoresSafeArea()
            if let id = window.showingMeetingID, let meeting = store.meeting(id) {
                VStack(alignment: .leading, spacing: 0) {
                    NoteTitleField(meetingID: id).padding(.top, 12)
                    NotePills(meeting: meeting).padding(.horizontal, 12).padding(.bottom, 12)
                    NoteBody(meetingID: id, tab: $window.tab)
                }
                .frame(maxWidth: 744)
                .padding(.horizontal, 20)
                .padding(.top, 52)
                .frame(maxWidth: .infinity)
                header(meeting)
            }
        }
        .ignoresSafeArea()
        .font(Theme.sans(15))
        .foregroundStyle(Theme.ink)
        .background(KeyHandler { window.goHome() })
    }

    private func header(_ meeting: Meeting) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 72, height: 12)   // the traffic lights
            HeaderIconButton(icon: "chevron.left", help: "All notes", filled: true) { window.goHome() }
            Spacer()
            NoteMoreMenu(meeting: meeting) { window.close() }
            HeaderIconButton(icon: "rectangle.split.2x1", help: "Split screen with meeting") { window.splitScreen() }
            if calendar.source == .none {
                Button {
                    WindowManager.shared.show()
                    HubRouter.shared.settingsTab = .connections
                } label: {
                    Label("Connect calendar", systemImage: "calendar").font(Theme.sans(15, .semibold))
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(MeetingRecorder.shared.currentID == meeting.id ? Theme.buttonFill : NT.orange100))
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plainPointer)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }
}

/// Esc in the Notepad goes back to the Hub (as in Wispr Flow).
private struct KeyHandler: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = EscapeView()
        view.onEscape = onEscape
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? EscapeView)?.onEscape = onEscape }

    final class EscapeView: NSView {
        var onEscape: (() -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.keyCode == 53, event.window === self.window,
                      !(event.window?.firstResponder is NSTextView) else { return event }
                self.onEscape?()
                return nil
            }
        }
    }
}
