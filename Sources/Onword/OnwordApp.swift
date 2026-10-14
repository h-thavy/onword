import AppKit
import Carbon.HIToolbox
import OnwordCore
import SwiftUI

@main
struct OnwordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = DictationController.shared
    @ObservedObject private var meetings = MeetingRecorder.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller, meetings: meetings)
        } label: {
            if let icon {
                Image(systemName: icon)
            } else {
                Image(nsImage: Logo.menuBarImage)
            }
        }
    }

    /// A status symbol while something is happening; nil shows the Onword mark.
    private var icon: String? {
        if meetings.isRecording { return "record.circle.fill" }
        return switch controller.state {
        case .recording: "mic.fill"
        case .transcribing: "ellipsis.circle"
        case .needsPermissions, .error: "mic.slash"
        default: nil
        }
    }
}

/// Onword shows in the Dock like a regular app (Settings › System › "Show app in Dock"); off, it lives
/// only in the menu bar.
@MainActor
enum DockIcon {
    static let key = "showInDock"
    static var isShown: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key); apply() }
    }

    static func apply() {
        NSApp.setActivationPolicy(isShown ? .regular : .accessory)
        if !isShown { NSApp.activate(ignoringOtherApps: true) }   // switching to accessory can hide our windows
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Clicking the Dock icon opens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { WindowManager.shared.show() }
        return true
    }

    /// Back from System Settings? Re-check permissions right away, not just on the poll, as Wispr does.
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { DictationController.shared.refreshPermissions() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            DockIcon.apply()
            // Look for a new version shortly after launch, then once a day.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { UpdateChecker.shared.checkIfStale() }
            Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
                MainActor.assumeIsolated { UpdateChecker.shared.check() }
            }
            History.prune()
            DictationController.shared.start()
            FlowBar.shared.start()
            if !Onboarding.isComplete || Onboarding.debugStep != nil {
                WindowManager.shared.showOnboarding()   // asks for permissions step by step
            } else if !Permissions.allGranted {
                DictationController.shared.requestPermissions()
            }

            WindowManager.shared.installSnapshotSignal()
            if let page = ProcessInfo.processInfo.environment["ONWORD_TEST_PAGE"].flatMap(HubRouter.Page.init) {   // test hook
                WindowManager.shared.show(page)
                // ONWORD_TEST_TOGGLE_SIDEBAR=1 presses the sidebar toggle 3 s after launch.
                if ProcessInfo.processInfo.environment["ONWORD_TEST_TOGGLE_SIDEBAR"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { WindowManager.shared.toggleSidebar(nil) }
                }
            }
            if let page = ProcessInfo.processInfo.environment["ONWORD_TEST_SETTINGS"] {   // test hook
                WindowManager.shared.show()
                HubRouter.shared.settingsTab = page == "languages" ? .general : HubRouter.SettingsTab(rawValue: page) ?? .general
            }
            _ = DictionaryStore.shared   // loads (and migrates) the dictionary file
            MeetingDetector.shared.start()
            CalendarService.shared.start()
            NotetakerFlow.shared.runTestHooks()
            if let folder = ProcessInfo.processInfo.environment["ONWORD_TEST_MEETING"] {
                MeetingRecorder.shared.importForTesting(from: URL(fileURLWithPath: folder))
                WindowManager.shared.show(.notetaker)
            }
            ScratchpadWindow.shared.runTestHookIfRequested()   // ONWORD_TEST_SCRATCHPAD

            // ⌃⌥S Scratchpad (⌃ avoids clashing with other dictation apps' ⌥S), ⌥M meeting recording
            // (Wispr Flow's Notetaker shortcut).
            GlobalShortcuts.shared.register(keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey) {
                MainActor.assumeIsolated { ScratchpadWindow.shared.toggle() }
            }
            GlobalShortcuts.shared.register(keyCode: kVK_ANSI_M, modifiers: optionKey) {
                MainActor.assumeIsolated { NotetakerFlow.shared.shortcut() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            NotesStore.shared.flush()
            // Stop cleanly so the audio files are closed; processing resumes via Re-process.
            if MeetingRecorder.shared.isRecording { MeetingRecorder.shared.stop() }
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var meetings: MeetingRecorder
    @ObservedObject var detector = MeetingDetector.shared
    @ObservedObject var updates = UpdateChecker.shared

    var body: some View {
        Button("Open Onword") { WindowManager.shared.show() }
            .keyboardShortcut("o")
        if let version = updates.availableVersion {
            Button("Update to Onword \(version)…") { updates.update() }
        }
        Text(controller.statusText)
        if controller.modelFailure != nil {
            Button("Retry speech model download") { controller.retryModel() }
        }
        if let call = detector.current { Text("In a \(call.platform.title) call") }

        Divider()

        Button(meetings.isRecording ? "Stop Notetaker (\(TimeFormat.clock(meetings.elapsed)))" : "Start Notetaker") {
            meetings.toggle()
            WindowManager.shared.show(.notetaker)
        }
        .keyboardShortcut("m", modifiers: [.option])
        Button("Scratchpad") { ScratchpadWindow.shared.show() }
            .keyboardShortcut("s", modifiers: [.control, .option])
        Button("Copy last transcript") { controller.copyLastText() }
            .disabled(controller.lastText == nil)

        Divider()

        if !Permissions.allGranted {
            Button("⚠︎ Permissions needed…") {
                WindowManager.shared.show()
                HubRouter.shared.settingsTab = .system
            }
        }
        Button("Settings…") {
            WindowManager.shared.show()
            HubRouter.shared.settingsTab = .general
        }
        .keyboardShortcut(",")
        Button("Quit Onword") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
