import AppKit
import Carbon.HIToolbox
import SwiftUI
import os

/// Onword is a menu-bar app, so its windows are created and shown by hand.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    /// The one main window (the "Hub"), created on first use.
    private var hub: NSWindow?

    /// Opens the Hub on a page.
    func show(_ page: HubRouter.Page? = nil) {
        // Setup can't be skipped: until it's finished, opening Onword brings setup back.
        if !Onboarding.isComplete, ProcessInfo.processInfo.environment["ONWORD_TEST_MEETING"] == nil {
            showOnboarding()
            return
        }
        if let page { HubRouter.shared.page = page }
        let window = hub ?? makeHub()
        hub = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private var onboarding: NSWindow?

    /// First-run setup: permissions, microphone test, shortcut, and a practice dictation.
    func showOnboarding() {
        let window = onboarding ?? {
            // First-run setup has no close button; running it again from Settings does.
            let style: NSWindow.StyleMask = Onboarding.isComplete
                ? [.titled, .closable, .fullSizeContentView] : [.titled, .fullSizeContentView]
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
                                  styleMask: style, backing: .buffered, defer: false)
            window.contentViewController = NSHostingController(rootView: OnboardingView())
            window.title = "Welcome to Onword"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(Theme.frame)
            window.appearance = Appearance.current.nsAppearance
            window.center()
            return window
        }()
        onboarding = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closeOnboarding() {
        DictationController.shared.clearPracticeSink(owner: nil)
        DictationController.shared.hotkeyTestMode = false
        onboarding?.close()
        onboarding = nil
    }

    /// Re-applies the Light/Dark/System choice to the Hub.
    func applyAppearance() {
        hub?.appearance = Appearance.current.nsAppearance
        onboarding?.appearance = Appearance.current.nsAppearance
    }

    private func makeHub() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: HubView())
        window.title = "Onword"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(Theme.frame)
        window.appearance = Appearance.current.nsAppearance
        window.delegate = self
        window.setFrameAutosaveName("Onword.Hub")
        if !window.setFrameUsingName("Onword.Hub") { window.center() }
        return window
    }

    /// Debug aid: `kill -USR1 <pid>` writes PNGs of Onword's open windows to /tmp/onword-snapshots.
    /// Renders from the app's own views, so it needs no Screen Recording permission.
    func installSnapshotSignal() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.snapshotWindows() } }
        source.resume()
        snapshotSource = source
    }

    private var snapshotSource: DispatchSourceSignal?

    private func snapshotWindows() {
        let folder = URL(fileURLWithPath: "/tmp/onword-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for window in NSApp.windows where window.isVisible && window.contentView != nil {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window == hub ? "Hub-\(HubRouter.shared.page.rawValue)" : (window.title.isEmpty ? "window-\(window.windowNumber)" : window.title)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent("\(name).png"))
        }
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow == hub { NotesStore.shared.flush() }
    }
}

/// System-wide shortcuts registered with Carbon's RegisterEventHotKey. Unlike the dictation event tap,
/// these consume the keystroke, so the shortcut doesn't also type a character into the focused app.
final class GlobalShortcuts {
    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "shortcuts")
    static let shared = GlobalShortcuts()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    /// - Parameters:
    ///   - keyCode: virtual key code, e.g. `kVK_ANSI_S`
    ///   - modifiers: Carbon modifier mask, e.g. `optionKey`
    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = UInt32(handlers.count + 1)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F4E_5744), id: id)  // 'ONWD'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            handlers[id] = action
        } else {
            log.error("Shortcut key \(keyCode) mods \(modifiers) could not be registered (\(status)); another app may own it")
        }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let action = GlobalShortcuts.shared.handlers[hotKeyID.id]
            DispatchQueue.main.async { action?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
