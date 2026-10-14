import SwiftUI

/// Setup step: press your dictation shortcut and watch the same key go down on an on-screen keyboard.
struct HotkeyStep: View {
    let next: () -> Void
    @ObservedObject private var dictation = DictationController.shared
    @State private var shownAt = Date()
    @State private var presses = 0
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var tested: Bool { presses > 0 }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Text("Try your \(Text("shortcut").font(Theme.serif(38, italic: true)))")
                    .font(Theme.serif(38))
                Text("Press the **\(dictation.hotkey.title)** key on your keyboard. You'll hold it whenever you want to talk.")
                    .font(Theme.sans(15)).foregroundStyle(Theme.inkTertiary)
                    .multilineTextAlignment(.center).frame(maxWidth: 540)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 22)

            MacKeyboardRow(target: dictation.hotkey,
                           pressed: dictation.hotkeyIsDown || Onboarding.debugStep == "hotkey-pressed")
                .padding(.vertical, 10)

            Group {
                if !Permissions.inputMonitoring || !dictation.shortcutReady {
                    Label("Onword can't see your keyboard yet — allow Input Monitoring in the previous step.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if dictation.hotkeyIsDown {
                    Label("Holding \(dictation.hotkey.chip)…", systemImage: "hand.point.down.fill").foregroundStyle(Theme.ink)
                } else if tested {
                    Label("That’s your shortcut. Press it again anytime.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 0.35))
                } else {
                    Text("Waiting for \(dictation.hotkey.chip)…").foregroundStyle(Theme.inkTertiary)
                }
            }
            .font(Theme.sans(14, .semibold))
            .frame(height: 22)

            // Nothing detected after a while: the usual causes, and a fix.
            if !tested, now.timeIntervalSince(shownAt) > 10 || (Permissions.inputMonitoring && !dictation.shortcutReady) {
                VStack(spacing: 8) {
                    Text("Not lighting up? Another dictation app may be using this key — quit it or pick another key below. Or reopen Onword so macOS applies Input Monitoring.")
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
                        .multilineTextAlignment(.center).frame(maxWidth: 520)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Reopen Onword") { Onboarding.relaunch() }.buttonStyle(.pillQuiet)
                }
            }

            HStack(spacing: 6) {
                Text("Prefer another key?").foregroundStyle(Theme.inkTertiary)
                Menu {
                    ForEach(HotkeyMonitor.Key.allCases) { key in
                        Button(key.title + (key == .fn && GlobeKey.conflict != nil ? " (conflicts with 🌐 key)" : "")) {
                            dictation.hotkey = key
                            presses = 0
                        }
                    }
                } label: { Text("Change").font(Theme.sans(12.5, .semibold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                if dictation.hotkey == .fn, GlobeKey.conflict != nil {
                    Button("Fix 🌐 key") { GlobeKey.openKeyboardSettings() }.buttonStyle(.pillQuiet)
                }
            }
            .font(Theme.sans(12.5))

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Continue", action: next).buttonStyle(.pill).keyboardShortcut(.defaultAction)
                    .disabled(!tested).opacity(tested ? 1 : 0.4)
            }
        }
        .onAppear {
            shownAt = Date()
            dictation.hotkeyTestMode = true      // pressing only animates here; no dictation starts
        }
        .onDisappear { dictation.hotkeyTestMode = false }
        .onReceive(timer) { now = $0 }
        .onChange(of: dictation.hotkeyIsDown) { _, down in
            if down { presses += 1 }
        }
    }
}

/// The bottom rows of a Mac keyboard, drawn to scale, with the target key highlighted and pressed live.
struct MacKeyboardRow: View {
    let target: HotkeyMonitor.Key
    let pressed: Bool

    private let unit: CGFloat = 38
    private let gap: CGFloat = 5

    var body: some View {
        VStack(spacing: gap) {
            // Shift row, faded, for context.
            HStack(spacing: gap) {
                key(KeyLabel(word: "shift", symbol: "⇧", align: .leading), width: 2.25)
                ForEach(["Z", "X", "C", "V", "B", "N", "M", ",", ".", "/"], id: \.self) { letter in
                    key(KeyLabel(center: letter), width: 1)
                }
                key(KeyLabel(word: "shift", symbol: "⇧", align: .trailing), width: 2.25)
            }
            .opacity(0.45)

            // Bottom row with the modifier keys.
            HStack(spacing: gap) {
                key(KeyLabel(word: "fn", systemImage: "globe", align: .leading), width: 1, isTarget: target == .fn)
                key(KeyLabel(word: "control", symbol: "⌃", align: .leading), width: 1)
                key(KeyLabel(word: "option", symbol: "⌥", align: .leading), width: 1)
                key(KeyLabel(word: "command", symbol: "⌘", align: .leading), width: 1.3)
                key(KeyLabel(), width: 5.3)
                key(KeyLabel(word: "command", symbol: "⌘", align: .trailing), width: 1.3, isTarget: target == .rightCommand)
                key(KeyLabel(word: "option", symbol: "⌥", align: .trailing), width: 1, isTarget: target == .rightOption)
                arrows
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.selected.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.border))
    }

    private func key(_ label: KeyLabel, width: CGFloat, isTarget: Bool = false) -> some View {
        KeyCap(label: label, size: CGSize(width: unit * width + gap * (width - 1).rounded(.down), height: unit),
               isTarget: isTarget, isPressed: isTarget && pressed)
    }

    private var arrows: some View {
        HStack(alignment: .bottom, spacing: gap) {
            KeyCap(label: KeyLabel(systemImage: "arrowtriangle.left.fill", tiny: true), size: CGSize(width: unit, height: unit / 2 - 1))
            VStack(spacing: 2) {
                KeyCap(label: KeyLabel(systemImage: "arrowtriangle.up.fill", tiny: true), size: CGSize(width: unit, height: unit / 2 - 1))
                KeyCap(label: KeyLabel(systemImage: "arrowtriangle.down.fill", tiny: true), size: CGSize(width: unit, height: unit / 2 - 1))
            }
            KeyCap(label: KeyLabel(systemImage: "arrowtriangle.right.fill", tiny: true), size: CGSize(width: unit, height: unit / 2 - 1))
        }
    }
}

struct KeyLabel {
    var word: String?
    var symbol: String?
    var systemImage: String?
    var center: String?
    var align: HorizontalAlignment = .leading
    var tiny = false
}

/// One key: a cap on a darker base. Pressed, the cap sinks onto the base and turns dark.
private struct KeyCap: View {
    let label: KeyLabel
    let size: CGSize
    var isTarget = false
    var isPressed = false
    @State private var pulse = false

    private let depth: CGFloat = 4

    var body: some View {
        ZStack(alignment: .top) {
            // Base (the key's side), visible below the cap.
            RoundedRectangle(cornerRadius: 7)
                .fill(isTarget ? Theme.onAccent.opacity(0.55) : Theme.border)
                .frame(width: size.width, height: size.height)
                .offset(y: depth)
            // Cap.
            RoundedRectangle(cornerRadius: 7)
                .fill(isPressed ? Theme.ink : (isTarget ? Theme.accent : Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isTarget ? Theme.onAccent.opacity(pulse && !isPressed ? 0.9 : 0.5) : Theme.border,
                                  lineWidth: isTarget ? 2 : 1))
                .overlay(content.padding(.horizontal, 4).padding(.vertical, 4))
                .frame(width: size.width, height: size.height)
                .offset(y: isPressed ? depth : 0)
                .scaleEffect(isPressed ? 0.97 : 1)
        }
        .frame(width: size.width, height: size.height + depth, alignment: .top)
        .shadow(color: isTarget && !isPressed ? Theme.onAccent.opacity(pulse ? 0.35 : 0.1) : .clear, radius: 10)
        .animation(.spring(response: 0.16, dampingFraction: 0.7), value: isPressed)
        .onAppear {
            guard isTarget else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var ink: Color { isPressed ? Theme.onPrimary : (isTarget ? Theme.onAccent : Theme.inkSecondary) }

    @ViewBuilder
    private var content: some View {
        if let center = label.center {
            Text(center).font(Theme.sans(14, .medium)).foregroundStyle(ink)
        } else if label.tiny, let image = label.systemImage {
            Image(systemName: image).font(.system(size: 7)).foregroundStyle(ink)
        } else {
            VStack(alignment: label.align, spacing: 0) {
                HStack {
                    if label.align == .trailing { Spacer(minLength: 0) }
                    if let symbol = label.symbol { Text(symbol).font(.system(size: 11)) }
                    if label.align == .leading, label.word == "fn" {
                        Text("fn").font(Theme.sans(10, .medium))
                    }
                    if label.align == .leading { Spacer(minLength: 0) }
                }
                Spacer(minLength: 0)
                HStack {
                    if label.align == .trailing { Spacer(minLength: 0) }
                    if let image = label.systemImage {
                        Image(systemName: image).font(.system(size: 11))
                    } else if let word = label.word {
                        Text(word).font(Theme.sans(8.5, .medium)).lineLimit(1).minimumScaleFactor(0.6)
                    }
                    if label.align == .leading { Spacer(minLength: 0) }
                }
            }
            .foregroundStyle(ink)
        }
    }
}
