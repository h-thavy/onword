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
        case welcome, permissions, holdToTalk, handsFree, done
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
                ProgressView().controlSize(.small)
                Text(dictation.modelStatus).foregroundStyle(Theme.inkTertiary)
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
        .frame(height: 22)
    }
}

/// Practice 1: hold the key, speak, let go — in a mock email.
private struct HoldToTalkStep: View {
    let next: () -> Void
    @ObservedObject private var dictation = DictationController.shared
    @State private var text = ""
    @State private var shownAt = Date()

    private var done: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var tappedInstead: Bool { !done && (dictation.lastQuickTap ?? .distantPast) > shownAt }

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
            PracticeStatus(success: done ? "The “um” and Friday are gone — it works the same in any app." : nil,
                           hint: tappedInstead ? "Don’t just tap — hold \(dictation.hotkey.title) down while you talk, then let go." : nil)
            ShortcutLine()
            Spacer(minLength: 0)
            StepFooter(title: done ? "Next: hands-free" : "Skip", action: next)
        }
        .onAppear { shownAt = Date() }
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

    private var done: Bool {
        (dictation.lastHandsFreeFinish ?? .distantPast) > shownAt && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            PracticeStatus(success: done ? "Hands-free works. Great for long messages and prompts." : nil,
                           hint: !done && !text.isEmpty ? "That was hold-to-talk. Try a quick double-tap instead." : nil)
            ShortcutLine()
            Spacer(minLength: 0)
            StepFooter(title: done ? "Finish" : "Skip", action: next)
        }
        .onAppear { shownAt = Date() }
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
