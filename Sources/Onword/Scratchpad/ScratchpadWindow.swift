import AppKit
import OnwordCore
import SwiftUI

/// The floating Scratchpad: a borderless panel over every app and Space (full-screen ones too) with
/// up to five notes open as tabs. ⌃⌥S shows it at the mouse cursor, brings it to the front, or hides
/// it; its tabs survive hiding. The close button closes every tab.
@MainActor
final class ScratchpadWindow: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = ScratchpadWindow()

    @Published private(set) var tabs = ScratchpadTabs()
    @Published private(set) var isExpanded = false
    @Published var sidebarOpen = UserDefaults.standard.bool(forKey: "scratchpadSidebarOpen") {
        didSet { if testOptions == nil { UserDefaults.standard.set(sidebarOpen, forKey: "scratchpadSidebarOpen") } }
    }
    /// Short message in the top bar ("Copied to clipboard"), cleared after 2 s.
    @Published private(set) var toast: String?
    /// The tab being renamed inline.
    @Published var renamingID: UUID?
    /// A note waiting for "Delete" to be confirmed.
    @Published var confirmingDelete: UUID?
    /// Bumped to put the cursor in the notes search field.
    @Published private(set) var searchFocusRequest = 0

    /// What ⌃⌥S shows when the window was hidden: the last note ("resume", the default) or a new tab.
    enum OpenBehavior: String { case resume, newTab }
    static var openBehavior: OpenBehavior {
        OpenBehavior(rawValue: UserDefaults.standard.string(forKey: "scratchpadOpenBehavior") ?? "") ?? .resume
    }

    private let store = NotesStore.shared
    private var panel: ScratchpadPanel?
    /// Set until the window is placed for the first time, and again after it's closed with X.
    private var needsPlacement = true
    private var toastWork: DispatchWorkItem?
    /// ONWORD_TEST_SCRATCHPAD options; while testing, preferences are left untouched.
    private let testOptions: Set<String>? = ProcessInfo.processInfo.environment["ONWORD_TEST_SCRATCHPAD"].map {
        Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    var activeNote: Note? { store.note(tabs.activeID) }
    var isVisible: Bool { panel?.isVisible == true }
    /// True while the Scratchpad has keyboard focus (the app itself may not be frontmost).
    var isKey: Bool { panel?.isKeyWindow == true }

    /// The text view dictation should type into: the focused field in the panel, else its editor.
    var keyTextView: NSTextView? {
        guard let panel, panel.isKeyWindow else { return nil }
        if let textView = panel.firstResponder as? NSTextView { return textView }
        if let editor = OwnWindowInserter.lastEditor, editor.window === panel { return editor }
        return nil
    }

    // MARK: - Showing and hiding

    /// ⌃⌥S: show at the cursor when hidden, bring to the front when behind, hide when focused.
    func toggle() {
        if let panel, panel.isVisible {
            if panel.isKeyWindow { hide() } else { present() }
            return
        }
        if Self.openBehavior == .newTab, let active = activeNote, !active.isBlank, !tabs.isFull {
            addTab()
        }
        present()
    }

    /// Shows the window with the current tabs (a fresh one if none are open).
    func show() {
        present()
    }

    /// Opens a note in a tab (reusing its tab if it's already open) and shows the window.
    func open(_ id: UUID) {
        if tabs.ids.contains(id) {
            tabs.activate(id)
        } else if let active = activeNote, active.isBlank, let blank = tabs.activeID {
            // An empty tab is replaced rather than kept next to the note.
            tabs.close(blank)
            store.discardIfBlank(blank)
            tabs.add(id)
        } else if let replaced = tabs.open(id) {
            store.flush()
            store.discardIfBlank(replaced)
        }
        present()
    }

    /// A new note in a new tab (or the empty one already showing).
    func newNote() {
        if let active = activeNote, active.isBlank {
            present()
            return
        }
        if tabs.isFull { show(toast: "Close a tab to open another (5 at most)"); present(); return }
        addTab()
        present()
    }

    func hide() {
        store.flush()
        renamingID = nil
        panel?.orderOut(nil)
    }

    /// The X button / ⌘⇧W: saves, closes every tab and hides. The next open starts fresh.
    func closeAll() {
        store.flush()
        for id in tabs.ids { store.discardIfBlank(id) }
        tabs.removeAll()
        renamingID = nil
        confirmingDelete = nil
        panel?.orderOut(nil)
        if let panel, isExpanded { panel.setContentSize(ScratchpadGeometry.defaultSize) }
        needsPlacement = true
    }

    private func present() {
        let panel = panel ?? makePanel()
        self.panel = panel
        if tabs.isEmpty { addTab() }
        panel.appearance = testOptions?.contains("dark") == true
            ? NSAppearance(named: .darkAqua) : Appearance.current.nsAppearance
        if !panel.isVisible, needsPlacement || activeNote?.isBlank != false {
            placeAtCursor(panel)
        }
        needsPlacement = false
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.invalidateShadow()
        focusEditor()
    }

    /// Puts the cursor in the note unless something else in the panel (search, rename) has it.
    func focusEditor() {
        DispatchQueue.main.async { [weak self] in
            guard let panel = self?.panel, let editor = OwnWindowInserter.lastEditor, editor.window === panel,
                  !(panel.firstResponder is NSTextView) || panel.firstResponder === editor else { return }
            panel.makeFirstResponder(editor)
        }
    }

    /// Top-left corner at the mouse, kept inside the visible part of the screen under it.
    private func placeAtCursor(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let size = isExpanded ? ScratchpadGeometry.expandedSize : ScratchpadGeometry.defaultSize
        panel.setFrame(ScratchpadGeometry.frame(topLeft: mouse, size: size, in: screen.visibleFrame), display: false)
    }

    /// Expand (920×660) or compact (500×420), keeping the top-left corner where it is.
    func toggleExpanded() {
        guard let panel else { return }
        let size = isExpanded ? ScratchpadGeometry.defaultSize : ScratchpadGeometry.expandedSize
        let topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        panel.setFrame(ScratchpadGeometry.frame(topLeft: topLeft, size: size, in: visible), display: true, animate: true)
    }

    // MARK: - Tabs

    /// ⌘T: a new empty tab.
    func newTab() {
        guard !tabs.isFull else { show(toast: "Close a tab to open another (5 at most)"); return }
        addTab()
        focusEditor()
    }

    private func addTab() {
        tabs.add(store.create().id)
    }

    func activate(_ id: UUID) {
        renamingID = nil
        tabs.activate(id)
        focusEditor()
    }

    /// ⌘W / a tab's ×. Closing the last tab closes the window.
    func closeTab(_ id: UUID) {
        store.flush()
        store.discardIfBlank(id)
        if renamingID == id { renamingID = nil }
        tabs.close(id)
        if tabs.isEmpty { closeAll() } else { focusEditor() }
    }

    func closeActiveTab() {
        if let id = tabs.activeID { closeTab(id) }
    }

    func rename(_ id: UUID, to title: String) {
        store.rename(id, to: title)
        renamingID = nil
        focusEditor()
    }

    // MARK: - Notes

    func toggleSidebar() {
        sidebarOpen.toggle()
    }

    /// The rail's search button: opens the notes list with the cursor in its search field.
    func startSearch() {
        sidebarOpen = true
        searchFocusRequest += 1
    }

    /// Deletes a note everywhere: its file, and its tab if it's open (an empty tab replaces the last one).
    func delete(_ id: UUID) {
        let wasOpen = tabs.ids.contains(id)
        store.delete(id)
        confirmingDelete = nil
        guard wasOpen else { return }
        tabs.close(id)
        if tabs.isEmpty, isVisible { addTab() }
        if isVisible { show(toast: "Note deleted") }
        focusEditor()
    }

    func copyActiveNote() {
        guard let note = activeNote else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.body, forType: .string)
        show(toast: "Copied to clipboard")
    }

    func show(toast message: String) {
        toastWork?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { toast = message }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeInOut(duration: 0.2)) { self?.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: - Keyboard

    /// In-window shortcuts. Editing keys are handled here too: in a non-activating panel the app may not
    /// be active, so the main menu wouldn't get them.
    fileprivate func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = flags.contains(.shift)
        let others = flags.subtracting([.command, .shift, .capsLock, .numericPad, .function])
        guard others.isEmpty else { return false }
        switch (key, shift) {
        case ("t", false): newTab()
        case ("w", false): closeActiveTab()
        case ("w", true): closeAll()
        case ("e", false): toggleSidebar()
        case ("c", false): return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case ("x", false): return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case ("v", false): return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case ("a", false): return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case ("z", false): return NSApp.sendAction(Selector(("undo:")), to: nil, from: self)
        case ("z", true): return NSApp.sendAction(Selector(("redo:")), to: nil, from: self)
        default: return false
        }
        return true
    }

    // MARK: - Window

    private func makePanel() -> ScratchpadPanel {
        let panel = ScratchpadPanel(
            contentRect: NSRect(origin: .zero, size: ScratchpadGeometry.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = "Scratchpad"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentMinSize = ScratchpadGeometry.minSize
        panel.delegate = self
        panel.onKeyEquivalent = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        let host = NSHostingView(rootView: ScratchpadWindowView())
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel else { return }
        let expanded = ScratchpadGeometry.isExpanded(width: panel.frame.width)
        if expanded != isExpanded { isExpanded = expanded }
        panel.invalidateShadow()
    }

    /// A system close (there's no close button) only hides the window, keeping its tabs.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        store.flush()
    }

    // MARK: - Test hook

    /// `ONWORD_TEST_SCRATCHPAD=1` (sample notes in memory only) opens the window with two tabs at the
    /// screen's top-left area. Comma-separated options: `sidebar`, `expanded`, `empty`, `toast`,
    /// `confirm`, `dark`, `hub` (also opens the Hub's Scratchpad page). Snapshot with `kill -USR1`.
    func runTestHookIfRequested() {
        guard let options = testOptions else { return }
        if options.contains("hub") { WindowManager.shared.show(.scratchpad) }
        sidebarOpen = options.contains("sidebar")
        let notes = store.visible(matching: "")
        if !options.contains("empty") {
            for note in notes.prefix(2) { tabs.add(note.id) }
        }
        let panel = makePanel()
        self.panel = panel
        if tabs.isEmpty { addTab() }
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let size = options.contains("expanded") ? ScratchpadGeometry.expandedSize : ScratchpadGeometry.defaultSize
        panel.setFrame(ScratchpadGeometry.frame(topLeft: CGPoint(x: visible.minX + 80, y: visible.maxY - 80),
                                                size: size, in: visible), display: false)
        needsPlacement = false
        present()
        if options.contains("toast") { toast = "Copied to clipboard" }   // stays up for the snapshot
        if options.contains("confirm") { confirmingDelete = tabs.activeID }
    }
}

/// Borderless panel that can still take keyboard focus (for typing), without becoming the main window.
final class ScratchpadPanel: NSPanel {
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc dismisses renames and the like, but never the window.
    override func cancelOperation(_ sender: Any?) {}
}
