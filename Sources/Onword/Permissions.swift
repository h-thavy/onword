import AppKit
import ApplicationServices
import AVFoundation

/// The three macOS permissions a dictation app needs.
enum Permissions {
    /// Recording your voice.
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    /// Reading the focused text field and posting ⌘V.
    static var accessibility: Bool { AXIsProcessTrusted() }
    /// Seeing the hotkey while other apps are focused.
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    static var allGranted: Bool { microphone && accessibility && inputMonitoring }

    /// A permission Onword sent the user to System Settings to allow. Remembered so the moment it's
    /// granted Onword comes back in front and the Settings window Onword opened goes away, as Wispr does.
    enum PendingRequest {
        case accessibility, microphone, inputMonitoring

        /// Which window the Allow button was in: setup during first run, the Hub's Settings page after.
        enum Origin { case onboarding, settings }

        var granted: Bool {
            switch self {
            case .accessibility: Permissions.accessibility
            case .microphone: Permissions.microphone
            case .inputMonitoring: Permissions.inputMonitoring
            }
        }
    }

    /// The outstanding System Settings request, if any, and where its Allow button was.
    static private(set) var pendingRequest: (request: PendingRequest, origin: PendingRequest.Origin)?

    /// Whether System Settings was already running when Onword opened it — if so it isn't ours to close.
    private static var settingsWasRunning = false

    static func requestMicrophone(from origin: PendingRequest.Origin) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            openSettings("Privacy_Microphone", for: .microphone, from: origin)
            return false
        }
    }

    /// The first time, macOS's own alert adds Onword to the Accessibility list and its "Open System Settings"
    /// button takes you there (closing itself). Opening Settings as well left that alert floating over every
    /// app, so after the first time Onword opens the pane directly instead.
    static func requestAccessibility(from origin: PendingRequest.Origin) {
        guard !AXIsProcessTrusted() else { return }
        let promptedKey = "accessibilityPrompted"
        if !UserDefaults.standard.bool(forKey: promptedKey) {
            UserDefaults.standard.set(true, forKey: promptedKey)
            settingsWasRunning = systemSettings != nil
            pendingRequest = (.accessibility, origin)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        } else {
            openSettings("Privacy_Accessibility", for: .accessibility, from: origin)
        }
    }

    static func requestInputMonitoring(from origin: PendingRequest.Origin) {
        if !CGRequestListenEventAccess() { openSettings("Privacy_ListenEvent", for: .inputMonitoring, from: origin) }
    }

    static func openSettings(_ pane: String, for request: PendingRequest, from origin: PendingRequest.Origin) {
        settingsWasRunning = systemSettings != nil
        pendingRequest = (request, origin)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// System Settings' app, if it's running (its bundle id since macOS 13).
    private static var systemSettings: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first
    }

    /// Called on each permission poll. Once the pending request is granted, quits the System Settings
    /// Onword opened — never one that was already up, never force-quit — and returns where to go back to.
    static func resolvePendingRequest() -> PendingRequest.Origin? {
        guard let pending = pendingRequest, pending.request.granted else { return nil }
        pendingRequest = nil
        if !settingsWasRunning { _ = systemSettings?.terminate() }
        return pending.origin
    }
}
