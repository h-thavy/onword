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

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            openSettings("Privacy_Microphone")
            return false
        }
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openSettings("Privacy_Accessibility") }
    }

    static func requestInputMonitoring() {
        if !CGRequestListenEventAccess() { openSettings("Privacy_ListenEvent") }
    }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
