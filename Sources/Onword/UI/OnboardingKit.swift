import AppKit
import SwiftUI

/// Setup's look, matched to Wispr Flow's onboarding: always light, Figtree 32/40 semibold titles, 18/28
/// subtitles, 40 pt buttons, warm sand backgrounds, and a 5-section progress header with a purple bar.
enum OB {
    static let background = hex(0xFCFCFB)
    static let sand = hex(0xEEEBE3)          // centred-layout background, right panel, track
    static let tray = hex(0xF5F4F0)          // key / meter tray
    static let cardBorder = hex(0xC5C0B3)
    static let ink = hex(0x1A1A1A)
    static let tertiary = hex(0x71716E)
    static let muted = hex(0x4D4A42)
    static let progress = hex(0xA26EC1)
    static let lilac = hex(0xF0D7FF)         // pressed key, toasts, stickers
    static let plum = hex(0x502B66)
    static let chipBorder = hex(0xB3B2AD)
    static let lumen = hex(0xFFFFEB)
    static let success = Color(red: 0.25, green: 0.55, blue: 0.35)

    static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }

    static let title = Theme.sans(32, .semibold)
    static let subtitle = Theme.sans(18)
    static let description = Theme.sans(18, .medium)
}

// MARK: - Progress header

/// "GET STARTED › DOWNLOAD › PERMISSIONS › SET UP › LEARN" with a 2 pt purple progress bar beneath.
struct OnboardingProgressHeader: View {
    static let sections = ["Get started", "Download", "Permissions", "Set up", "Learn"]
    /// 0…1 of the whole setup.
    let fraction: Double
    /// Index of the section in progress.
    let section: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 48) {
                ForEach(Array(Self.sections.enumerated()), id: \.offset) { index, name in
                    HStack(spacing: 48) {
                        Text(name.uppercased())
                            .font(Theme.sans(12, .semibold)).tracking(0.9)
                            .foregroundStyle(index <= section ? OB.ink : OB.muted)
                        if index < Self.sections.count - 1 {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(index < section ? OB.ink : OB.hex(0xB0ABB2))
                        }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(minHeight: 28)
            .padding(8)
            .frame(maxWidth: .infinity)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(OB.sand)
                    Rectangle().fill(OB.progress).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 2)
        }
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

// MARK: - Layouts

/// Wispr's centred layout: sand background, Back on the left, a centred title and subtitle, content up to
/// 560 pt wide, and footer buttons (up to 300 pt each) pinned to the bottom.
struct CenteredStep<Header: View, Content: View, Footer: View>: View {
    var back: (() -> Void)?
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let back { BackButton(action: back) }
                Spacer()
            }
            .frame(height: 28)
            VStack(spacing: 40) {
                VStack(spacing: 16) { header() }
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 112, alignment: .top)
                content().frame(maxWidth: 560)
            }
            .padding(.top, 32)
            Spacer(minLength: 24)
            HStack(spacing: 24) { footer() }.frame(maxWidth: 500)
        }
        .padding(.horizontal, 108).padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OB.sand)
    }
}

/// Wispr's split layout: a 577 pt left column (title, description, content, full-width button at the bottom)
/// and a sand panel on the right.
struct SplitStep<Content: View, Right: View>: View {
    var back: (() -> Void)?
    var splash = false
    let title: Text
    var description: String?
    @ViewBuilder var content: () -> Content
    var cta: (title: String, enabled: Bool, action: () -> Void)?
    @ViewBuilder var right: () -> Right

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                if let back { BackButton(action: back) }
                VStack(alignment: .leading, spacing: splash ? 40 : 16) {
                    title
                        .font(splash ? Theme.serif(72) : OB.title)
                        .tracking(splash ? -2.88 : 0)
                        .lineSpacing(splash ? 0 : 8)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description {
                        Text(description)
                            .font(splash ? Theme.sans(18, .semibold) : OB.description)
                            .lineSpacing(10)
                            .frame(maxWidth: splash ? 389 : 360, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: splash ? .infinity : 360, alignment: .leading)
                content()
                Spacer(minLength: 0)
                if let cta {
                    Button(cta.title, action: cta.action)
                        .buttonStyle(OBButtonStyle(kind: .primary, size: .large, fullWidth: true))
                        .disabled(!cta.enabled)
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 108).padding(.vertical, 40)
            .frame(width: 577, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(splash ? OB.sand : OB.background)
            right()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OB.sand)
        }
    }
}

struct BackButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                Text("Back")
            }
            .font(Theme.sans(15, .medium)).foregroundStyle(OB.tertiary)
            .padding(4).contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
    }
}

// MARK: - Buttons

/// Wispr's buttons: radius 8, 15 pt; large is 24×10 padding (40 pt tall), small 12×6, extra small 32 tall.
struct OBButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, outline }
    enum Size { case large, small, extraSmall }
    var kind: Kind = .primary
    var size: Size = .large
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View { styledBody(configuration).pointerCursor() }

    @ViewBuilder private func styledBody(_ configuration: Configuration) -> some View {
        configuration.label
            .font(size == .extraSmall ? Theme.sans(12, .medium) : Theme.sans(15, kind == .secondary ? .semibold : .medium))
            .lineLimit(1)
            .padding(.horizontal, size == .large ? 24 : 12)
            .padding(.vertical, size == .large ? 10 : size == .small ? 6 : 0)
            .frame(height: size == .extraSmall ? 32 : nil)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill(pressed: configuration.isPressed)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(kind == .outline ? OB.sand : .clear))
            .foregroundStyle(kind == .primary ? OB.background : OB.ink)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }

    private func fill(pressed: Bool) -> Color {
        switch kind {
        case .primary: pressed ? OB.hex(0x313130) : OB.ink
        case .secondary: pressed ? OB.hex(0xE0DDD5) : OB.sand
        case .outline: pressed ? OB.tray : OB.background
        }
    }
}

/// A footer button capped at 300 pt wide, as in Wispr's centred layout.
struct FooterButton: View {
    let title: String
    var kind: OBButtonStyle.Kind = .primary
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(OBButtonStyle(kind: kind, size: .large, fullWidth: true))
            .disabled(!enabled)
            .frame(maxWidth: 300)
            .keyboardShortcut(kind == .primary ? .defaultAction : nil)
    }
}

// MARK: - Cards, chips, keycaps

/// The white card: 20 pt padding, radius 12, 1 pt #C5C0B3 border.
struct OBCard<Content: View>: View {
    var padding: CGFloat = 20
    var widget = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: widget ? 24 : 8) { content() }
            .padding(widget ? 24 : padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(OB.background))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(widget ? .clear : OB.cardBorder))
            .shadow(color: widget ? OB.ink.opacity(0.25) : .clear, radius: 25, y: 25)
    }
}

/// The shortcut as a small key inside text ("Hold [⌥ Opt →] while you speak"), sized like the text around it.
struct InlineKey: View {
    let key: HotkeyMonitor.Key
    /// The size of the text around it; the keycap is drawn about twice as tall.
    var size: CGFloat = 18
    @ObservedObject private var dictation = DictationController.shared

    var body: some View {
        // The real key, drawn as a Mac keycap (not a text chip); it lights up while you hold it.
        MiniKeycap(key: key, pressed: dictation.hotkeyIsDown, scale: size * 1.9 / 60)
    }
}

/// A Mac keycap drawn like the real key (fn with its globe, ⌥ option, ⌘ command). Pressed, it turns lilac
/// with a plum border and loses its shadow.
struct Keycap: View {
    let key: HotkeyMonitor.Key
    let pressed: Bool

    private var width: CGFloat { Self.width(for: key) }

    static func width(for key: HotkeyMonitor.Key) -> CGFloat {
        switch key {
        case .fn: 60
        case .rightOption: 70
        case .rightCommand: 90
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                switch key {
                case .fn: Text("fn")
                case .rightOption: Text("⌥").font(.system(size: 16))
                case .rightCommand: Text("⌘").font(.system(size: 16))
                }
            }
            Spacer(minLength: 0)
            HStack {
                switch key {
                case .fn:
                    Image(systemName: "globe").font(.system(size: 14))
                    Spacer()
                case .rightOption:
                    Spacer()
                    Text("option")
                case .rightCommand:
                    Spacer()
                    Text("command")
                }
            }
        }
        .font(.system(size: 12.4))
        .foregroundStyle(pressed ? OB.hex(0x30302F) : OB.muted)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(width: width, height: 60)
        .background(RoundedRectangle(cornerRadius: 5).fill(pressed ? OB.lilac : .white))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(pressed ? OB.plum : OB.muted, lineWidth: 1.43))
        .shadow(color: OB.hex(0x101828).opacity(pressed ? 0 : 0.1), radius: 7, y: 9.5)
    }
}

/// The keycap at a smaller size (e.g. 0.6), laid out at its scaled size.
struct MiniKeycap: View {
    let key: HotkeyMonitor.Key
    let pressed: Bool
    var scale: CGFloat = 0.6

    var body: some View {
        Keycap(key: key, pressed: pressed)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: Keycap.width(for: key) * scale, height: 60 * scale, alignment: .topLeading)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

/// Lilac pill for coaching ("Don't tap. Press and hold [key]") and stickers ("Well done!").
struct OBPill<Content: View>: View {
    var sticker = false
    var rotation: Double = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 6) { content() }
            .font(sticker ? Theme.sans(18, .medium) : Theme.sans(18, .semibold))
            .foregroundStyle(sticker ? OB.ink : .black)
            .padding(.horizontal, sticker ? 16 : 24).padding(.vertical, sticker ? 6 : 8)
            .background(Capsule().fill(OB.lilac).opacity(sticker ? 1 : 0))
            .background(RoundedRectangle(cornerRadius: 8).fill(OB.lilac).opacity(sticker ? 0 : 1))
            .overlay(Capsule().strokeBorder(sticker ? OB.lumen : .clear, lineWidth: 2))
            .shadow(color: OB.ink.opacity(0.1), radius: 6, y: 6)
            .rotationEffect(.degrees(rotation))
    }
}

/// A mock app window for practice: white, radius 16, grey header with the app's name.
struct AppShell<Content: View>: View {
    let name: String
    let symbol: String
    let tint: Color
    var active = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 5).fill(tint))
                Text(name).font(Theme.sans(18, .medium)).padding(.leading, 4)
                Spacer()
            }
            .padding(16)
            .background(OB.hex(0xF1F1F2))
            content()
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(active ? OB.muted : OB.sand, lineWidth: active ? 1.5 : 1))
        .shadow(color: OB.ink.opacity(0.25), radius: 25, y: 25)
        .frame(maxWidth: 500)
    }
}

extension HotkeyMonitor.Key {
    /// The key as Wispr labels it in onboarding chips ("fn", "⌥ Opt →" for the right Option key).
    var onboardingLabel: String {
        switch self {
        case .fn: "fn"
        case .rightOption: "⌥ Opt →"
        case .rightCommand: "⌘ Cmd →"
        }
    }
}
