import AppKit
import SwiftUI

/// Building blocks for the Settings window, matched to Wispr Flow's settings: 15 pt rows on warm cards,
/// 164 pt "Change" buttons, 42×25 switches, and dialogs on a dimmed backdrop.
extension Theme {
    /// Row descriptions and secondary text in Settings.
    static let inkMuted = settingsColor(light: 0x30302F, dark: 0xDEDDD7)
    /// Sidebar section headers, version text, native language names.
    static let inkFaint = settingsColor(light: 0x4D4A42, dark: 0x9D9C98)
    /// Fill of secondary ("Change") buttons and of the selected sidebar item.
    static let buttonFill = settingsColor(light: 0xEEEBE3, dark: 0x30302F)
    static let switchOff = settingsColor(light: 0xC5C0B3, dark: 0x5B5B59)
    /// Selected language tile.
    static let tileSelected = settingsColor(light: 0xFAF1FF, dark: 0x502B66)
    static let tileRing = Color(red: 0xA2 / 255, green: 0x6E / 255, blue: 0xC1 / 255)
    static let scrim = settingsColor(light: 0x1A1A1A, dark: 0x000000)

    private static func settingsColor(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// A settings page: serif title, then sections 24 pt apart, inside 48 pt of padding. The scrollbar is hidden.
struct SettingsPage<Content: View>: View {
    let title: String
    var description: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(Theme.serif(28)).tracking(-1.12)
                    if let description {
                        Text(description).font(Theme.sans(15)).foregroundStyle(Theme.inkMuted)
                    }
                }
                VStack(alignment: .leading, spacing: 24) { content() }
            }
            .padding(48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }
}

/// An optional 15 pt semibold title over a warm card of rows.
struct SettingsSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title { Text(title).font(Theme.sans(15, .semibold)) }
            VStack(alignment: .leading, spacing: 20) { content() }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.frame))
        }
    }
}

/// Title and description on the left, a 164 pt control column on the right, a divider below unless last.
struct SettingsLine<Control: View>: View {
    let title: String
    var description: Text?
    var last = false
    @ViewBuilder var control: () -> Control

    init(_ title: String, _ description: String? = nil, last: Bool = false, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.description = description.map { Text($0) }
        self.last = last
        self.control = control
    }

    init(_ title: String, rich description: Text, last: Bool = false, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.description = description
        self.last = last
        self.control = control
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(Theme.sans(15, .medium))
                    if let description {
                        description.font(Theme.sans(15)).foregroundStyle(Theme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                control().frame(width: 164, alignment: .trailing)
            }
            if !last { Rectangle().fill(Theme.border).frame(height: 1) }
        }
    }
}

/// Wispr's secondary button: warm fill, 15 pt semibold, 8×16 padding, radius 8; fills its column.
struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(15, .semibold))
            .lineLimit(1)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.buttonFill))
            .overlay(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(configuration.isPressed ? 0.08 : 0)))
            .foregroundStyle(Theme.ink)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }
}

/// Wispr's primary button: ink fill, inverted text.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(15, .medium))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.primary.opacity(configuration.isPressed ? 0.85 : 1)))
            .foregroundStyle(Theme.onPrimary)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }
}

/// Wispr's switch: 42×25 track, 21 pt thumb, warm grey off, ink on.
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(configuration.isOn ? Theme.primary : Theme.switchOff)
            .frame(width: 42, height: 25)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle().fill(configuration.isOn ? Theme.onPrimary : .white)
                    .frame(width: 21, height: 21)
                    .padding(2)
                    .shadow(color: .black.opacity(0.1), radius: 1, y: 0.5)
            }
            .animation(.spring(duration: 0.15), value: configuration.isOn)
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityAddTraits(.isButton)
    }
}

/// A switch bound to a value, right-aligned in the control column.
struct SettingsSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).toggleStyle(SettingsSwitchStyle()).labelsHidden()
    }
}

/// A 36 pt dropdown trigger with a 1 pt outline, showing the current value; opens a native menu.
struct SettingsSelect<Items: View>: View {
    let value: String
    @ViewBuilder var items: () -> Items

    var body: some View {
        Menu { items() } label: {
            HStack {
                Text(value).font(Theme.sans(15)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
            }
        }
        .menuStyle(.button)
        .buttonStyle(SelectTriggerStyle())
        .menuIndicator(.hidden)
    }
}

private struct SelectTriggerStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12).frame(height: 36)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? Theme.frame : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            .foregroundStyle(Theme.ink)
            .contentShape(Rectangle())
    }
}

/// A dialog on a dimmed backdrop inside Settings: 24 pt padding, radius 12, 18 pt title.
struct SettingsDialog<Content: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 520
    let close: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Theme.scrim.opacity(0.3).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.sans(18, .semibold))
                    if let subtitle {
                        Text(subtitle).font(Theme.sans(15)).foregroundStyle(Theme.inkFaint)
                            .frame(maxWidth: 416, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
                content()
            }
            .padding(24)
            .frame(width: width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            .compositingGroup()   // one shadow for the whole panel, not one per element
            .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

/// A selectable option row in a dialog (microphones, shortcut keys).
struct DialogOption: View {
    let title: String
    var detail: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.sans(15, .medium))
                    if let detail { Text(detail).font(Theme.sans(12.5)).foregroundStyle(Theme.inkFaint) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.buttonFill : Theme.frame))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
