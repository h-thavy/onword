import AppKit
import Combine
import SwiftUI

/// The Flow Bar: a small bar centred above the Dock that shows dictation and Notetaker at a glance and
/// offers a mic button (hands-free dictation) and a record button (Notetaker) on hover.
///
/// It lives in a transparent, non-activating panel that ignores the mouse everywhere except over the bar
/// itself, so it never takes focus from the app you're dictating into or blocks clicks around it.
@MainActor
final class FlowBar {
    static let shared = FlowBar()

    /// "Show Flow Bar at all times" (Settings ▸ General). Off hides the resting bar; it still appears while
    /// you dictate or Notetaker records.
    static let showKey = "showFlowBar"
    /// Posted by Settings when `showFlowBar` changes.
    private static let settingChanged = Notification.Name("Onword.flowBarSettingChanged")
    /// How long the error flash lasts.
    private static let errorDuration: TimeInterval = 0.5
    /// How long the pointer rests on a button before its tooltip appears.
    private static let tooltipDelay: TimeInterval = 0.35

    let model = FlowBarModel()

    private var panel: NSPanel?
    private var subscriptions: Set<AnyCancellable> = []
    private var mouseMonitors: [Any] = []
    private var hovered = false
    private var errorUntil: Date?
    private var errorTimer: Timer?
    private var hiddenUntil: Date?
    private var hiddenTimer: Timer?
    private var tooltipTimer: Timer?
    private var wasDictating = false
    private var wasInMeeting = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard panel == nil else { return }
        let panel = FlowBarPanel(
            contentRect: NSRect(origin: .zero, size: FlowBarLayout.canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Above the Dock, below menus and alerts.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true   // keep hover tracking while the bar takes the pointer
        panel.isReleasedWhenClosed = false

        let content = FlowBarContentView(frame: NSRect(origin: .zero, size: FlowBarLayout.canvas))
        let host = NSHostingView(rootView: FlowBarView(model: model))
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        let catcher = FlowBarClickCatcher(frame: content.bounds)
        catcher.autoresizingMask = [.width, .height]
        catcher.bar = self
        content.addSubview(catcher)
        panel.contentView = content
        self.panel = panel

        let dictation = DictationController.shared
        let meetings = MeetingRecorder.shared
        dictation.$state.combineLatest(dictation.$isHandsFree)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &subscriptions)
        meetings.$currentID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: Self.settingChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshVisibility() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &subscriptions)
        // The Dock can appear, hide or move without a screen-parameters change; the active Space
        // switching is a good moment to re-check.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &subscriptions)

        // Mouse-moved events for the whole screen (no permission needed) while the pointer is elsewhere,
        // and our own while it's over the bar.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) { mouseMonitors.append(local) }

        refreshVisibility()

        // Test hook: ONWORD_TEST_FLOWBAR=ready|listening|handsFree|processing|error|meeting forces a mode
        // for snapshots.
        if let forced = ProcessInfo.processInfo.environment["ONWORD_TEST_FLOWBAR"] {
            let modes: [String: FlowBarModel.Mode] = ["ready": .ready, "listening": .listening, "handsFree": .handsFree,
                                                      "processing": .processing, "error": .error, "meeting": .meeting]
            if let mode = modes[forced] { forcedMode = mode; update() }
        }
    }

    private var forcedMode: FlowBarModel.Mode?

    /// Re-reads "Show Flow Bar at all times" and the "Hide for 1 hour" timer, then shows or hides the bar.
    func refreshVisibility() {
        if let hiddenUntil, hiddenUntil <= Date() { self.hiddenUntil = nil }
        let enabled = UserDefaults.standard.object(forKey: Self.showKey) as? Bool ?? true
        let concealed = !enabled || hiddenUntil != nil
        if model.concealed != concealed { model.concealed = concealed }
        update()
    }

    /// A 500 ms red flash: dictation couldn't start, or transcription failed.
    func flashError() {
        errorUntil = Date().addingTimeInterval(Self.errorDuration)
        errorTimer?.invalidate()
        errorTimer = Timer.scheduledTimer(withTimeInterval: Self.errorDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.errorUntil = nil
                self?.update()
            }
        }
        update()
    }

    /// Hides the resting bar for an hour (it still appears while dictating or recording).
    func hideForAnHour() {
        hiddenUntil = Date().addingTimeInterval(60 * 60)
        hiddenTimer?.invalidate()
        hiddenTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibility() }
        }
        hovered = false
        refreshVisibility()
    }

    // MARK: - State

    private var isDictating: Bool {
        if case .recording = DictationController.shared.state { return true }
        return false
    }

    /// What the bar should show right now.
    private func currentMode() -> FlowBarModel.Mode {
        let dictation = DictationController.shared
        if let forcedMode { return forcedMode }
        if let errorUntil, errorUntil > Date() { return .error }
        switch dictation.state {
        case .recording: return dictation.isHandsFree ? .handsFree : .listening
        case .transcribing: return .processing
        default: break
        }
        if MeetingRecorder.shared.isRecording { return .meeting }
        if !model.concealed && (hovered || model.menuOpen) { return .ready }
        return .rest
    }

    /// Whether anything is drawn at all.
    private var isVisible: Bool {
        switch model.mode {
        case .rest, .ready: !model.concealed
        default: true
        }
    }

    private func update() {
        guard let panel else { return }
        let dictating = isDictating
        if dictating && !wasDictating { model.dictationMeter.reset() }
        wasDictating = dictating
        let inMeeting = MeetingRecorder.shared.isRecording
        if inMeeting && !wasInMeeting { model.meetingMeter.reset() }
        wasInMeeting = inMeeting

        let mode = currentMode()
        if model.mode != mode {
            let leavingRest = model.mode == .rest
            model.mode = mode   // FlowBarView animates the size change from the bar's bottom centre
            if leavingRest { reposition() }
            // Buttons move or disappear between modes: the old hover target and tooltip no longer apply.
            setHover(hoverTarget())
        }

        if isVisible {
            if !panel.isVisible { reposition(); panel.orderFrontRegardless() }
        } else if panel.isVisible {
            panel.orderOut(nil)
            hovered = false
            setHover(nil)
        }
        updateMouseCapture()
    }

    // MARK: - Pointer

    /// The pointer in the canvas's top-left coordinates, nil when it's off the panel.
    private func pointerInCanvas() -> CGPoint? {
        guard let panel, panel.isVisible else { return nil }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        guard frame.contains(mouse) else { return nil }
        return CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
    }

    private func hoverTarget() -> FlowBarModel.Target? {
        guard let point = pointerInCanvas() else { return nil }
        return model.layout.target(at: point)
    }

    private func pointerMoved() {
        guard let panel, panel.isVisible else { return }
        // Follow the pointer to another display.
        let mouse = NSEvent.mouseLocation
        if !(panel.screen?.frame.contains(mouse) ?? true), NSScreen.screens.contains(where: { $0.frame.contains(mouse) }) {
            reposition()
        }
        let point = pointerInCanvas()
        if !model.concealed {
            let wasHovered = hovered
            let zone = model.layout.hotRect(expanded: wasHovered)
            hovered = point.map { zone.contains($0) } ?? false
            if hovered != wasHovered { update() }
        }
        setHover(hoverTarget())
        updateMouseCapture()
    }

    /// The panel takes clicks only over the bar; everywhere else they fall through to the app below.
    private func updateMouseCapture() {
        guard let panel else { return }
        let capture: Bool
        if !panel.isVisible || model.mode == .rest || model.mode == .processing || model.mode == .error {
            capture = false
        } else if let point = pointerInCanvas() {
            capture = model.layout.hotRect(expanded: true).contains(point)
        } else {
            capture = false
        }
        if panel.ignoresMouseEvents == capture { panel.ignoresMouseEvents = !capture }
    }

    private func setHover(_ target: FlowBarModel.Target?) {
        guard model.hover != target else { return }
        model.hover = target
        tooltipTimer?.invalidate()
        tooltipTimer = nil
        guard let target else {
            model.tooltip = nil
            return
        }
        if model.tooltip != nil {
            // Moving between buttons: switch straight away.
            model.tooltip = tooltip(for: target)
            return
        }
        tooltipTimer = Timer.scheduledTimer(withTimeInterval: Self.tooltipDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.hover == target else { return }
                self.model.tooltip = self.tooltip(for: target)
            }
        }
    }

    private func tooltip(for target: FlowBarModel.Target) -> FlowBarModel.Tooltip? {
        typealias Run = FlowBarModel.Tooltip.Run
        let key = DictationController.shared.hotkey.title
        let runs: [Run]
        switch (target, model.mode) {
        case (.mic, .ready):
            runs = [Run(text: "Click or hold "), Run(text: key, bold: true), Run(text: " to start dictating")]
        case (.mic, .listening):
            runs = [Run(text: "Release "), Run(text: key, bold: true), Run(text: " to paste")]
        case (.mic, .handsFree):
            runs = [Run(text: "Press "), Run(text: key, bold: true), Run(text: " or click ✓ to paste")]
        case (.record, _):
            runs = [Run(text: "Start "), Run(text: "Notetaker", bold: true)]
        case (.cancel, _):
            runs = [Run(text: "Cancel "), Run(text: "esc", bold: true, color: .white.opacity(0.6))]
        case (.finish, _):
            runs = [Run(text: "Finish and paste")]
        case (.meetingNote, _):
            runs = [Run(text: "Open "), Run(text: "Notetaker", bold: true)]
        case (.meetingStop, _):
            runs = [Run(text: "Stop recording")]
        default:
            return nil
        }
        return FlowBarModel.Tooltip(target: target, runs: runs)
    }

    // MARK: - Clicks

    fileprivate func click(at point: CGPoint) {
        guard let target = model.layout.target(at: point) else { return }
        setHover(nil)
        switch target {
        case .mic:
            // Holding the shortcut already records; the mic starts (or finishes) a hands-free dictation.
            if model.mode == .listening { return }
            DictationController.shared.toggleHandsFree()
        case .record:
            MeetingRecorder.shared.start()
        case .cancel:
            DictationController.shared.cancel()
        case .finish:
            DictationController.shared.finishDictation()
        case .meetingNote:
            WindowManager.shared.show(.notetaker)
        case .meetingStop:
            MeetingRecorder.shared.stop()
        }
    }

    fileprivate func rightClick(at point: CGPoint, in view: NSView) {
        let menu = NSMenu()
        let hide = NSMenuItem(title: "Hide for 1 hour", action: #selector(FlowBarMenuTarget.hideForAnHour), keyEquivalent: "")
        let always = NSMenuItem(title: "Show Flow Bar at all times", action: #selector(FlowBarMenuTarget.toggleAlwaysShow), keyEquivalent: "")
        always.state = (UserDefaults.standard.object(forKey: Self.showKey) as? Bool ?? true) ? .on : .off
        let settings = NSMenuItem(title: "Settings…", action: #selector(FlowBarMenuTarget.openSettings), keyEquivalent: "")
        let copy = NSMenuItem(title: "Copy last transcript", action: #selector(FlowBarMenuTarget.copyLast), keyEquivalent: "")
        copy.isEnabled = DictationController.shared.lastText != nil
        for item in [hide, always, settings, copy] { item.target = FlowBarMenuTarget.shared }
        menu.autoenablesItems = false

        // Microphone ▸ Auto-detect / System default / each input, like the Settings dialog.
        let microphones = NSMenu()
        let current = DictationController.shared.microphoneUID
        let choices: [(String, String)] = [("Auto-detect", AudioDevices.automatic), ("System default", AudioDevices.systemDefault)]
            + AudioDevices.inputs().map { ($0.name, $0.uid) }
        for (name, uid) in choices {
            let item = NSMenuItem(title: name, action: #selector(FlowBarMenuTarget.chooseMicrophone(_:)), keyEquivalent: "")
            item.target = FlowBarMenuTarget.shared
            item.representedObject = uid
            item.state = (current ?? AudioDevices.automatic) == uid ? .on : .off
            microphones.addItem(item)
        }
        let microphone = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphone.submenu = microphones

        menu.addItem(hide)
        menu.addItem(always)
        menu.addItem(.separator())
        menu.addItem(microphone)
        menu.addItem(copy)
        menu.addItem(.separator())
        menu.addItem(settings)

        setHover(nil)
        model.menuOpen = true
        update()
        // Blocks until the menu closes.
        menu.popUp(positioning: nil, at: CGPoint(x: point.x, y: point.y), in: view)
        model.menuOpen = false
        pointerMoved()
        update()
    }

    fileprivate func setAlwaysShow(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.showKey)
        refreshVisibility()
    }

    // MARK: - Placement

    /// Centres the canvas above the Dock (or the bottom of the screen when the Dock is hidden or on the
    /// side) of the screen the pointer is on.
    private func reposition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let visible = screen.visibleFrame
        let size = FlowBarLayout.canvas
        let origin = NSPoint(x: (visible.midX - size.width / 2).rounded(), y: visible.minY)
        if panel.frame.origin != origin || panel.frame.size != size {
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }
}

/// Never becomes key or main, so clicking the bar leaves the frontmost app (and its text field) focused.
private final class FlowBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A top-left-origin container, matching the SwiftUI canvas and `FlowBarLayout`.
private final class FlowBarContentView: NSView {
    override var isFlipped: Bool { true }
}

/// Sits over the SwiftUI view and turns clicks into `FlowBar` actions in canvas coordinates.
private final class FlowBarClickCatcher: NSView {
    weak var bar: FlowBar?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        MainActor.assumeIsolated { bar?.click(at: point) }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        MainActor.assumeIsolated { bar?.rightClick(at: point, in: self) }
    }

    override func otherMouseDown(with event: NSEvent) {}
}

/// Objective-C target for the bar's context menu.
@MainActor
private final class FlowBarMenuTarget: NSObject {
    static let shared = FlowBarMenuTarget()

    @objc func hideForAnHour() { FlowBar.shared.hideForAnHour() }

    @objc func toggleAlwaysShow(_ sender: NSMenuItem) {
        FlowBar.shared.setAlwaysShow(sender.state != .on)
    }

    @objc func openSettings() {
        WindowManager.shared.show()
        HubRouter.shared.settingsTab = .system   // where "Show Flow Bar at all times" lives
    }

    @objc func copyLast() { DictationController.shared.copyLastText() }

    @objc func chooseMicrophone(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String { DictationController.shared.microphoneUID = uid }
    }
}
