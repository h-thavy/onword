import AppKit
import AVFoundation
import SwiftUI

/// First-run setup: welcome → download models → permissions → shortcut test → hold-to-talk → hands-free → done.
/// Steps can't be skipped: each one unlocks only after Onword has seen it work.
enum Onboarding {
    /// Developer option: `ONWORD_ONBOARDING_STEP=hotkey` (or `hotkey-pressed`, `holdToTalk`, …) opens setup
    /// at that step on launch, e.g. to check a screen without clicking through.
    static let debugStep = ProcessInfo.processInfo.environment["ONWORD_ONBOARDING_STEP"]

    /// First-run setup hasn't reached the languages step's Continue yet, so no model should download.
    static var waitingForLanguages: Bool {
        guard !isComplete, debugStep == nil else { return false }
        return (savedStep ?? 0) <= OnboardingView.Step.languages.rawValue
    }

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
    /// The models are downloaded and loaded; the shortcut and practice steps wait for this.
    @ObservedObject private var dictation = DictationController.shared
    private var modelsReady: Bool {
        dictation.modelReady && dictation.pendingModel == nil && dictation.speakerModels == .ready
    }

    enum Step: Int, CaseIterable {
        case welcome, name, languages, download, permissions, hotkey, holdToTalk, handsFree, done
    }

    @State private var step: Step = Self.initialStep

    private static var initialStep: Step {
        if let name = Onboarding.debugStep,
           let step = Step.allCases.first(where: { "\($0)" == name.replacingOccurrences(of: "-pressed", with: "") }) {
            return step
        }
        guard let saved = Onboarding.savedStep.flatMap(Step.init(rawValue:)) else { return .welcome }
        // Later steps need the models and permissions; if one went missing meanwhile, go back to that step.
        if saved.rawValue > Step.permissions.rawValue, !Permissions.allGranted { return .permissions }
        return saved
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgressHeader(fraction: progress, section: section)
            Group {
                switch step {
                case .welcome: WelcomeStep(next: next)
                case .name: NameStep(back: back, next: next)
                case .languages: LanguagesStep(back: back, next: next)
                case .download: DownloadStep(back: back, next: next)
                case .permissions: PermissionsStep(back: back, next: next)
                // The download may still be running after Permissions: the key and speaking tests wait
                // for it, showing its progress, then continue on their own.
                case .hotkey where !modelsReady, .holdToTalk where !modelsReady, .handsFree where !modelsReady:
                    DownloadStep(back: back, next: next, gate: true)
                case .hotkey: HotkeyStep(back: back, next: next)
                case .holdToTalk: HoldToTalkStep(back: back, next: next)
                case .handsFree: HandsFreeStep(back: back, next: next)
                case .done: DoneStep(back: back)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .id(step)
        }
        .frame(minWidth: 1140, minHeight: 750)
        .background(OB.background)
        .font(Theme.sans(15))
        .foregroundStyle(OB.ink)
        .environment(\.colorScheme, .light)   // Wispr's onboarding is always light
        .animation(.easeOut(duration: 0.2), value: step)
    }

    /// Progress sections: Get started · Download · Permissions · Set up · Learn.
    private var section: Int {
        switch step {
        case .welcome, .name, .languages: 0
        case .download: 1
        case .permissions: 2
        case .hotkey: 3
        case .holdToTalk, .handsFree, .done: 4
        }
    }

    /// Completed sections count fully; the current one by how far into it you are.
    private var progress: Double {
        let within: Double = switch step {
        case .holdToTalk: 1.0 / 3
        case .handsFree: 2.0 / 3
        case .done: 1
        default: 1
        }
        return (Double(section) + (step == .done ? 1 : step.rawValue <= Step.hotkey.rawValue ? 1 : within)) / 5
    }

    private func next() {
        if let following = Step(rawValue: step.rawValue + 1) {
            step = following
            Onboarding.savedStep = following.rawValue
        }
    }

    /// Back is always allowed; only moving forward needs each step to work.
    private func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let next: () -> Void

    var body: some View {
        SplitStep(splash: true,
                  title: Text("Speak, and it’s \(Text("written").font(Theme.serif(72, italic: true))).")
                      .foregroundColor(OB.ink),
                  description: "Onword turns your voice into text in any app, and takes notes in your meetings. Everything runs on this Mac — nothing you say leaves it.",
                  content: { EmptyView() },
                  cta: ("Get started", true, next)) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 220, height: 220)
                .shadow(color: OB.ink.opacity(0.15), radius: 30, y: 20)
        }
    }
}

/// "What should we call you?" — the name shown in greetings and meeting notes. Pre-filled from the Mac's account.
private struct NameStep: View {
    let back: () -> Void
    let next: () -> Void
    @State private var name = UserProfile.name ?? UserProfile.suggestedName
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        CenteredStep(back: back) {
            Text("What should we call you?").font(OB.title)
            Text("Onword uses your name in greetings and in your meeting notes. It stays on this Mac.")
                .font(OB.subtitle).lineSpacing(10).frame(maxWidth: 520)
        } content: {
            TextField("Your name", text: $name)
                .textFieldStyle(.plain)
                .font(Theme.sans(24, .medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20).frame(height: 64)
                .background(RoundedRectangle(cornerRadius: 12).fill(OB.background))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? OB.progress : OB.cardBorder, lineWidth: focused ? 2 : 1))
                .frame(maxWidth: 420)
                .focused($focused)
                .onSubmit(save)
                .onAppear { focused = true }
        } footer: {
            FooterButton(title: "Continue", enabled: !trimmed.isEmpty, action: save)
        }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        UserProfile.name = trimmed
        next()
    }
}

/// Wispr's "Set all the languages you speak": pick the languages you dictate in. This decides which speech
/// model gets downloaded next (English-only, or the multilingual one for anything else).
private struct LanguagesStep: View {
    let back: () -> Void
    let next: () -> Void
    @ObservedObject private var dictation = DictationController.shared
    @State private var selection: [String] = DictationController.shared.selectedLanguages.isEmpty
        ? ["en"] : DictationController.shared.selectedLanguages
    @State private var showAll = false

    /// This Mac's languages first, then common ones, plus anything picked in the full list.
    private var suggestions: [String] {
        var seen = Set<String>()
        return (Languages.preferred + ["en", "es", "zh", "ja", "ko", "fr", "de", "km", "th", "vi", "pt", "hi"] + selection)
            .filter { Languages.all.contains($0) && seen.insert($0).inserted }
    }

    private var needsMultilingual: Bool { selection != ["en"] }

    var body: some View {
        CenteredStep(back: back) {
            Text("Set all the languages you speak").font(OB.title)
            Text("Onword works in \(Languages.all.count) languages. Pick all that apply — with more than one, it detects which you’re speaking.")
                .font(OB.subtitle).lineSpacing(10).frame(maxWidth: 520)
        } content: {
            VStack(spacing: 16) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(suggestions, id: \.self) { tile($0) }
                }
                Button { showAll = true } label: {
                    Label("More languages…", systemImage: "magnifyingglass")
                }
                .buttonStyle(OBButtonStyle(kind: .outline, size: .small))
                Text(needsMultilingual
                     ? "Languages other than English use a one-time download (\(Transcriber.Model.variant(dictation.model.tier, english: false).downloadSize))."
                     : "English uses a fast English-only model (\(dictation.model.downloadSize)).")
                    .font(Theme.sans(15)).foregroundStyle(OB.tertiary)
            }
        } footer: {
            FooterButton(title: "Continue", enabled: !selection.isEmpty) {
                dictation.chooseLanguages(selection)
                dictation.loadModelIfNeeded()   // English: start the download now (other languages already started)
                next()
            }
        }
        .overlay {
            if showAll {
                ZStack {
                    Color.black.opacity(0.3).onTapGesture { showAll = false }
                    LanguagePicker {
                        selection = dictation.selectedLanguages.isEmpty ? selection : dictation.selectedLanguages
                        showAll = false
                    }
                }
            }
        }
    }

    private func tile(_ code: String) -> some View {
        let isSelected = selection.contains(code)
        return Button {
            if let index = selection.firstIndex(of: code) { selection.remove(at: index) } else { selection.append(code) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(Languages.name(code)).font(Theme.sans(15, .semibold)).foregroundStyle(OB.ink).lineLimit(1)
                Text(Languages.nativeName(code) ?? " ").font(Theme.sans(12)).foregroundStyle(OB.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? OB.hex(0xFAF1FF) : OB.background))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? OB.progress : OB.cardBorder, lineWidth: isSelected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
    }
}

/// Downloads what Onword needs before it can be used. Starts on its own at launch; this step waits for it.
private struct DownloadStep: View {
    let back: () -> Void
    let next: () -> Void
    /// Shown in place of the shortcut test while the download finishes; it moves on by itself.
    var gate = false
    @ObservedObject private var dictation = DictationController.shared

    private var ready: Bool { dictation.modelReady && dictation.pendingModel == nil && dictation.speakerModels == .ready }

    var body: some View {
        CenteredStep(back: back) {
            Text(gate ? "Finishing the download…" : "Getting Onword ready").font(OB.title)
            Text(gate ? "Your shortcut and practice dictation need the speech model. This continues on its own as soon as it’s ready."
                      : "Onword understands you right here on your Mac, so it downloads its models once. After that it works offline.")
                .font(OB.subtitle).lineSpacing(10).frame(maxWidth: 520)
        } content: {
            OBCard(widget: true) {
                row("Speech model", "Turns your voice into text · \((dictation.pendingModel?.model ?? dictation.model).downloadSize)") { speech }
                Divider().overlay(OB.sand)
                row("Speaker model", "Tells voices apart in meeting notes · 11 MB") { speaker }
                Divider().overlay(OB.sand)
                row("Meeting summaries", summariesDetail) { summaries }
            }
            Text(ready ? "All downloaded."
                 : gate ? "Keep Onword open and connected to the internet."
                 : "You can continue — the download keeps going in the background.")
                .font(Theme.sans(15)).foregroundStyle(OB.tertiary).padding(.top, 16)
        } footer: {
            // The download keeps going in the background; only the shortcut and practice steps wait for it.
            if !gate { FooterButton(title: "Continue", action: next) }
        }
    }

    private func row(_ title: String, _ detail: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.sans(15, .medium))
                Text(detail).font(Theme.sans(15)).foregroundStyle(OB.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            control()
        }
    }

    @ViewBuilder private var speech: some View {
        if let pending = dictation.pendingModel {
            // A chosen language's model (e.g. multilingual) is downloading.
            if let failure = pending.failure {
                failed(failure) { dictation.retryPendingModel() }
            } else {
                HStack(spacing: 8) {
                    ProgressView(value: pending.progress).frame(width: 110).tint(OB.progress)
                    Text("\(Int(pending.progress * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                .font(Theme.sans(15, .semibold))
            }
        } else if dictation.modelReady {
            done
        } else if let failure = dictation.modelFailure {
            failed(failure) { dictation.retryModel() }
        } else if let progress = dictation.modelProgress, progress < 1 {
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 110).tint(OB.progress)
                Text("\(Int(progress * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            .font(Theme.sans(15, .semibold))
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
            Text("Optional").font(Theme.sans(15, .medium)).foregroundStyle(OB.tertiary)
        }
    }

    private var done: some View {
        Label("Ready", systemImage: "checkmark.circle.fill").font(Theme.sans(15, .semibold)).foregroundStyle(OB.success)
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(Theme.sans(15, .medium)).foregroundStyle(OB.tertiary)
        }
    }

    private func failed(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(message).font(Theme.sans(13, .medium)).foregroundStyle(.orange)
                .frame(maxWidth: 220, alignment: .trailing).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again", action: retry).buttonStyle(OBButtonStyle(kind: .secondary, size: .small))
        }
    }
}

/// Wispr's permissions step: one card per permission (the first not yet allowed is open, with Allow), and a
/// System Settings preview on the right showing where to switch Onword on.
private struct PermissionsStep: View {
    let back: () -> Void
    let next: () -> Void
    @State private var mic = Permissions.microphone
    @State private var accessibility = Permissions.accessibility
    @State private var input = Permissions.inputMonitoring
    @ObservedObject private var dictation = DictationController.shared
    @State private var inputGrantedAt: Date?
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private enum Kind: CaseIterable { case accessibility, microphone, inputMonitoring }

    private func granted(_ kind: Kind) -> Bool {
        switch kind {
        case .accessibility: accessibility
        case .microphone: mic
        case .inputMonitoring: input
        }
    }

    private var current: Kind? { Kind.allCases.first { !granted($0) } }

    var body: some View {
        SplitStep(back: back,
                  title: Text(allGranted ? "Thanks for trusting us, we value your privacy" : "Give Onword permissions on your computer"),
                  content: {
                      VStack(alignment: .leading, spacing: 24) {
                          ForEach(Kind.allCases, id: \.self) { card($0) }
                          if needsRelaunch {
                              VStack(alignment: .leading, spacing: 8) {
                                  Text("macOS needs Onword reopened to finish turning on Input Monitoring.")
                                      .font(Theme.sans(15)).foregroundStyle(.orange)
                                  Button("Reopen Onword") { Onboarding.relaunch() }
                                      .buttonStyle(OBButtonStyle(kind: .primary, size: .small))
                              }
                          }
                      }
                      .animation(.timingCurve(0.05, 0.6, 0.4, 0.95, duration: 0.2), value: current)
                  },
                  cta: ready ? ("Continue", true, next) : nil) {
            SettingsPreview(kind: current ?? .microphone, allowed: current == nil)
                .padding(80)
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

    private func card(_ kind: Kind) -> some View {
        let done = granted(kind)
        let active = kind == current
        let (title, doneTitle, detail, info): (String, String, String, String) = switch kind {
        case .accessibility:
            ("Allow Onword to insert spoken words", "Onword can now paste text anywhere",
             "This lets Onword put your spoken words in the right text box",
             "Onword reads the text around your cursor to match spacing and capitals, and uses the clipboard briefly to paste. It all stays on this Mac.")
        case .microphone:
            ("Allow Onword to use your microphone", "Onword can now use your microphone",
             "Onword only listens while you hold your shortcut or record a meeting",
             "The Flow Bar shows when the microphone is on.")
        case .inputMonitoring:
            ("Allow Onword to notice your shortcut", "Onword can now hear your shortcut",
             "So holding your shortcut works in every app",
             "Onword only watches for its own shortcut key. macOS may ask you to reopen Onword.")
        }
        return OBCard {
            HStack {
                Text(done ? doneTitle : title).font(Theme.sans(15, .medium))
                Spacer()
                if done { Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(OB.success) }
            }
            if active {
                Text(detail).font(Theme.sans(15)).foregroundStyle(OB.tertiary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Allow") { request(kind) }.buttonStyle(OBButtonStyle(kind: .primary, size: .extraSmall))
                    Image(systemName: "info.circle").font(.system(size: 16)).foregroundStyle(OB.tertiary).help(info)
                }
                .padding(.top, 16)
            }
        }
        .frame(minHeight: active ? 172 : 68)
    }

    private func request(_ kind: Kind) {
        switch kind {
        case .accessibility: Permissions.requestAccessibility()
        case .microphone: Task { _ = await Permissions.requestMicrophone() }
        case .inputMonitoring: Permissions.requestInputMonitoring()
        }
    }

    /// A small System Settings window showing the pane to open and Onword's switch.
    private struct SettingsPreview: View {
        let kind: Kind
        let allowed: Bool

        private var pane: (String, String) {
            switch kind {
            case .accessibility: ("Accessibility", "Allow the applications below to control your computer.")
            case .microphone: ("Microphone", "Allow the applications below to access your microphone.")
            case .inputMonitoring: ("Input Monitoring", "Allow the applications below to monitor input from your keyboard.")
            }
        }

        var body: some View {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(OB.hex(UInt32($0))).frame(width: 11, height: 11) }
                    }
                    .padding(.bottom, 14)
                    ForEach(["General", "Appearance", "Privacy & Security", "Keyboard"], id: \.self) { item in
                        Text(item).font(.system(size: 12, weight: item == "Privacy & Security" ? .medium : .regular))
                            .foregroundStyle(item == "Privacy & Security" ? .white : OB.hex(0x1D1D1F))
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 7).fill(item == "Privacy & Security" ? OB.hex(0xA550A7) : .clear))
                    }
                    Spacer()
                }
                .padding(12)
                .frame(width: 170)
                .background(Color.white.opacity(0.6))
                VStack(alignment: .leading, spacing: 12) {
                    Text(pane.0).font(.system(size: 15, weight: .semibold)).foregroundStyle(OB.hex(0x1D1D1F))
                    Text(pane.1).font(.system(size: 12)).foregroundStyle(OB.hex(0x3C3C43))
                    VStack(spacing: 0) {
                        appRow("Onword", on: allowed, highlight: true)
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                    Spacer()
                }
                .padding(20)
            }
            .frame(maxWidth: 560, maxHeight: 345)
            .background(OB.hex(0xF4F3F1))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.24), radius: 35, y: 26)
        }

        private func appRow(_ name: String, on: Bool, highlight: Bool) -> some View {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 25, height: 25)
                Text(name).font(.system(size: 13)).foregroundStyle(OB.hex(0x1D1D1F))
                Spacer()
                Capsule().fill(on ? OB.hex(0xA550A7) : OB.hex(0xE3E3E3)).frame(width: 38, height: 22)
                    .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).frame(width: 18).padding(2) }
            }
            .padding(.horizontal, 14).frame(height: 52)
        }
    }
}

// MARK: - Practice

/// "Your shortcut [key] · Change" under a practice window.
private struct ShortcutLine: View {
    @ObservedObject private var dictation = DictationController.shared

    var body: some View {
        HStack(spacing: 8) {
            Text("Your shortcut").foregroundStyle(OB.tertiary)
            InlineKey(key: dictation.hotkey, size: 15)
            Menu {
                ForEach(HotkeyMonitor.Key.allCases) { key in
                    Button(key.title + (key == .fn && GlobeKey.conflict != nil ? " (conflicts with 🌐 key)" : "")) {
                        dictation.hotkey = key
                    }
                }
            } label: { Text("Change").font(Theme.sans(15, .semibold)) }
                .menuStyle(.borderlessButton).pointerCursor().menuIndicator(.hidden).fixedSize()
        }
        .font(Theme.sans(15))
    }
}

/// The editor inside a practice window, with Wispr's instruction placeholder while it's empty.
private struct PracticeEditor<Placeholder: View>: View {
    @Binding var text: String
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        ZStack(alignment: .topLeading) {
            PlainTextEditor(text: $text, font: NSFont(name: "Figtree", size: 15) ?? .systemFont(ofSize: 15),
                            placeholder: "", documentID: "practice")
            if text.isEmpty {
                VStack(alignment: .leading, spacing: 6) { placeholder() }
                    .font(Theme.sans(15, .medium)).foregroundStyle(OB.muted)
                    .padding(.horizontal, 23).padding(.top, 16)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 150)
    }
}

/// What's happening under a practice window: listening, writing, a coaching pill, or the download.
private struct PracticeStatus: View {
    let coaching: AnyView?
    let hint: String?
    @ObservedObject private var dictation = DictationController.shared

    var body: some View {
        Group {
            switch dictation.state {
            case .recording:
                Label(dictation.isHandsFree ? "Listening hands-free — press your shortcut once to finish" : "Listening… let go when you’re done",
                      systemImage: "waveform").foregroundStyle(OB.muted)
            case .transcribing:
                Label("Writing…", systemImage: "ellipsis").foregroundStyle(OB.muted)
            case .loadingModel:
                ModelDownloadStatus(compact: false)
            case .error where dictation.modelFailure != nil:
                ModelDownloadStatus(compact: false)
            case .needsPermissions:
                Label("Onword needs its permissions first — go back to Permissions.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            default:
                if let coaching {
                    coaching
                } else if let hint {
                    Text(hint).foregroundStyle(OB.muted)
                }
            }
        }
        .font(Theme.sans(15, .medium))
        .frame(minHeight: 44)
        .animation(.easeOut(duration: 0.15), value: dictation.state)
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
                    Button("Try again") { dictation.retryModel() }.buttonStyle(OBButtonStyle(kind: .secondary, size: .small))
                }
                .frame(maxWidth: 600)
            } else if dictation.state == .loadingModel {
                HStack(spacing: 10) {
                    if let progress = dictation.modelProgress, progress < 1 {
                        ProgressView(value: progress).frame(width: compact ? 120 : 160).tint(OB.progress)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(dictation.modelStatus).foregroundStyle(OB.tertiary)
                }
            }
        }
        .font(Theme.sans(compact ? 12 : 15, .medium))
        .multilineTextAlignment(.leading)
    }
}

/// "Don't tap. Press and hold [key]" — shown when a quick tap was ignored.
private func holdCoaching(_ key: HotkeyMonitor.Key) -> AnyView {
    AnyView(OBPill {
        Text("Don’t tap. Press and hold")
        InlineKey(key: key, size: 18)
    })
}

/// Practice 1 (Wispr's "Dictate a message"): hold the key, speak, let go — in a mock email.
private struct HoldToTalkStep: View {
    let back: () -> Void
    let next: () -> Void
    @ObservedObject private var dictation = DictationController.shared
    @State private var text = ""
    @State private var shownAt = Date()
    private let owner = UUID()
    /// Set only by a real hold-to-talk dictation (typing in the box doesn't count).
    @State private var done = false
    @State private var usedHandsFree = false

    private var tapped: Bool { !done && (dictation.lastQuickTap ?? .distantPast) > shownAt }

    private var hint: String? {
        if done { return nil }
        if usedHandsFree { return "That was hands-free. Here, hold your shortcut down while you talk." }
        if (dictation.lastHeardNothing ?? .distantPast) > shownAt {
            return "Didn’t catch that. Speak a little louder, close to your microphone."
        }
        return nil
    }

    var body: some View {
        CenteredStep(back: back) {
            (Text("Dictate").italic() + Text(" a message with Onword")).font(OB.title)
            HStack(spacing: 6) {
                Text("Hold")
                InlineKey(key: dictation.hotkey)
                Text("while you speak. Onword turns your voice into text.")
            }
            .font(OB.subtitle)
        } content: {
            VStack(spacing: 20) {
                AppShell(name: "Mail", symbol: "envelope.fill", tint: OB.hex(0x2F7CF6), active: dictation.state == .recording) {
                    VStack(spacing: 0) {
                        mailField("To:", "Dara")
                        Divider().overlay(OB.sand)
                        mailField("Subject:", "Quick question")
                        Divider().overlay(OB.sand)
                        PracticeEditor(text: $text) {
                            HStack(spacing: 6) {
                                Text("Hold down")
                                InlineKey(key: dictation.hotkey, size: 15)
                                Text("and say this, then release:")
                            }
                            Text("“Um, hi Dara, are you free on Friday at three? Scratch that. Are you free on Saturday morning?”")
                                .font(Theme.sans(15)).italic().fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if done {
                        OBPill(sticker: true, rotation: 8) { Text("Well done!") }
                            .offset(x: 60, y: -24)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                PracticeStatus(coaching: tapped ? holdCoaching(dictation.hotkey) : nil, hint: hint)
                ShortcutLine()
            }
            .animation(.easeOut(duration: 0.15), value: done)
        } footer: {
            FooterButton(title: "Continue", enabled: done, action: next)
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
            Text(label).opacity(0.5)
            Text(value)
            Spacer()
        }
        .font(Theme.sans(15))
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// Practice 2 (Wispr's "hands free"): double-tap to start, press once more to finish — in a mock AI chat.
private struct HandsFreeStep: View {
    let back: () -> Void
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
        if heldInstead { return "That was hold-to-talk. Tap your shortcut twice quickly instead, then talk." }
        if (dictation.lastHeardNothing ?? .distantPast) > shownAt {
            return "Didn’t catch that. Speak a little louder, close to your microphone."
        }
        return nil
    }

    var body: some View {
        CenteredStep(back: back) {
            (Text("Write a prompt ") + Text("hands free").italic()).font(OB.title)
            HStack(spacing: 6) {
                Text("Double-tap")
                InlineKey(key: dictation.hotkey)
                Text("and talk. Press it once more when you’re done.")
            }
            .font(OB.subtitle)
        } content: {
            VStack(spacing: 20) {
                AppShell(name: "AI Chat", symbol: "sparkles", tint: OB.progress, active: dictation.state == .recording) {
                    PracticeEditor(text: $text) {
                        HStack(spacing: 6) {
                            Text("Double-tap")
                            InlineKey(key: dictation.hotkey, size: 15)
                            Text("and say...")
                        }
                        Text("“Draft a short note to the team about Friday’s launch, and ask who can help test it.”")
                            .font(Theme.sans(15)).italic().fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text("then press")
                            InlineKey(key: dictation.hotkey, size: 15)
                            Text("once to finish")
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if done {
                        OBPill(sticker: true, rotation: -8) { Text("Hands free!") }
                            .offset(x: 60, y: -24)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                PracticeStatus(coaching: nil, hint: hint)
                ShortcutLine()
            }
            .animation(.easeOut(duration: 0.15), value: done)
        } footer: {
            FooterButton(title: "Continue", enabled: done, action: next)
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
}

private struct DoneStep: View {
    let back: () -> Void
    @ObservedObject private var dictation = DictationController.shared
    /// Redraws as soon as the name changes in Settings.
    @AppStorage(UserProfile.key) private var userName = ""

    var body: some View {
        CenteredStep(back: back) {
            Text(UserProfile.name.map { "You’re all set, \($0)" } ?? "You’re all set").font(OB.title)
            Text("Onword lives in the Flow Bar above your Dock and in the menu bar.").font(OB.subtitle)
        } content: {
            OBCard(widget: true) {
                tip(AnyView(InlineKey(key: dictation.hotkey, size: 15)), "Hold to dictate in any app. Double-tap for hands-free, Esc to cancel.")
                Divider().overlay(OB.sand)
                tip(AnyView(chip("⌃⌥S")), "Open the Scratchpad for quick notes.")
                Divider().overlay(OB.sand)
                tip(AnyView(chip("⌥M")), "Start or stop Notetaker in a call. Onword can also notice calls and ask.")
            }
        } footer: {
            FooterButton(title: "Open Onword") {
                Onboarding.isComplete = true
                WindowManager.shared.closeOnboarding()
                WindowManager.shared.show(.dictation)
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(Theme.sans(15, .medium)).foregroundStyle(OB.hex(0x30302F))
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(OB.background))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(OB.chipBorder))
    }

    private func tip(_ key: AnyView, _ text: String) -> some View {
        HStack(spacing: 16) {
            key.frame(width: 80, alignment: .leading)
            Text(text).font(Theme.sans(15)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
