import SwiftUI

/// Setup step (Wispr's "Test your dictation shortcut"): press your shortcut and watch the same key, drawn
/// as a real Mac keycap, turn purple while you hold it.
struct HotkeyStep: View {
    let back: () -> Void
    let next: () -> Void
    @ObservedObject private var dictation = DictationController.shared
    @State private var shownAt = Date()
    @State private var presses = 0
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var tested: Bool { presses > 0 }
    private var pressed: Bool { dictation.hotkeyIsDown || Onboarding.debugStep == "hotkey-pressed" }

    var body: some View {
        CenteredStep(back: back) {
            Text("Test your dictation shortcut").font(OB.title)
            HStack(spacing: 6) {
                Text("Hold")
                InlineKey(key: dictation.hotkey)
                Text("while you speak. Onword turns your voice into text.")
            }
            .font(OB.subtitle)
        } content: {
            VStack(spacing: 24) {
                OBCard(widget: true) {
                    Text("Does the button turn purple while pressing it?")
                        .font(Theme.sans(20, .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Spacer()
                        Keycap(key: dictation.hotkey, pressed: pressed)
                        Spacer()
                    }
                    .frame(height: 96)
                    .background(RoundedRectangle(cornerRadius: 8).fill(OB.tray))
                    HStack(spacing: 16) {
                        shortcutMenu {
                            Label("Edit shortcut", systemImage: "pencil")
                        }
                        .buttonStyle(OBButtonStyle(kind: .outline, size: .small))
                        Spacer()
                        shortcutMenu { Text("No") }
                            .buttonStyle(OBButtonStyle(kind: .secondary, size: .small))
                        Button("Yes", action: next)
                            .buttonStyle(OBButtonStyle(kind: .primary, size: .small))
                            .disabled(!tested)
                            .keyboardShortcut(.defaultAction)
                            .help(tested ? "" : "Press your shortcut to continue")
                    }
                }
                status
            }
        } footer: {
            EmptyView()
        }
        .onAppear {
            shownAt = Date()
            dictation.hotkeyTestMode = true      // pressing only animates here; no dictation starts
        }
        .onDisappear { dictation.hotkeyTestMode = false }
        .onChange(of: dictation.hotkeyIsDown) { _, down in
            if down { presses += 1 }
        }
        .onReceive(timer) { now = $0 }
    }

    /// Below the card: why nothing lights up, or how to fix it.
    @ViewBuilder private var status: some View {
        if !Permissions.inputMonitoring || !dictation.shortcutReady {
            VStack(spacing: 10) {
                Text("Onword can't see your keyboard yet. Allow Input Monitoring, or reopen Onword so macOS applies it.")
                    .font(Theme.sans(15)).foregroundStyle(.orange).multilineTextAlignment(.center)
                Button("Reopen Onword") { Onboarding.relaunch() }.buttonStyle(OBButtonStyle(kind: .secondary, size: .small))
            }
        } else if !tested, now.timeIntervalSince(shownAt) > 10 {
            VStack(spacing: 10) {
                Text("Not turning purple? Another dictation app may be using this key — quit it or pick another key. Or reopen Onword so macOS applies Input Monitoring.")
                    .font(Theme.sans(15)).foregroundStyle(OB.tertiary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reopen Onword") { Onboarding.relaunch() }.buttonStyle(OBButtonStyle(kind: .secondary, size: .small))
            }
        } else if dictation.hotkey == .fn, GlobeKey.conflict != nil {
            Button("Set “Press 🌐 key to” → Do Nothing") { GlobeKey.openKeyboardSettings() }
                .buttonStyle(OBButtonStyle(kind: .secondary, size: .small))
        }
    }

    private func shortcutMenu(@ViewBuilder label: @escaping () -> some View) -> some View {
        PopMenuButton(items: HotkeyMonitor.Key.allCases.map { key in
            PopMenuItem(title: key.title + (key == .fn && GlobeKey.conflict != nil ? " (conflicts with 🌐 key)" : ""),
                        icon: dictation.hotkey == key ? "checkmark" : nil) {
                dictation.hotkey = key
                presses = 0
            }
        }, alignment: .leading, plain: false, label: label)
        .fixedSize()
    }
}
