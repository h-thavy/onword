import AppKit
import SwiftUI

/// Design tokens: warm "sand" neutrals, near-black ink, a lavender "dawn"
/// accent, EB Garamond headlines and Figtree text. Values are read from its stylesheet; every colour
/// has a light and a dark variant.
enum Theme {
    // MARK: Colours

    /// Window frame behind the sidebar (sand-500 / vast-925).
    static let frame = dynamic(light: 0xF5F4F0, dark: 0x202020)
    /// Main content panel (pure white / vast-950).
    static let panel = dynamic(light: 0xFFFFFF, dark: 0x1A1A1A)
    /// Cards and rows on the panel (sand-50 / vast-910).
    static let card = dynamic(light: 0xFCFCFB, dark: 0x2A2A29)
    /// Hover and selected rows (sand-200 / vast-900).
    static let hover = dynamic(light: 0xF8F7F3, dark: 0x30302F)
    static let selected = dynamic(light: 0xEEEBE3, dark: 0x343432)
    /// Hairlines (sand-600 / vast-900).
    static let border = dynamic(light: 0xEEEBE3, dark: 0x30302F)
    static let ink = dynamic(light: 0x1A1A1A, dark: 0xE9E8E1)
    static let inkSecondary = dynamic(light: 0x464544, dark: 0xC8C8C2)
    static let inkTertiary = dynamic(light: 0x71716E, dark: 0x9D9C98)
    /// Primary buttons: ink on light, sand on dark.
    static let primary = dynamic(light: 0x1A1A1A, dark: 0xFCFCFB)
    static let onPrimary = dynamic(light: 0xFCFCFB, dark: 0x1A1A1A)
    /// Lavender accent for highlights and badges (dawn-300/900).
    static let accent = dynamic(light: 0xF4E1FF, dark: 0x3C2947)
    static let onAccent = dynamic(light: 0x502B66, dark: 0xF0D7FF)
    static let recording = Color(red: 0.86, green: 0.2, blue: 0.18)

    // MARK: Type

    /// Serif display face for page titles and headlines.
    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        .custom(italic ? "EBGaramond-Italic" : "EBGaramond-Regular", size: size)
    }

    /// Body face.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Figtree", size: size).weight(weight)
    }

    // MARK: Shape

    static let radiusSmall: CGFloat = 6
    static let radius: CGFloat = 8
    static let radiusMedium: CGFloat = 12
    static let radiusLarge: CGFloat = 16

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

// MARK: Scratchpad window
// Extra tokens for the floating Scratchpad window, whose values follow Wispr Flow's Scratchpad
// (frame, hairlines and ink reuse `frame`, `border`, `ink`, `inkTertiary` above).

extension Theme {
    /// Editor card inside the frame (background).
    static let scratchpadCard = dynamic(light: 0xFCFCFB, dark: 0x1A1A1A)
    /// Active rows and pressed buttons (neutral-200).
    static let scratchpadActive = dynamic(light: 0xEEEBE3, dark: 0x30302F)
    /// Placeholder, inactive tabs, muted text (neutral-500).
    static let scratchpadMuted = dynamic(light: 0x4D4A42, dark: 0x9D9C98)
    /// Toolbar icons and the logo (neutral-600).
    static let scratchpadIcon = dynamic(light: 0x30302F, dark: 0xDEDDD7)
    /// Hovered tab text (vast-900).
    static let scratchpadHoverInk = dynamic(light: 0x30302F, dark: 0xE9E8E1)
    /// The Copy pill and its label (shade-black / shade-white).
    static let scratchpadPill = dynamic(light: 0x000000, dark: 0xE9E8E1)
    static let scratchpadOnPill = dynamic(light: 0xFFFFFF, dark: 0x1A1A1A)
    /// Round floating buttons and popovers (shade-white).
    static let scratchpadFloating = dynamic(light: 0xFFFFFF, dark: 0x1A1A1A)
    /// Text cursor (glow-300), the same in light and dark.
    static let caret = NSColor(srgbRed: 1, green: 0xA9 / 255, blue: 0x46 / 255, alpha: 1)
    /// Search-match highlight.
    static let searchHighlight = Color(red: 1, green: 212 / 255, blue: 103 / 255).opacity(0.4)
}

// MARK: - Components

/// Page title row: serif title, optional badge, actions on the right.
struct PageHeader<Actions: View>: View {
    let title: String
    var badge: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(Theme.serif(34)).foregroundStyle(Theme.ink)
            if let badge {
                Text(badge).font(Theme.sans(11, .semibold)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.accent))
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
            }
            Spacer()
            actions()
        }
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, badge: String? = nil) {
        self.init(title: title, badge: badge) { EmptyView() }
    }
}

/// Hero card: a serif headline with one italic word, a sentence, and an action.
struct HeroCard<Action: View>: View {
    /// Headline split around the italic word, e.g. ("Onword spells the way ", "you", " do.").
    let before: String
    let italic: String
    let after: String
    let message: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(before)\(Text(italic).font(Theme.serif(28, italic: true)))\(after)")
                .font(Theme.serif(28))
                .foregroundStyle(Theme.ink)
            Text(message).font(Theme.sans(14)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            action()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLarge).fill(Theme.accent.opacity(0.55)))
    }
}

/// Dark pill button, or a quiet outlined one.
struct PillButtonStyle: ButtonStyle {
    var prominent = true
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent, tint: tint)
    }
}

private struct PillBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let tint: Color?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(Theme.sans(13, .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(prominent ? Theme.onPrimary : Theme.ink)
            .background(
                Capsule().fill(prominent ? (tint ?? Theme.primary) : Theme.panel)
                    .overlay(Capsule().strokeBorder(prominent ? .clear : Theme.border))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillQuiet: PillButtonStyle { PillButtonStyle(prominent: false) }
}

/// Small borderless icon button that darkens on hover.
struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 13))
                .frame(width: 26, height: 26)
                .foregroundStyle(hovering ? Theme.ink : Theme.inkTertiary)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSmall).fill(hovering ? Theme.selected : .clear))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// A keyboard-key chip, e.g. "fn".
struct KeyChip: View {
    let text: String

    var body: some View {
        Text(text).font(Theme.sans(12, .semibold)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.06), radius: 0, y: 1)
    }
}

/// Rounded search field.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.inkTertiary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(Theme.sans(13))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkTertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
    }
}

/// Uppercase group label ("TODAY").
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(Theme.sans(11, .semibold)).kerning(0.6).foregroundStyle(Theme.inkTertiary)
    }
}

/// A list row that highlights on hover and reveals trailing actions.
/// Actions float over the row's right edge on hover, so text can use the full width.
struct HoverRow<Content: View, Actions: View>: View {
    var selected = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(selected ? Theme.selected : (hovering ? Theme.hover : .clear)))
            .overlay(alignment: .topTrailing) {
                if hovering {
                    actions()
                        .padding(3)
                        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.panel)
                            .shadow(color: .black.opacity(0.08), radius: 3, y: 1))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Grouped settings card with hairline-separated rows.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium).strokeBorder(Theme.border))
    }
}

/// One settings row: title, current value, and a control.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var last = false
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.sans(14, .medium)).foregroundStyle(Theme.ink)
                    if let detail {
                        Text(detail).font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                control()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            if !last { Divider().overlay(Theme.border).padding(.leading, 16) }
        }
    }
}

/// The Hub's colour scheme: light by default, with dark as an option.
enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    static var current: Appearance {
        get { Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .light }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "appearance") }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}
