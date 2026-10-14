import AppKit
import AVFoundation
import SwiftUI

/// First-run setup: welcome → permissions → microphone test → shortcut → practice dictation → done.
enum Onboarding {
    static var isComplete: Bool {
        get { UserDefaults.standard.bool(forKey: "onboardingComplete") }
        set { UserDefaults.standard.set(newValue, forKey: "onboardingComplete") }
    }
}

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, permissions, microphone, shortcut, tryIt, done
    }

    @State private var step: Step = .welcome

    var body: some View {
        VStack(spacing: 0) {
            ProgressDots(current: step.rawValue, total: Step.allCases.count)
                .padding(.top, 34)
            Group {
                switch step {
                case .welcome: WelcomeStep(next: next)
                case .permissions: PermissionsStep(next: next)
                case .microphone: MicrophoneStep(next: next)
                case .shortcut: ShortcutStep(next: next)
                case .tryIt: TryItStep(next: next)
                case .done: DoneStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 56)
            .padding(.bottom, 34)
        }
        .frame(width: 780, height: 580)
        .background(Theme.panel)
        .font(Theme.sans(14))
        .foregroundStyle(Theme.ink)
        .animation(.easeOut(duration: 0.2), value: step)
    }

    private func next() {
        if let following = Step(rawValue: step.rawValue + 1) { step = following }
    }
}

// MARK: - Shared pieces

private struct ProgressDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Capsule().fill(i <= current ? Theme.ink : Theme.selected)
                    .frame(width: i == current ? 22 : 7, height: 7)
            }
        }
    }
}

private struct StepHeader: View {
    let title: String
    let italic: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Text("\(title)\(Text(italic).font(Theme.serif(38, italic: true)))")
                .font(Theme.serif(38))
                .multilineTextAlignment(.center)
            Text(message).font(Theme.sans(15)).foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        .padding(.top, 34)
    }
}

private struct StepFooter: View {
    var back: String?
    var backAction: (() -> Void)?
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        HStack {
            if let back, let backAction {
                Button(back, action: backAction).buttonStyle(.plain).foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
            Button(title, action: action).buttonStyle(.pill).disabled(!enabled).opacity(enabled ? 1 : 0.4)
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let next: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 120, height: 120)
            StepHeader(title: "Speak, and it’s ", italic: "written",
                       message: "Onword turns your voice into text in any app, and takes notes in your meetings. Everything runs on this Mac — nothing you say leaves it.")
                .padding(.top, -20)
            Spacer()
            StepFooter(title: "Get started", action: next)
        }
    }
}

private struct PermissionsStep: View {
    let next: () -> Void
    @State private var mic = Permissions.microphone
    @State private var accessibility = Permissions.accessibility
    @State private var input = Permissions.inputMonitoring
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(title: "Three quick ", italic: "permissions",
                       message: "macOS asks you to allow these once. Onword only listens while you hold your shortcut or record a meeting.")
            SettingsCard {
                row("Microphone", "To hear you.", mic) { Task { _ = await Permissions.requestMicrophone() } }
                row("Accessibility", "To put text where your cursor is.", accessibility) { Permissions.requestAccessibility() }
                row("Input Monitoring", "To notice your shortcut in other apps. macOS may ask to reopen Onword.", input, last: true) {
                    Permissions.requestInputMonitoring()
                }
            }
            .frame(maxWidth: 560)
            Text("In System Settings, switch Onword on, then come back here.")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
            Spacer()
            StepFooter(title: allGranted ? "Continue" : "Continue anyway", action: next)
        }
        .onReceive(timer) { _ in
            mic = Permissions.microphone
            accessibility = Permissions.accessibility
            input = Permissions.inputMonitoring
            DictationController.shared.refreshPermissions()
        }
    }

    private var allGranted: Bool { mic && accessibility && input }

    private func row(_ title: String, _ detail: String, _ granted: Bool, last: Bool = false,
                     request: @escaping () -> Void) -> some View {
        SettingsRow(title: title, detail: detail, last: last) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").font(Theme.sans(13, .semibold))
                    .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 0.35))
            } else {
                Button("Allow", action: request).buttonStyle(.pill)
            }
        }
    }
}

/// Live level meter on the chosen microphone; turns green once it clearly hears speech.
private struct MicrophoneStep: View {
    let next: () -> Void
    @ObservedObject private var dictation = DictationController.shared
    @State private var recorder = AudioRecorder()
    @State private var level: Float = 0
    @State private var heardSpeech: Double = 0     // seconds of speech-level audio heard
    @State private var error: String?
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var heard: Bool { heardSpeech >= 1.0 }

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(title: "Let’s test your ", italic: "microphone",
                       message: "Say a few words at your normal volume — like “testing, one, two, three”.")
            VStack(spacing: 18) {
                HStack {
                    Text("Microphone").font(Theme.sans(14, .medium))
                    Spacer()
                    Picker("", selection: Binding(get: { dictation.microphoneUID }, set: { uid in
                        dictation.microphoneUID = uid
                        restart()
                    })) {
                        Text("System default (\(AudioDevices.defaultInput?.name ?? "none"))").tag(String?.none)
                        ForEach(AudioDevices.inputs()) { device in Text(device.name).tag(Optional(device.uid)) }
                    }
                    .labelsHidden().frame(maxWidth: 300)
                }
                Meter(level: level, heard: heard)
                HStack(spacing: 8) {
                    if heard {
                        Label("We can hear you", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 0.35))
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        Text("Listening…").foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer()
                }
                .font(Theme.sans(13.5, .semibold))
                if active?.isBluetooth == true {
                    Text("Bluetooth mics like AirPods switch to call-quality audio while recording and can miss your first word. Your Mac’s built-in mic is usually more reliable.")
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
                }
            }
            .padding(22)
            .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium).strokeBorder(Theme.border))
            .frame(maxWidth: 560)
            Spacer()
            StepFooter(title: heard ? "Sounds good" : "Skip for now") {
                _ = recorder.stop()
                next()
            }
        }
        .onAppear(perform: start)
        .onDisappear { _ = recorder.stop() }
        .onReceive(timer) { _ in
            level = recorder.level
            if level > 0.12 { heardSpeech += 0.05 }
        }
    }

    private var active: AudioDevices.Device? {
        dictation.microphoneUID.flatMap { AudioDevices.device(uid: $0) } ?? AudioDevices.defaultInput
    }

    private func start() {
        recorder.keepsSamples = false
        do {
            try recorder.start()
            error = nil
        } catch {
            self.error = Permissions.microphone ? error.localizedDescription : "Allow microphone access first."
        }
    }

    private func restart() {
        _ = recorder.stop()
        heardSpeech = 0
        start()
    }
}

private struct Meter: View {
    let level: Float
    let heard: Bool
    private let bars = 28

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<bars, id: \.self) { i in
                let lit = Float(i) / Float(bars) < min(1, level * 0.9)
                Capsule()
                    .fill(lit ? (heard ? Color(red: 0.25, green: 0.55, blue: 0.35) : Theme.ink) : Theme.selected)
                    .frame(height: 26)
            }
        }
        .animation(.easeOut(duration: 0.06), value: level)
    }
}

private struct ShortcutStep: View {
    let next: () -> Void
    @ObservedObject private var dictation = DictationController.shared
    @State private var shownAt = Date()

    private var detected: Bool { (dictation.lastHotkeyPress ?? .distantPast) > shownAt }

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(title: "Your dictation ", italic: "shortcut",
                       message: "Hold it and talk, let go and the text appears. Double-tap it for hands-free.")
            VStack(spacing: 10) {
                ForEach(HotkeyMonitor.Key.allCases) { key in
                    Button {
                        dictation.hotkey = key
                        shownAt = Date()
                    } label: {
                        HStack {
                            Image(systemName: dictation.hotkey == key ? "largecircle.fill.circle" : "circle")
                            Text(key.title).font(Theme.sans(14.5, .medium))
                            Spacer()
                            if key == .fn, GlobeKey.conflict != nil {
                                Text("conflicts with your 🌐 key").font(Theme.sans(12)).foregroundStyle(.orange)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: Theme.radiusMedium)
                            .fill(dictation.hotkey == key ? Theme.selected : Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium).strokeBorder(Theme.border))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 6) {
                    if detected {
                        Label("Detected — that’s your key", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 0.35))
                    } else {
                        Text("Press").foregroundStyle(Theme.inkTertiary)
                        KeyChip(text: dictation.hotkey.chip)
                        Text("once to check it works.").foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer()
                    if dictation.hotkey == .fn, GlobeKey.conflict != nil {
                        Button("Fix 🌐 key") { GlobeKey.openKeyboardSettings() }.buttonStyle(.pillQuiet)
                    }
                }
                .font(Theme.sans(13.5, .semibold))
                .padding(.top, 4)
            }
            .frame(maxWidth: 560)
            Spacer()
            StepFooter(title: detected ? "Continue" : "Continue anyway", action: next)
        }
        .onAppear { shownAt = Date() }
    }
}

/// A practice box: dictation inserts straight into it.
private struct TryItStep: View {
    let next: () -> Void
    @ObservedObject private var dictation = DictationController.shared
    @State private var text = ""

    var body: some View {
        VStack(spacing: 18) {
            StepHeader(title: "Now ", italic: "try it",
                       message: "Click in the box, hold \(dictation.hotkey.title), and say: “Hi, I’m trying Onword for the first time. It’s pretty fast.”")
            if dictation.state == .loadingModel {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(dictation.modelStatus).font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
                }
            }
            PlainTextEditor(text: $text, font: NSFont(name: "Figtree", size: 17) ?? .systemFont(ofSize: 17),
                            placeholder: "Your words will appear here…", documentID: "try-it")
                .frame(maxWidth: 600, maxHeight: 150)
                .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium)
                    .strokeBorder(dictation.state == .recording ? Theme.ink : Theme.border, lineWidth: dictation.state == .recording ? 2 : 1))
            HStack(spacing: 6) {
                switch dictation.state {
                case .recording: Label("Listening…", systemImage: "waveform").foregroundStyle(Theme.ink)
                case .transcribing: Label("Writing…", systemImage: "ellipsis").foregroundStyle(Theme.ink)
                default:
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label("That’s it — it works anywhere you can type.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 0.35))
                    }
                }
            }
            .font(Theme.sans(13.5, .semibold))
            .frame(height: 20)
            Spacer()
            StepFooter(title: text.isEmpty ? "Skip" : "Continue", action: next)
        }
    }
}

private struct DoneStep: View {
    @ObservedObject private var dictation = DictationController.shared

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(title: "You’re ", italic: "all set",
                       message: "Onword lives in your menu bar. A few things worth knowing:")
            SettingsCard {
                tip("Hold \(dictation.hotkey.title)", "Dictate in any app. Double-tap for hands-free, Esc to cancel.")
                tip("⌃⌥S", "Open Scratchpad for quick notes.")
                tip("⌃⌥M", "Start or stop Notetaker in a call. Onword can also notice calls and ask.", last: true)
            }
            .frame(maxWidth: 560)
            Spacer()
            StepFooter(title: "Open Onword") {
                Onboarding.isComplete = true
                WindowManager.shared.closeOnboarding()
                WindowManager.shared.show(.dictation)
            }
        }
    }

    private func tip(_ key: String, _ text: String, last: Bool = false) -> some View {
        SettingsRow(title: text, last: last) { KeyChip(text: key) }
    }
}
