import AppKit
import AVFoundation
import SwiftUI

/// First-run setup: welcome → download models → permissions → shortcut test → hold-to-talk → hands-free → done.
/// Steps can't be skipped: each one unlocks only after Onword has seen it work.
enum Onboarding {
    /// Developer option: `ONWORD_ONBOARDING_STEP=hotkey` (or `hotkey-pressed`, `holdToTalk`, …) opens setup
    /// at that step on launch, e.g. to check a screen without clicking through.
    static let debugStep = ProcessInfo.processInfo.environment["ONWORD_ONBOARDING_STEP"]

    static var isComplete: Bool {
        get { UserDefaults.standard.bool(forKey: "onboardingComplete") }
        set {
            UserDefaults.standard.set(newValue, forKey: "onboardingComplete")
            if newValue { UserDefaults.standard.removeObject(forKey: "onboardingStep") }
        }
    }

    /// The step reached so far, so setup resumes there after Onword is reopened (e.g. for Input Monitoring).
    static var savedStep: Int? {
        get { isComplete ? nil : UserDefaults.standard.object(forKey: "onboardingStep") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "onboardingStep") }
    }

    /// Quits and reopens Onword. macOS often only applies a new Input Monitoring grant to a fresh launch.
    @MainActor static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let url = Bundle.main.bundleURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }
}

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, download, permissions, hotkey, holdToTalk, handsFree, done
    }

    @State private var step: Step = Self.initialStep

    private static var initialStep: Step {
        if let name = Onboarding.debugStep,
           let step = Step.allCases.first(where: { "\($0)" == name.replacingOccurrences(of: "-pressed", with: "") }) {
            return step
        }
        guard let saved = Onboarding.savedStep.flatMap(Step.init(rawValue:)) else { return .welcome }
        // Later steps need the models and permissions; if one went missing meanwhile, go back to that step.
        let modelsOnDisk = Transcriber.localFolder(for: DictationController.shared.model, downloadBase: AppPaths.models) != nil
            && SpeakerModels.isDownloaded
        if saved.rawValue > Step.download.rawValue, !modelsOnDisk { return .download }
        if saved.rawValue > Step.permissions.rawValue, !Permissions.allGranted { return .permissions }
        return saved
    }

    var body: some View {
        VStack(spacing: 0) {
            ProgressDots(current: step.rawValue, total: Step.allCases.count)
                .padding(.top, 34)
            Group {
                switch step {
                case .welcome: WelcomeStep(next: next)
                case .download: DownloadStep(next: next)
                case .permissions: PermissionsStep(next: next)
                case .hotkey: HotkeyStep(next: next)
                case .holdToTalk: HoldToTalkStep(next: next)
                case .handsFree: HandsFreeStep(next: next)
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
        if let following = Step(rawValue: step.rawValue + 1) {
            step = following
            Onboarding.savedStep = following.rawValue
        }
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
                .multilineTextAlignment(.center).frame(maxWidth: 540)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 22)
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

/// Downloads what Onword needs before it can be used. Starts on its own at launch; this step waits for it.
private struct DownloadStep: View {
    let next: () -> Void
    @ObservedObject private var dictation = DictationController.shared

    private var ready: Bool { dictation.modelReady && dictation.speakerModels == .ready }

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(title: "Getting Onword ", italic: "ready",
                       message: "Onword understands you right here on your Mac, so it downloads its models once. After that it works offline.")
            SettingsCard {
                SettingsRow(title: "Speech model", detail: "Turns your voice into text · \(dictation.model.downloadSize)") { speech }
                SettingsRow(title: "Speaker model", detail: "Tells voices apart in meeting notes · 11 MB") { speaker }
                SettingsRow(title: "Meeting summaries", detail: summariesDetail, last: true) { summaries }
            }
            .frame(maxWidth: 600)
            Text(ready ? "All downloaded." : "Keep Onword open and connected to the internet until this finishes.")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
            Spacer()
            StepFooter(title: "Continue", enabled: ready, action: next)
        }
    }

    @ViewBuilder private var speech: some View {
        if dictation.modelReady {
            done
        } else if let failure = dictation.modelFailure {
            failed(failure) { dictation.retryModel() }
        } else if let progress = dictation.modelProgress, progress < 1 {
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 110).tint(Theme.ink)
                Text("\(Int(progress * 100))%").monospacedDigit().frame(width: 38, alignment: .trailing)
            }
            .font(Theme.sans(13, .semibold))
        } else {
            working(dictation.modelProgress == nil ? "Loading…" : "Preparing…")
        }
    }

    @ViewBuilder private var speaker: some View {
        switch dictation.speakerModels {
        case .ready: done
        case .downloading: working("Downloading…")
        case .failed(let message): failed(message) { dictation.ensureSpeakerModels() }
        }
    }

    /// Apple Intelligence is part of macOS, not something Onword can download, so it's optional here.
    private var summariesDetail: String {
        MeetingSummarizer.shared.unavailableReason.map { "Optional. \($0)" } ?? "Apple Intelligence, built into macOS"
    }

    @ViewBuilder private var summaries: some View {
        if MeetingSummarizer.shared.unavailableReason == nil {
            done
        } else {
            Text("Optional").font(Theme.sans(13, .medium)).foregroundStyle(Theme.inkTertiary)
        }
    }

    private var done: some View {
        Label("Ready", systemImage: "checkmark.circle.fill").font(Theme.sans(13, .semibold))
            .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 0.35))
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(Theme.sans(13, .medium)).foregroundStyle(Theme.inkTertiary)
        }
    }

    private func failed(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(message).font(Theme.sans(12, .medium)).foregroundStyle(.orange)
                .frame(maxWidth: 230, alignment: .trailing).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again", action: retry).buttonStyle(.pillQuiet)
        }
    }
}

private struct PermissionsStep: View {
    let next: () -> Void
    @State private var mic = Permissions.microphone
    @State private var accessibility = Permissions.accessibility
    @State private var input = Permissions.inputMonitoring
    @ObservedObject private var dictation = DictationController.shared
    @State private var inputGrantedAt: Date?
    @State private var now = Date()
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
            if needsRelaunch {
                HStack(spacing: 10) {
                    Text("macOS needs Onword reopened to finish turning on Input Monitoring.")
                        .font(Theme.sans(12.5)).foregroundStyle(.orange)
                    Button("Reopen Onword") { Onboarding.relaunch() }.buttonStyle(.pill)
                }
            } else {
                Text(allGranted ? "All set." : "In System Settings, switch Onword on, then come back here.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
            StepFooter(title: "Continue", enabled: ready, action: next)
        }
        .onReceive(timer) { date in
            now = date
            mic = Permissions.microphone
            accessibility = Permissions.accessibility
            input = Permissions.inputMonitoring
            if input, inputGrantedAt == nil { inputGrantedAt = date }
            DictationController.shared.refreshPermissions()
        }
    }

    private var allGranted: Bool { mic && accessibility && input }
    /// All three allowed and the shortcut listener is live.
    private var ready: Bool { allGranted && dictation.shortcutReady }
    private var needsRelaunch: Bool {
        allGranted && !dictation.shortcutReady && now.timeIntervalSince(inputGrantedAt ?? now) > 4
    }

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

// MARK: - Practice

/// Shows the dictation shortcut, with a small menu to switch keys.
private struct ShortcutLine: View {
    @ObservedObject private var dictation = DictationController.shared

    var body: some View {
        HStack(spacing: 6) {
            Text("Your shortcut").foregroundStyle(Theme.inkTertiary)
            KeyChip(text: dictation.hotkey.chip)
            Menu {
                ForEach(HotkeyMonitor.Key.allCases) { key in
                    Button(key.title + (key == .fn && GlobeKey.conflict != nil ? " (conflicts with 🌐 key)" : "")) {
                        dictation.hotkey = key
                    }
                }
            } label: { Text("Change").font(Theme.sans(12.5, .semibold)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .font(Theme.sans(12.5))
    }
}

/// A mock app window (email, AI chat) with a text box you dictate into.
private struct MockApp<Header: View>: View {
    @Binding var text: String
    let placeholder: String
    let listening: Bool
    @ViewBuilder var header: () -> Header

    var body: some View {
        VStack(spacing: 0) {
            header()
            Divider().overlay(Theme.border)
            PlainTextEditor(text: $text, font: NSFont(name: "Figtree", size: 16) ?? .systemFont(ofSize: 16),
                            placeholder: placeholder, documentID: placeholder)
                .frame(height: 96)
        }
        .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium)
            .strokeBorder(listening ? Theme.ink : Theme.border, lineWidth: listening ? 2 : 1))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
        .frame(maxWidth: 600)
    }
}

/// Live status under a practice box: listening, writing, a hint, or success.
private struct PracticeStatus: View {
    let success: String?
    let hint: String?
    @ObservedObject private var dictation = DictationController.shared

    var body: some View {
        HStack(spacing: 8) {
            switch dictation.state {
            case .recording:
                Label(dictation.isHandsFree ? "Listening hands-free — press the key again to finish" : "Listening… let go when you're done",
                      systemImage: "waveform")
            case .transcribing:
                Label("Writing…", systemImage: "ellipsis")
            case .loadingModel:
                ModelDownloadStatus(compact: false)
            case .error where dictation.modelFailure != nil:
                ModelDownloadStatus(compact: false)
            case .needsPermissions:
                Label("Onword needs its permissions first — go back one step.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            default:
                if let success {
                    Label(success, systemImage: "checkmark.circle.fill").foregroundStyle(Color(red: 0.25, green: 0.55, blue: 0.35))
                } else if let hint {
                    Label(hint, systemImage: "hand.raised").foregroundStyle(.orange)
                }
            }
        }
        .font(Theme.sans(13.5, .semibold))
        .frame(minHeight: 22)
    }
}

/// The speech model's download: a progress bar with a percentage, or what went wrong and a Try again button.
struct ModelDownloadStatus: View {
    let compact: Bool
    @ObservedObject private var dictation = DictationController.shared

    var body: some View {
        Group {
            if let failure = dictation.modelFailure {
                HStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                    Text(failure).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button("Try again") { dictation.retryModel() }.buttonStyle(.pillQuiet)
                }
                .frame(maxWidth: 600)
            } else if dictation.state == .loadingModel {
                HStack(spacing: 10) {
                    if let progress = dictation.modelProgress, progress < 1 {
                        ProgressView(value: progress).frame(width: compact ? 120 : 160).tint(Theme.ink)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(dictation.modelStatus).foregroundStyle(Theme.inkTertiary)
                }
            }
        }
        .font(Theme.sans(compact ? 12 : 13.5, compact ? .medium : .semibold))
        .multilineTextAlignment(.leading)
    }
}

/// Practice 1: hold the key, speak, let go — in a mock email.
private struct HoldToTalkStep: View {
    let next: () -> Void
    @ObservedObject private var dictation = DictationController.shared
    @State private var text = ""
    @State private var shownAt = Date()
    private let owner = UUID()
    /// Set only by a real hold-to-talk dictation (typing in the box doesn't count).
    @State private var done = false
    @State private var usedHandsFree = false

    private var hint: String? {
        if done { return nil }
        if usedHandsFree { return "That was hands-free (double-tap). Here, hold \(dictation.hotkey.title) down while you talk." }
        if (dictation.lastHeardNothing ?? .distantPast) > shownAt {
            return "Didn’t catch that. Speak a little louder, close to your microphone."
        }
        if (dictation.lastQuickTap ?? .distantPast) > shownAt {
            return "Don’t just tap — hold \(dictation.hotkey.title) down while you talk, then let go."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 18) {
            StepHeader(title: "Hold to ", italic: "talk",
                       message: "Hold \(dictation.hotkey.title) down, read this out loud, then let go:")
            Text("“Um, hi Dara, are you free on Friday at three? Scratch that. Are you free on Saturday morning?”")
                .font(Theme.serif(19, italic: true)).multilineTextAlignment(.center).frame(maxWidth: 580)
                .fixedSize(horizontal: false, vertical: true)
            MockApp(text: $text, placeholder: "Hold \(dictation.hotkey.title), speak, and let go…",
                    listening: dictation.state == .recording) {
                VStack(spacing: 0) {
                    mailField("To", "Dara")
                    Divider().overlay(Theme.border)
                    mailField("Subject", "Quick question")
                }
            }
            PracticeStatus(success: done ? "Hold-to-talk works — it’s the same in any app." : nil, hint: hint)
            ShortcutLine()
            Spacer(minLength: 0)
            StepFooter(title: "Next: hands-free", enabled: done, action: next)
        }
        .onAppear {
            shownAt = Date()
            dictation.setPracticeSink(owner: owner) { dictated, handsFree in
                text = text.isEmpty ? dictated : text + " " + dictated
                if handsFree { usedHandsFree = true } else { done = true; usedHandsFree = false }
            }
        }
        .onDisappear { dictation.clearPracticeSink(owner: owner) }
    }

    private func mailField(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(Theme.inkTertiary).frame(width: 56, alignment: .leading)
            Text(value)
            Spacer()
        }
        .font(Theme.sans(13.5))
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}

/// Practice 2: double-tap to start hands-free, press again to finish — in a mock AI chat box.
private struct HandsFreeStep: View {
    let next: () -> Void
    @ObservedObject private var dictation = DictationController.shared
    @State private var text = ""
    @State private var shownAt = Date()
    private let owner = UUID()
    /// Set only by a real hands-free dictation.
    @State private var done = false
    @State private var heldInstead = false

    private var hint: String? {
        if done { return nil }
        if heldInstead { return "That was hold-to-talk. Tap \(dictation.hotkey.title) twice quickly instead, then talk." }
        if (dictation.lastHeardNothing ?? .distantPast) > shownAt {
            return "Didn’t catch that. Speak a little louder, close to your microphone."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 18) {
            StepHeader(title: "Now go ", italic: "hands-free",
                       message: "For longer thoughts, double-tap \(dictation.hotkey.title). Onword keeps listening until you press it once more.")
            HStack(spacing: 10) {
                step("1", "Double-tap")
                Image(systemName: "arrow.right").foregroundStyle(Theme.inkTertiary)
                step("2", "Talk freely")
                Image(systemName: "arrow.right").foregroundStyle(Theme.inkTertiary)
                step("3", "Press once to finish")
            }
            MockApp(text: $text, placeholder: "Brain-dump an idea or a prompt for your AI assistant…",
                    listening: dictation.state == .recording) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Logo.accent)
                    Text("Message your AI assistant").font(Theme.sans(13.5, .medium))
                    Spacer()
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                        .foregroundStyle(text.isEmpty ? Theme.inkTertiary : Theme.ink)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            PracticeStatus(success: done ? "Hands-free works. Great for long messages and prompts." : nil, hint: hint)
            ShortcutLine()
            Spacer(minLength: 0)
            StepFooter(title: "Finish", enabled: done, action: next)
        }
        .onAppear {
            shownAt = Date()
            dictation.setPracticeSink(owner: owner) { dictated, handsFree in
                text = text.isEmpty ? dictated : text + " " + dictated
                if handsFree { done = true; heldInstead = false } else { heldInstead = true }
            }
        }
        .onDisappear { dictation.clearPracticeSink(owner: owner) }
    }

    private func step(_ number: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(number).font(Theme.sans(11, .bold)).foregroundStyle(Theme.onAccent)
                .frame(width: 18, height: 18).background(Circle().fill(Theme.accent))
            Text(label).font(Theme.sans(13, .medium))
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
