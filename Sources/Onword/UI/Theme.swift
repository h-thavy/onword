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
    /// The Hub's page panel (background): warm off-white, not pure white.
    static let page = dynamic(light: 0xFCFCFB, dark: 0x1A1A1A)
    /// Status and upcoming-meeting cards (muted-hover).
    static let mutedCard = dynamic(light: 0xF1EBE1, dark: 0x30302F)
    /// Quiet toolbar and row-action icons at rest (vast-300).
    static let iconFaint = dynamic(light: 0xB3B2AD, dark: 0x9D9C98)
    /// Outline-variant button border (sand-700).
    static let outline = dynamic(light: 0xC5C0B3, dark: 0x5B5B59)
    /// Orange key chip and glow badges (glow-300, the same in both modes).
    static let glow = Color(red: 1, green: 0xA9 / 255, blue: 0x46 / 255)
    /// The Scratchpad shortcut pill (sand-300 / vast-900, ring border / vast-800).
    static let shortcutPill = dynamic(light: 0xF7F6F2, dark: 0x30302F)
    static let shortcutPillRing = dynamic(light: 0xEEEBE3, dark: 0x464544)
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

/// Page title row: 24 pt semibold Figtree title, optional badge, actions on the right.
struct PageHeader<Actions: View>: View {
    let title: String
    var badge: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title).font(Theme.sans(24, .semibold)).foregroundStyle(Theme.ink)
            if let badge {
                Text(badge).font(Theme.sans(12, .medium)).foregroundStyle(Color(hex: 0x1A1A1A))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xF0D7FF)))
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
        VStack(alignment: .leading, spacing: 8) {
            Text("\(before)\(Text(italic).font(Theme.serif(28, italic: true)))\(after)")
                .font(Theme.serif(28)).tracking(-1.12)
                .foregroundStyle(Theme.ink)
            Text(message).font(Theme.sans(15)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            action().padding(.top, 16)
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLarge).fill(Theme.accent.opacity(0.55)))
    }
}

/// Primary (dark) or secondary (sand) button: radius 8, 15 pt, 36 tall — or 32 at `.small`.
struct PillButtonStyle: ButtonStyle {
    var prominent = true
    var tint: Color?
    /// Draw a 1-pt outline instead of the sand fill (the "outline" variant).
    var bordered = false

    func makeBody(configuration: Configuration) -> some View { styledBody(configuration).pointerCursor() }

    @ViewBuilder private func styledBody(_ configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent, tint: tint, bordered: bordered)
    }
}

private struct PillBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let tint: Color?
    let bordered: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    private var small: Bool { controlSize == .small || controlSize == .mini }

    var body: some View {
        configuration.label
            .font(Theme.sans(15, prominent ? .medium : .semibold))
            .padding(.horizontal, small ? 12 : 16).padding(.vertical, small ? 6 : 8)
            .foregroundStyle(prominent ? Theme.onPrimary : Theme.ink)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .fill(prominent ? (tint ?? Theme.primary) : (bordered ? Theme.page : Theme.buttonFill))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                        .strokeBorder(bordered ? Theme.outline : .clear))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
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
    var box: CGFloat = 28
    var icon: CGFloat = 16
    /// Give the button a filled, 1-pt-bordered tile (floating actions on cards).
    var bordered = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: icon))
                .frame(width: box, height: box)
                .foregroundStyle(hovering ? Theme.ink : Theme.iconFaint)
                .background(RoundedRectangle(cornerRadius: box > 32 ? 8 : 6)
                    .fill(bordered ? Theme.panel : (hovering ? Theme.frame : .clear)))
                .overlay(RoundedRectangle(cornerRadius: box > 32 ? 8 : 6)
                    .strokeBorder(bordered ? Theme.border : .clear))
        }
        .buttonStyle(.plainPointer)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// A keyboard-key chip, e.g. "fn".
struct KeyChip: View {
    let text: String

    /// Drawn as keycaps (a combination like ⌃⌥S becomes control, option and S keys), like the shortcut key.
    var body: some View { KeyCombo(text: text, scale: 0.42) }

}

/// Rounded search field.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.inkTertiary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(Theme.sans(15))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkTertiary) }
                    .buttonStyle(.plainPointer)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
    }
}

/// Uppercase group label ("TODAY").
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(Theme.sans(12, .semibold)).tracking(0.9).foregroundStyle(Theme.inkTertiary)
    }
}

/// A table row that reveals its trailing actions on hover. The actions keep their
/// space (opacity, not removal), so a one-line row is exactly 52 tall.
struct HoverRow<Content: View, Actions: View>: View {
    var selected = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.init(top: 16, leading: 16, bottom: 16, trailing: 4))
            actions()
                .opacity(hovering || selected ? 1 : 0)
                .padding(.init(top: 12, leading: 0, bottom: 12, trailing: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected || hovering ? Theme.frame : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
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

/// One rounded list table: hairline-separated rows inside a 16-radius, 1-pt border.
struct TableCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge).strokeBorder(Theme.border))
    }
}

/// The orange keycap ("fn"): 1-pt ink border, radius 5.5, hard offset shadow.
struct GlowChip: View {
    let text: String

    var body: some View {
        Text(text).font(Theme.sans(15, .semibold)).foregroundStyle(Color(hex: 0x1A1A1A))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5.5).fill(Theme.glow))
            .overlay(RoundedRectangle(cornerRadius: 5.5).strokeBorder(Color(hex: 0x1A1A1A)))
            .shadow(color: Color(hex: 0x1A1A1A), radius: 0, x: -0.8, y: 0.8)
    }
}

/// A selected underline tab: 15 pt semibold, 2-pt ink underline, 12-pt padding.
struct UnderlineTab: View {
    let title: String

    var body: some View {
        Text(title).font(Theme.sans(15, .semibold)).foregroundStyle(Theme.ink)
            .padding(12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.ink).frame(height: 2).padding(.horizontal, 12)
            }
    }
}

/// A list's empty state: centred message on a sand tile.
struct EmptyState: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(Theme.sans(16, .medium))
            if let detail {
                Text(detail).font(Theme.sans(15)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLarge).fill(Theme.frame))
        .padding(.vertical, 16)
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

// MARK: - Pointer cursor

extension View {
    /// Shows the pointing-hand cursor while the pointer is over this view (clickable things, as in Wispr Flow).
    func pointerCursor(_ enabled: Bool = true) -> some View {
        onContinuousHover { phase in
            guard enabled else { return }
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

/// `.plain`, plus the pointing-hand cursor.
struct PlainPointerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.pointerCursor()
    }
}

extension ButtonStyle where Self == PlainPointerButtonStyle {
    static var plainPointer: PlainPointerButtonStyle { PlainPointerButtonStyle() }
}
