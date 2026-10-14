import AppKit
import OnwordCore
import SwiftUI

/// Notetaker design tokens and small components, following Wispr Flow's Notetaker
/// (Figtree text, sand neutrals, the live-recording green).
enum NT {
    // MARK: Colours

    /// Docked preview panel (sand-100 / background-tertiary).
    static let sidePanel = color(light: 0xFAF9F7, dark: 0x202020)
    /// Unselected tab text and quiet labels (neutral-500).
    static let neutral500 = color(light: 0x4D4A42, dark: 0x9D9C98)
    /// Hovered tab text (neutral-600).
    static let neutral600 = color(light: 0x30302F, dark: 0xDEDDD7)
    /// Date and attendee pills (vast-800).
    static let pillInk = color(light: 0x464544, dark: 0x9D9C98)
    /// Notes-editor placeholder (sand-700).
    static let placeholder = color(light: 0xC5C0B3, dark: 0x5B5B59)
    /// Back button hover.
    static let filledHover = color(light: 0xE2DED5, dark: 0x464544)
    /// Search-dialog and task-row hover (sand-200).
    static let sand200 = color(light: 0xF8F7F3, dark: 0x30302F)
    /// Live recording.
    static let liveText = Color(hex: 0x18A558)
    static let liveBars = Color(hex: 0x3CBB77)
    static let green500 = Color(hex: 0x10B981)
    static let recordingFill = color(light: 0xECFDF5, dark: 0x1D3A2E)
    static let recordingStroke = color(light: 0x059669, dark: 0x34D399)
    static let successFill = Color(hex: 0xD4F6E1)
    static let successInk = Color(hex: 0x368855)
    static let destructive = Color(hex: 0xEE6A6A)
    static let orange100 = Color(hex: 0xFFEDD5)
    /// Checked checklist box (dawn-700).
    static let checkFill = Color(hex: 0xA26EC1)
    static let lumen = Color(hex: 0xFFFFEB)

    /// Google Calendar `colorId` accents.
    static let calendarPalette: [UInt32] = [0x7986CB, 0x33B679, 0x8E24AA, 0xE67C73, 0xF6BF26, 0xF4511E,
                                            0x039BE5, 0x616161, 0x3F51B5, 0x0B8043, 0xD50000]
    /// Speaker names in transcripts, by order of appearance.
    static let speakerPalette: [UInt32] = [0xE89F4D, 0x6B3FAB, 0x3F9970, 0x3D5FE0, 0xC0392B, 0x1ABC9C, 0xD68A2D,
                                           0x8E44AD, 0x2980B9, 0x27AE60, 0xE67E22, 0x16A085, 0x9B59B6, 0x34495E, 0xD35400]

    static func color(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    // MARK: Time labels

    /// "10 - 10:30am", "11:30am - 12pm": ":00" dropped, am/pm said once when both ends share it.
    static func timeRange(_ start: Date, _ end: Date) -> String {
        let (a, aSuffix) = clockParts(start), (b, bSuffix) = clockParts(end)
        return aSuffix == bSuffix ? "\(a) - \(b)\(bSuffix)" : "\(a)\(aSuffix) - \(b)\(bSuffix)"
    }

    /// "2:30pm", "9am".
    static func clock(_ date: Date) -> String {
        let (time, suffix) = clockParts(date)
        return time + suffix
    }

    private static func clockParts(_ date: Date) -> (String, String) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = c.hour ?? 0, minute = c.minute ?? 0
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return (minute == 0 ? "\(h12)" : String(format: "%d:%02d", h12, minute), hour < 12 ? "am" : "pm")
    }

    /// Past-notes day groups: "Today, Oct 14", "Yesterday, Oct 13", "Mon, Oct 12" (shown uppercase).
    static func dayBucket(_ date: Date) -> String {
        let cal = Calendar.current
        let monthDay = date.formatted(.dateTime.month(.abbreviated).day())
        if cal.isDateInToday(date) { return "Today, \(monthDay)" }
        if cal.isDateInYesterday(date) { return "Yesterday, \(monthDay)" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))), \(monthDay)"
    }

    /// Note date pill: "Today", "Tomorrow", "Yesterday" or "Oct 3" (with the year when it differs).
    static func datePill(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if cal.component(.year, from: date) != cal.component(.year, from: Date()) {
            return date.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The countdown on the right of an upcoming row ("in 5 min", "Starting now", "12 min left").
    static func countdown(start: Date, end: Date, now: Date = Date()) -> (text: String, icon: String?)? {
        let toStart = start.timeIntervalSince(now), toEnd = end.timeIntervalSince(now)
        if abs(toStart) <= 60 { return ("Starting now", nil) }
        if toEnd <= 60, toEnd > 0 { return ("Ending soon", nil) }
        if toStart > 0, toStart <= 2 * 3600 {
            let minutes = Int((toStart / 60).rounded(.up))
            if minutes < 1 { return ("now", nil) }
            if minutes < 60 { return ("in \(minutes) min", nil) }
            let h = minutes / 60, m = minutes % 60
            return (m == 0 ? "in \(h) hr" : "in \(h)h \(m)m", nil)
        }
        if toStart < 0, toEnd > 0 {
            let elapsed = -toStart, total = end.timeIntervalSince(start)
            if elapsed < total / 2 {
                let minutes = Int(elapsed / 60)
                return (minutes < 60 ? "\(minutes) min ago" : "\(minutes / 60) hr \(minutes % 60) min ago", nil)
            }
            return ("\(Int((toEnd / 60).rounded(.up))) min left", nil)
        }
        let hour = Calendar.current.component(.hour, from: start)
        if hour >= 23 || hour < 4 { return ("Midnight meeting", "moon") }
        if hour < 7 { return ("Dawn patrol", "sunrise") }
        return nil
    }
}

// MARK: - Text styles

/// 12/20, weight 600, uppercase, 0.075 em tracking ("TODAY", day groups, section labels).
struct Overline: View {
    let text: String
    var color: Color = Theme.ink

    var body: some View {
        Text(text.uppercased()).font(Theme.sans(12, .semibold)).tracking(0.9).foregroundStyle(color)
            .frame(height: 20)
    }
}

// MARK: - Avatars

/// Initials on a coloured tile.
struct Monogram: View {
    let name: String
    var size: CGFloat
    var radius: CGFloat = 0

    var body: some View {
        Rectangle().fill(Color(hex: tint))
            .overlay(Text(initials).font(Theme.sans(size >= 30 ? 13 : 10, .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }

    private var initials: String {
        let parts: [Substring] = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
        var result = ""
        if let first = parts.first?.first { result.append(first) } else { result = "?" }
        if parts.count > 1, let second = parts[1].first { result.append(second) }
        return result.uppercased()
    }

    private var tint: UInt32 {
        let hash = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return NT.speakerPalette[hash % NT.speakerPalette.count]
    }
}

/// Wispr's 36-pt facepile: one person fills the tile, two split it, three are one tall and two quarters,
/// four are a 2×2 grid, more are three faces and "+N". Notes without people get a note tile.
struct Facepile: View {
    let names: [String]
    var size: CGFloat = 36
    var dimmed = false

    var body: some View {
        Group {
            if names.isEmpty {
                RoundedRectangle(cornerRadius: 8).fill(Theme.buttonFill)
                    .overlay(Image(systemName: "note.text").font(.system(size: 15)).foregroundStyle(NT.neutral600))
            } else {
                tiles.clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(width: size, height: size)
        .opacity(dimmed ? 0.7 : 1)
        .saturation(dimmed ? 0.35 : 1)
    }

    @ViewBuilder private var tiles: some View {
        let gap: CGFloat = 1, half = (size - gap) / 2
        switch names.count {
        case 1:
            Monogram(name: names[0], size: size)
        case 2:
            HStack(spacing: gap) {
                Monogram(name: names[0], size: size).frame(width: half)
                Monogram(name: names[1], size: size).frame(width: half)
            }
            .clipped()
        case 3:
            HStack(spacing: gap) {
                Monogram(name: names[0], size: size).frame(width: half).clipped()
                VStack(spacing: gap) {
                    Monogram(name: names[1], size: half)
                    Monogram(name: names[2], size: half)
                }
            }
        default:
            let extra = names.count - 3
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    Monogram(name: names[0], size: half)
                    Monogram(name: names[1], size: half)
                }
                HStack(spacing: gap) {
                    Monogram(name: names[2], size: half)
                    if names.count == 4 {
                        Monogram(name: names[3], size: half)
                    } else {
                        Rectangle().fill(.white)
                            .overlay(Text("+\(extra)").font(Theme.sans(10, .medium)).foregroundStyle(Color(hex: 0x1A1A1A)))
                            .frame(width: half, height: half)
                    }
                }
            }
        }
    }
}

// MARK: - Live recording

/// The green "being recorded" cluster: an 11-bar waveform that follows the audio, and the timer.
struct LiveCluster: View {
    let level: Float
    let elapsed: TimeInterval
    var action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 8) {
                LiveWaveform(level: level, bars: 11, height: 14.1, barWidth: 2.35)
                    .frame(width: 41.4, height: 14.1)
                Text(TimeFormat.clock(elapsed)).font(Theme.sans(15).monospacedDigit()).foregroundStyle(NT.liveText)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(Capsule().fill(hovering ? Color.black.opacity(0.06) : .clear))
        }
        .buttonStyle(.plainPointer)
        .onHover { hovering = $0 }
    }
}

/// Bars that rise with the level and ripple over time.
struct LiveWaveform: View {
    let level: Float
    var bars = 11
    var height: CGFloat = 14
    var barWidth: CGFloat = 2.35
    var color: Color = NT.liveBars

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 0) {
                ForEach(0..<bars, id: \.self) { i in
                    let ripple = (sin(t * 6 + Double(i) * 0.9) + 1) / 2
                    let amount = 0.18 + 0.82 * min(1, Double(level) * 1.6) * (0.45 + 0.55 * ripple)
                    Capsule().fill(color)
                        .frame(width: barWidth, height: max(barWidth, height * amount))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Section header bar ("Multitool")

/// The grey bar heading the Transcript and Summary panels: icon, an uppercase label, actions on the right.
struct MultitoolBar<Actions: View>: View {
    let icon: String
    let label: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.inkTertiary)
            Text(label.uppercased()).font(Theme.sans(12, .semibold)).tracking(0.9).foregroundStyle(Theme.inkTertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 4) { actions() }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.frame))
    }
}

/// A 28-pt action in a section header bar.
struct BarAction: View {
    let icon: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(hovering || active ? Theme.ink : Theme.iconFaint)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.frame : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Buttons

/// 32×32 icon buttons in note headers: "filled" (the Back button) or ghost.
struct HeaderIconButton: View {
    let icon: String
    let help: String
    var filled = false
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
                .foregroundStyle(Theme.ink)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(filled ? (hovering ? NT.filledHover : Theme.buttonFill) : (hovering ? NT.filledHover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .opacity(disabled ? 0.3 : 1)
        .disabled(disabled)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// The conference platform as a small glyph (Meet, Zoom, Teams…), or a generic video icon.
struct PlatformGlyph: View {
    let platform: MeetingPlatform?
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(tint)
    }

    private var symbol: String {
        switch platform {
        case .slack: "number"
        case .teams: "person.2.fill"
        case .discord: "gamecontroller.fill"
        case .facetime: "video.fill"
        default: "video.fill"
        }
    }

    private var tint: Color {
        switch platform {
        case .googleMeet: Color(hex: 0x00897B)
        case .zoom: Color(hex: 0x0B5CFF)
        case .teams: Color(hex: 0x5059C9)
        case .webex: Color(hex: 0x07C160)
        case .slack: Color(hex: 0x611F69)
        case .discord: Color(hex: 0x5865F2)
        case .facetime: Color(hex: 0x34C759)
        case nil: .primary
        }
    }
}

/// "Join + Start" split button on upcoming meetings: dark when the meeting is happening now, outlined
/// otherwise. The chevron offers "Join meeting" and "Start Notetaker". Events without a link get "Start".
struct JoinStartButton: View {
    let meeting: UpcomingMeeting
    let prominent: Bool
    @State private var starting = false
    @State private var hoverMain = false
    @State private var hoverChevron = false

    var body: some View {
        if meeting.joinURL == nil {
            Button { startOnly() } label: {
                HStack(spacing: 6) {
                    RecordDot(size: 14)
                    Text(starting ? "Starting…" : "Start")
                }
                .font(Theme.sans(15, prominent ? .medium : .regular))
                .padding(.horizontal, 12).frame(height: 36)
                .foregroundStyle(prominent ? Theme.onPrimary : Theme.ink)
                .background(RoundedRectangle(cornerRadius: 8).fill(prominent ? Theme.primary : Theme.page))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(prominent ? .clear : Theme.outline))
            }
            .buttonStyle(.plainPointer)
            .disabled(starting)
        } else {
            HStack(spacing: 0) {
                Button { joinAndStart() } label: {
                    HStack(spacing: 6) {
                        if starting {
                            ProgressView().controlSize(.mini).frame(width: 22, height: 22)
                        } else {
                            RoundedRectangle(cornerRadius: 5).fill(prominent ? Theme.onPrimary : Theme.primary)
                                .overlay(PlatformGlyph(platform: meeting.platform, size: 11)
                                    .foregroundStyle(prominent ? Theme.primary : Theme.onPrimary))
                                .frame(width: 22, height: 22)
                        }
                        Text(starting ? "Starting…" : "Join + Start")
                    }
                    .padding(.leading, 6).padding(.trailing, 10).frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plainPointer)
                .onHover { hoverMain = $0 }
                Rectangle().fill(divider).frame(width: 1, height: 20).opacity(hoverMain || hoverChevron ? 0 : 1)
                PopMenuButton(items: [
                    .init(title: "Join meeting", icon: "video") { CalendarService.shared.join(meeting) },
                    .init(title: "Start Notetaker", icon: "record.circle") { startOnly() },
                ]) {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(chevronColor)
                        .padding(.horizontal, 8).frame(height: 36)
                        .contentShape(Rectangle())
                }
                .onHover { hoverChevron = $0 }
            }
            .font(Theme.sans(15, prominent ? .medium : .regular))
            .foregroundStyle(prominent ? Theme.onPrimary : Theme.ink)
            .background(RoundedRectangle(cornerRadius: 8).fill(prominent ? Theme.primary : Theme.page))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(prominent ? .clear : Theme.outline))
            .disabled(starting)
        }
    }

    private var divider: Color { prominent ? Color.white.opacity(0.2) : Color.black.opacity(0.07) }
    private var chevronColor: Color {
        prominent ? Theme.onPrimary.opacity(hoverChevron ? 1 : 0.5) : (hoverChevron ? Theme.ink : Theme.outline)
    }

    private func joinAndStart() {
        starting = true
        NotetakerFlow.shared.joinAndStart(meeting)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { starting = false }
    }

    private func startOnly() {
        starting = true
        NotetakerFlow.shared.start(meeting: meeting)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { starting = false }
    }
}

/// Wispr's record glyph: a ring with a filled centre (lucide disc).
struct RecordDot: View {
    var size: CGFloat = 14
    var color: Color = .primary

    var body: some View {
        ZStack {
            Circle().strokeBorder(color, lineWidth: max(1.2, size / 9))
            Circle().fill(color).frame(width: size * 0.36, height: size * 0.36)
        }
        .frame(width: size, height: size)
    }
}

/// Tasks chip on a past note: "☑ 2 / 5".
struct TasksChip: View {
    let done: Int
    let total: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: done == total ? "checkmark.square" : "square.dashed").font(.system(size: 12))
                Text("\(done) / \(total)").monospacedDigit()
            }
            .font(Theme.sans(15)).foregroundStyle(Theme.ink.opacity(hovering ? 1 : 0.7))
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.buttonFill : .clear))
        }
        .buttonStyle(.plainPointer)
        .onHover { hovering = $0 }
        .help("Open tasks")
    }
}

// MARK: - Pop-up menu

/// A Wispr-style dropdown menu (rounded card, 15-pt items with 14-pt icons) in its own small window, so it
/// can extend outside the view that opened it.
struct PopMenuItem: Identifiable {
    let id = UUID()
    var title: String
    var icon: String?
    var destructive = false
    var divider = false
    var action: () -> Void = {}

    static var separator: PopMenuItem { PopMenuItem(title: "", divider: true) }
}

struct PopMenuButton<Label: View>: View {
    let items: [PopMenuItem]
    var alignment: HorizontalAlignment = .trailing
    /// The dark menu of the Flow Bar's reminder pill.
    var dark = false
    var onOpen: (() -> Void)?
    @ViewBuilder var label: () -> Label
    @State private var anchor = AnchorBox()

    var body: some View {
        Button {
            onOpen?()
            PopMenu.shared.show(items, below: anchor.view, alignment: alignment, dark: dark)
        } label: { label() }
            .buttonStyle(.plainPointer)
            .background(AnchorReader(box: anchor))
    }
}

/// Holds the NSView behind a SwiftUI view, to find its place on screen.
final class AnchorBox {
    weak var view: NSView?
}

struct AnchorReader: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

@MainActor
final class PopMenu {
    static let shared = PopMenu()
    private var panel: NSPanel?
    private var monitors: [Any] = []

    var isOpen: Bool { panel != nil }

    func show(_ items: [PopMenuItem], below view: NSView?, alignment: HorizontalAlignment = .trailing, offset: CGFloat = 6,
              dark: Bool = false) {
        close()
        guard let view, let window = view.window else { return }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let host = NSHostingView(rootView: PopMenuView(items: items, dark: dark) { [weak self] item in
            self?.close()
            item.action()
        }
        .environment(\.colorScheme, window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
        let size = host.fittingSize
        // The menu's card sits 14 pt inside its window (room for the shadow).
        var origin = NSPoint(x: (alignment == .leading ? rect.minX : rect.maxX - size.width) + (alignment == .leading ? -14 : 14),
                             y: rect.minY - offset - size.height + 14)
        if let screen = window.screen?.visibleFrame {
            if origin.y < screen.minY { origin.y = rect.maxY + offset - 14 }
            origin.x = min(max(screen.minX + 4, origin.x), screen.maxX - size.width - 4)
        }
        let panel = KeyablePanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentView = host
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.08; panel.animator().alphaValue = 1 }
        self.panel = panel
        let close: () -> Void = { [weak self] in MainActor.assumeIsolated { self?.close() } }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in close() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak panel] event in
            if event.type == .keyDown {
                if event.keyCode == 53 { close(); return nil }
                return event
            }
            if event.window !== panel { close() }
            return event
        }) { monitors.append(m) }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

private struct PopMenuView: View {
    let items: [PopMenuItem]
    var dark = false
    let choose: (PopMenuItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: dark ? 1 : 2) {
            ForEach(items) { item in
                if item.divider {
                    Rectangle().fill(dark ? Color(hex: 0x343432) : Theme.border).frame(height: 1)
                        .padding(.horizontal, dark ? 0 : 6).padding(.vertical, dark ? 3 : 4)
                } else {
                    PopMenuRow(item: item, dark: dark) { choose(item) }
                }
            }
        }
        .padding(dark ? 4 : 6)
        .frame(minWidth: dark ? 110 : 160, alignment: .leading)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: dark ? 8 : 10).fill(dark ? Color(hex: 0x1A1A1A) : Theme.page))
        .overlay(RoundedRectangle(cornerRadius: dark ? 8 : 10).strokeBorder(dark ? Color(hex: 0x343432) : Theme.border))
        .shadow(color: dark ? .black.opacity(0.38) : Color(hex: 0x1A1A1A).opacity(0.1), radius: dark ? 16 : 7, y: dark ? 8 : 6)
        .padding(14)
        .font(dark ? Theme.sans(12, .medium) : Theme.sans(15))
    }
}

private struct PopMenuRow: View {
    let item: PopMenuItem
    var dark = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon = item.icon { Image(systemName: icon).font(.system(size: dark ? 11 : 12)).frame(width: 14) }
                Text(item.title)
                Spacer(minLength: 0)
            }
            .foregroundStyle(item.destructive ? NT.destructive : dark ? Color(hex: hovering ? 0xFCFCFB : 0xDEDDD7) : Theme.ink)
            .padding(.horizontal, dark ? 8 : 10).padding(.vertical, dark ? 6 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? (item.destructive ? NT.destructive.opacity(0.1) : dark ? Color.white.opacity(0.08) : Theme.frame) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .onHover { hovering = $0 }
    }
}

// MARK: - Rolling status line

/// A phrase that changes every few seconds (processing rows, the generation card).
struct RollingText: View {
    let phrases: [String]
    var interval: TimeInterval = 7
    var font: Font = Theme.sans(12)
    var color: Color = NT.neutral500

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { context in
            let index = Int(context.date.timeIntervalSinceReferenceDate / interval) % max(1, phrases.count)
            Text(phrases.isEmpty ? "" : phrases[index])
                .font(font).foregroundStyle(color)
                .id(index)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
                .animation(.easeOut(duration: 0.8), value: index)
        }
        .clipped()
    }
}
