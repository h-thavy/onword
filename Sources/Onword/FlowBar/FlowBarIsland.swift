import AppKit
import Combine
import OnwordCore
import SwiftUI

/// Notetaker's floating surfaces above the Flow Bar, as in Wispr Flow: the calendar reminder pill
/// ("Meeting starting" / "Meeting detected") and the black notification cards ("Notetaker stopping",
/// "Started by mistake?"…). Both grow out of the bar, centred over it. The window is click-through
/// except over the visible card.
@MainActor
final class FlowBarIsland: ObservableObject {
    static let shared = FlowBarIsland()

    // MARK: Reminder pill

    struct Reminder: Identifiable, Equatable {
        enum Surface { case scheduled, detected }
        let id: String
        var title: String
        /// Detected calls: the app or platform ("Google Meet in Opera GX"), or "Meeting detected" under an
        /// event's title.
        var subtitle: String? = nil
        var start: Date
        var surface: Surface
        var platform: MeetingPlatform?
        var meeting: UpcomingMeeting?
        /// Detected calls with "Start Notetaker automatically" on: seconds of countdown before recording.
        var autoStartSeconds: TimeInterval?
        var dismissAt: Date

        static func == (a: Reminder, b: Reminder) -> Bool { a.id == b.id && a.title == b.title && a.start == b.start }
        var joinable: Bool { meeting?.joinURL != nil }
    }

    @Published private(set) var reminders: [Reminder] = []
    @Published var expandedID: String?
    @Published var busyID: String?
    @Published var autoStartStarted: [String: Date] = [:]

    // MARK: Toasts

    struct Action: Identifiable {
        enum Style { case link, dark, light, lumen, ghost, softDark }
        let id = UUID()
        var title: String
        var style: Style = .link
        var run: () -> Void
    }

    enum Kind {
        /// One line with a record-disc icon, actions and an optional draining progress line.
        case condensed
        /// Title and body, with a yellow alert or red error icon.
        case standard(status: Status, body: String?)
        /// "Continue transcribing?" countdown card before the length limit.
        case maxLength(ends: Date, limitTitle: String, canExtend: Bool)
        /// "Your summary is ready!".
        case summaryReady(meetingTitle: String)
        enum Status { case alert, error, info }
    }

    struct Toast: Identifiable {
        let id = UUID()
        var title: String
        var kind: Kind
        var actions: [Action] = []
        /// 0 = stays until answered.
        var timeout: TimeInterval
        var onTimeout: (() -> Void)?
        var onHover: ((Bool) -> Void)?
        /// Hovering pauses the countdown.
        var pausesOnHover = true
    }

    @Published private(set) var toast: Toast?
    /// Seconds left on the toast's countdown, and whether it's paused.
    @Published private(set) var toastRemaining: TimeInterval = 0
    @Published var toastHovered = false {
        didSet { toast?.onHover?(toastHovered) }
    }

    /// Where the visible card is in the window (window coordinates, top-left origin), for hit testing.
    var hotRect: CGRect = .zero

    private var panel: NSPanel?
    private var ticker: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private static let size = CGSize(width: 480, height: 360)

    private init() {}

    func showReminder(_ reminder: Reminder) {
        reminders.removeAll { $0.id == reminder.id }
        reminders.insert(reminder, at: 0)
        reminders = Array(reminders.prefix(4))
        expandedID = reminder.id
        if let seconds = reminder.autoStartSeconds, seconds > 0 { autoStartStarted[reminder.id] = Date() }
        // The newest card shows in full for 5 s, then folds to its one-line row.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.expandedID == reminder.id, !self.pillHovered, !PopMenu.shared.isOpen else { return }
            self.expandedID = nil
        }
        present()
    }

    func dismissReminder(_ id: String) {
        reminders.removeAll { $0.id == id }
        autoStartStarted[id] = nil
        if expandedID == id { expandedID = nil }
        present()
    }

    func reminder(_ id: String) -> Reminder? { reminders.first { $0.id == id } }

    @Published var pillHovered = false {
        didSet {
            if pillHovered {
                expandedID = reminders.first?.id
            } else {
                // A short grace before folding back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
                    guard let self, !self.pillHovered, !PopMenu.shared.isOpen else { return }
                    self.expandedID = nil
                }
            }
        }
    }

    func show(_ toast: Toast) {
        self.toast = toast
        toastRemaining = toast.timeout
        toastHovered = false
        present()
    }

    func hideToast() {
        toast = nil
        present()
    }

    // MARK: - Window

    private func present() {
        let visible = toast != nil || !reminders.isEmpty
        ticker?.invalidate()
        ticker = nil
        if visible {
            ensurePanel()
            reposition()
            panel?.orderFrontRegardless()
            ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated { FlowBarIsland.shared.tick() }
            }
        } else {
            // Let the card fold away first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
                guard let self, self.toast == nil, self.reminders.isEmpty else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    private func tick() {
        reposition()
        let now = Date()
        // Toast countdown (paused while hovered).
        if let toast, toast.timeout > 0 {
            if !(toastHovered && toast.pausesOnHover) { toastRemaining -= 0.1 }
            if toastRemaining <= 0 {
                let done = toast.onTimeout
                self.toast = nil
                present()
                done?()
                return
            }
        }
        // Reminders expire unless you're hovering them.
        if !pillHovered, !PopMenu.shared.isOpen {
            let expired = reminders.filter { $0.dismissAt <= now }
            for r in expired {
                if r.surface == .detected { MeetingDetector.shared.cardIgnored() }
                dismissReminder(r.id)
            }
        }
        // Auto-start countdowns.
        for (id, began) in autoStartStarted {
            guard let r = reminder(id), let seconds = r.autoStartSeconds else { continue }
            if now.timeIntervalSince(began) >= seconds {
                autoStartStarted[id] = nil
                NotetakerFlow.shared.startFromReminder(r)
            }
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = IslandPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        let container = IslandContainer(frame: NSRect(origin: .zero, size: Self.size))
        let host = NSHostingView(rootView: IslandView(island: self))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
        self.panel = panel
    }

    /// Centred over the Flow Bar, its bottom on the bar's canvas bottom (the Dock top).
    private func reposition() {
        guard let panel, let bar = FlowBar.shared.canvasFrame else { return }
        let origin = NSPoint(x: (bar.midX - Self.size.width / 2).rounded(), y: bar.minY)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets clicks through everywhere except the visible card.
private final class IslandContainer: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let rect = MainActor.assumeIsolated { FlowBarIsland.shared.hotRect }
        let flipped = CGPoint(x: point.x, y: bounds.height - point.y)
        return rect.insetBy(dx: -12, dy: -12).contains(flipped) ? super.hitTest(point) : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Views

private struct IslandView: View {
    @ObservedObject var island: FlowBarIsland
    @ObservedObject private var recorder = MeetingRecorder.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            VStack(spacing: 8) {
                if !island.reminders.isEmpty {
                    ReminderStack(island: island)
                        .transition(.scale(scale: 0.1, anchor: .bottom).combined(with: .opacity))
                }
                if let toast = island.toast {
                    ToastCard(island: island, toast: toast)
                        .id(toast.id)
                        .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
                }
            }
            .background(GeometryReader { geo in
                Color.clear.preference(key: HotRectKey.self, value: geo.frame(in: .named("island")))
            })
            // 14 pt above the canvas bottom (level with the bar), 50 while the green meeting bar shows.
            .padding(.bottom, recorder.isRecording && island.toast == nil ? 50 : 14)
        }
        .coordinateSpace(name: "island")
        .onPreferenceChange(HotRectKey.self) { rect in
            MainActor.assumeIsolated { FlowBarIsland.shared.hotRect = rect }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: island.reminders.map(\.id))
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: island.toast?.id)
        .environment(\.colorScheme, .dark)
        .font(Theme.sans(15))
    }
}

private struct HotRectKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        value = value == .zero ? next : value.union(next)
    }
}

// MARK: Reminder pill

private struct ReminderStack: View {
    @ObservedObject var island: FlowBarIsland

    var body: some View {
        let items = island.reminders
        ZStack(alignment: .bottom) {
            // Cards behind peek above the front one.
            ForEach(Array(items.dropFirst().enumerated()).reversed(), id: \.element.id) { index, _ in
                let i = CGFloat(index + 1)
                RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x1F1F1F))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(hex: 0x30302F), lineWidth: 1.5))
                    .frame(width: 416, height: 48)
                    .scaleEffect(pow(0.975, i), anchor: .bottom)
                    .offset(y: -(8 + 7 * (i - 1)))
                    .opacity(1 - 0.1 * Double(i))
            }
            if let front = items.first {
                ReminderCard(island: island, reminder: front, expanded: island.expandedID == front.id)
            }
        }
        .onHover { island.pillHovered = $0 }
    }
}

private struct ReminderCard: View {
    @ObservedObject var island: FlowBarIsland
    let reminder: FlowBarIsland.Reminder
    let expanded: Bool
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .frame(width: 416, height: expanded ? 80 : 48)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x1F1F1F)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(hex: 0x30302F), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.38), radius: 16, y: 8)
        .overlay(alignment: .topLeading) {
            if hovering {
                Button {
                    if reminder.surface == .detected { MeetingDetector.shared.cardClosed() }
                    island.dismissReminder(reminder.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color(hex: 0x1A1A1A).opacity(0.9)))
                        .overlay(Circle().strokeBorder(Color(hex: 0x2C2C2C)))
                        .shadow(color: .black.opacity(0.4), radius: 5, y: 4)
                }
                .buttonStyle(.plainPointer)
                .offset(x: -8, y: -10)
                .help("Dismiss")
            }
        }
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: expanded)
    }

    /// Mini (48 tall): badge, title, time. Card (80 tall): badge, title over time, and the split button.
    @ViewBuilder private func content(now: Date) -> some View {
        HStack(spacing: 8) {
            badge
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    title
                    meta(now: now)
                }
                cta
            } else {
                title
                meta(now: now)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, expanded ? 16 : 0)
    }

    /// One line, clipped by a 20-pt fade at the right edge (no ellipsis).
    private var title: some View {
        Text(reminder.title.isEmpty ? (reminder.surface == .detected ? "Meeting detected" : "Meeting starting") : reminder.title)
            .font(Theme.sans(15, .medium)).foregroundStyle(Color(hex: 0xFCFCFB))
            .lineLimit(1).fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .mask(HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 20)
            })
            .clipped()
    }

    private var badge: some View {
        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08))
            .overlay(PlatformGlyph(platform: reminder.platform, size: 12).foregroundStyle(Color(hex: 0xDEDDD7)))
            .frame(width: 24, height: 24)
    }

    private func meta(now: Date) -> some View {
        HStack(spacing: 5) {
            if imminent(now) { RoundedRectangle(cornerRadius: 2).fill(NT.green500).frame(width: 6, height: 6) }
            Text(reminder.subtitle.map { "\($0) · \(timeLabel(now))" } ?? timeLabel(now))
        }
        .font(Theme.sans(12)).foregroundStyle(Color(hex: 0x71716E))
    }

    private func imminent(_ now: Date) -> Bool {
        let end = reminder.meeting?.end ?? reminder.start.addingTimeInterval(3600)
        return (reminder.start <= now && end > now) || (reminder.start.timeIntervalSince(now) <= 600 && reminder.start > now)
    }

    private func timeLabel(_ now: Date) -> String {
        let seconds = reminder.start.timeIntervalSince(now)
        if seconds > 600 { return NT.clock(reminder.start) }
        if seconds >= 60 { return "In \(Int((seconds / 60).rounded(.up))) min" }
        return "Now"
    }

    /// Lumen split button: "Join meeting / & start Notetaker", or "Start Notetaker".
    private var cta: some View {
        let busy = island.busyID == reminder.id
        return HStack(spacing: 0) {
            Button { primary() } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 5).fill(Color(hex: 0x1A1A1A))
                        .overlay(Image(systemName: "waveform").font(.system(size: 11, weight: .bold)).foregroundStyle(NT.lumen))
                        .frame(width: 24, height: 24)
                    if busy {
                        Text(MeetingRecorder.shared.isRecording ? "Switching…" : "Starting…").font(Theme.sans(12, .semibold))
                    } else if reminder.joinable && reminder.surface == .scheduled {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Join meeting").font(Theme.sans(12, .semibold))
                            Text("& start Notetaker").font(Theme.sans(10, .medium)).opacity(0.8)
                        }
                    } else {
                        Text(MeetingRecorder.shared.isRecording ? "Switch" : "Start Notetaker").font(Theme.sans(12, .semibold))
                    }
                }
                .foregroundStyle(Color(hex: 0x1A1A1A))
                .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 8)
                .background(alignment: .leading) { autoStartFill }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainPointer)
            .disabled(busy)
            PopMenuButton(items: menuItems, dark: true, onOpen: { island.autoStartStarted[reminder.id] = nil }) {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x1A1A1A))
                    .padding(.horizontal, 6).frame(maxHeight: .infinity)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(hex: 0xC8C8C2)).frame(width: 1) }
            }
        }
        .fixedSize()
        .background(NT.lumen)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: 0xEEEBE3)))
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }

    /// The auto-start countdown: a darker fill sliding across the button.
    @ViewBuilder private var autoStartFill: some View {
        if let began = island.autoStartStarted[reminder.id], let seconds = reminder.autoStartSeconds {
            TimelineView(.animation) { context in
                let progress = min(1, context.date.timeIntervalSince(began) / seconds)
                GeometryReader { geo in
                    Rectangle().fill(Color(hex: 0xEFEFC9))
                        .overlay(alignment: .trailing) { Rectangle().fill(Color(hex: 0xA9A939)).frame(width: 2) }
                        .frame(width: geo.size.width * progress)
                }
            }
            .help("Starts automatically when the countdown ends")
        }
    }

    private var menuItems: [PopMenuItem] {
        var items: [PopMenuItem] = []
        if reminder.joinable, let meeting = reminder.meeting {
            items.append(.init(title: "Join meeting") { island.dismissReminder(reminder.id); CalendarService.shared.join(meeting) })
            items.append(.init(title: "Start Notetaker") { island.dismissReminder(reminder.id); NotetakerFlow.shared.start(meeting: meeting) })
        }
        items.append(.init(title: "Snooze for 2 min") { NotetakerFlow.shared.snooze(reminder) })
        items.append(.separator)
        let auto = MeetingDetector.shared.mode == .auto
        items.append(.init(title: auto ? "✓ Start Notetaker automatically" : "Start Notetaker automatically") {
            MeetingDetector.shared.mode = auto ? .ask : .auto
        })
        items.append(.init(title: "Notification settings") {
            WindowManager.shared.show()
            HubRouter.shared.settingsTab = .notetaker
        })
        return items
    }

    private func primary() {
        island.busyID = reminder.id
        if reminder.joinable && reminder.surface == .scheduled, let meeting = reminder.meeting {
            NotetakerFlow.shared.joinAndStart(meeting)
            island.dismissReminder(reminder.id)
        } else {
            NotetakerFlow.shared.startFromReminder(reminder)
        }
        island.busyID = nil
    }
}

// MARK: Toasts

private struct ToastCard: View {
    @ObservedObject var island: FlowBarIsland
    let toast: FlowBarIsland.Toast

    var body: some View {
        Group {
            switch toast.kind {
            case .condensed: condensed
            case .standard(let status, let body): standard(status: status, body: body)
            case .maxLength(let ends, let limit, let canExtend): MaxLengthCard(toast: toast, ends: ends, limit: limit, canExtend: canExtend)
            case .summaryReady(let title): summaryReady(title)
            }
        }
        .onHover { island.toastHovered = $0 }
    }

    /// One line: disc icon, title, actions (shown second-first), and a lumen progress line along the bottom.
    private var condensed: some View {
        HStack(spacing: 16) {
            RecordDot(size: 16, color: Color(hex: 0xFCFCFB))
            Text(toast.title).font(Theme.sans(15, .medium)).foregroundStyle(Color(hex: 0xFCFCFB))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(toast.actions) { action in ToastButton(action: action) { island.hideToast() } }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(minHeight: 48)
        .fixedSize()
        .background(alignment: .bottom) {
            if toast.timeout > 0 {
                GeometryReader { geo in
                    let progress = 1 - max(0, island.toastRemaining) / toast.timeout
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color(hex: 0x71716E))
                        Rectangle().fill(NT.lumen).frame(width: geo.size.width * progress)
                    }
                    .frame(height: 3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .background(Color(hex: 0x1A1A1A))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: Color(hex: 0x1A1A1A).opacity(0.1), radius: 8, y: 6)
    }

    private func standard(status: FlowBarIsland.Kind.Status, body: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                switch status {
                case .alert: Image(systemName: "exclamationmark.triangle").font(.system(size: 16)).foregroundStyle(Color(hex: 0xFFD467))
                case .error: Image(systemName: "exclamationmark.circle").font(.system(size: 16)).foregroundStyle(Color(hex: 0xEE6A6A))
                case .info: Image(systemName: "info.circle").font(.system(size: 16)).foregroundStyle(Color(hex: 0xF0D7FF))
                }
                Text(toast.title).font(Theme.sans(15, .semibold)).foregroundStyle(Color(hex: 0xFCFCFB))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                TimedClose(remaining: island.toastRemaining, total: toast.timeout) { island.hideToast() }
            }
            if let body {
                Text(body).font(Theme.sans(15)).foregroundStyle(Color(hex: 0xB3B2AD))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !toast.actions.isEmpty {
                HStack(spacing: 8) {
                    Spacer()
                    ForEach(toast.actions) { action in ToastButton(action: action) { island.hideToast() } }
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(minWidth: 340, maxWidth: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(.black))
    }

    private func summaryReady(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xE4E4D0))
                .frame(height: 116)
                .overlay {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 14)).foregroundStyle(Color(hex: 0x1A1A1A))
                        Text("Your summary is ready!").font(Theme.sans(15, .medium)).foregroundStyle(Color(hex: 0x1A1A1A))
                            .multilineTextAlignment(.center).frame(maxWidth: 104)
                    }
                    .padding(12)
                    .frame(width: 193)
                    .frame(minHeight: 85)
                    .background(RoundedRectangle(cornerRadius: 7.5).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: 7.5).strokeBorder(
                        AngularGradient(colors: [Color(hex: 0xD193DA), Color(hex: 0x8242AE), Color(hex: 0xFBAB57),
                                                 Color(hex: 0xFD7354), Color(hex: 0xFFB8EA), Color(hex: 0xD193DA)],
                                        center: .center), lineWidth: 1.26))
                }
                .overlay(alignment: .topTrailing) {
                    TimedClose(remaining: island.toastRemaining, total: toast.timeout, dark: true) { island.hideToast() }
                        .padding(8)
                }
            Text(title.isEmpty ? "Synthesized your notes" : "From \(title)")
                .font(Theme.sans(15)).foregroundStyle(Color(hex: 0xB3B2AD)).padding(.top, 16)
            ForEach(toast.actions) { action in
                Button { island.hideToast(); action.run() } label: {
                    Text(action.title).font(Theme.sans(15, .semibold)).foregroundStyle(Color(hex: 0x1A1A1A))
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0xEEEBE3)))
                }
                .buttonStyle(.plainPointer)
                .padding(.top, 24)
            }
        }
        .padding(12)
        .frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 24).fill(.black))
    }
}

/// Small round close button with a ring that drains over the toast's lifetime.
private struct TimedClose: View {
    let remaining: TimeInterval
    let total: TimeInterval
    var dark = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(hex: 0xFCFCFB))
                .frame(width: 24, height: 24)
                .background(Circle().fill(hovering || dark ? Color(hex: 0x30302F) : .clear))
                .overlay {
                    if total > 0 {
                        ZStack {
                            Circle().stroke(.white.opacity(0.1), lineWidth: 1.5)
                            Circle().trim(from: 0, to: max(0, remaining / total))
                                .stroke(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 26, height: 26)
                    }
                }
        }
        .buttonStyle(.plainPointer)
        .onHover { hovering = $0 }
        .help("Dismiss")
    }
}

private struct ToastButton: View {
    let action: FlowBarIsland.Action
    let hide: () -> Void
    @State private var hovering = false

    var body: some View {
        Button { hide(); action.run() } label: {
            Text(action.title)
                .font(Theme.sans(15, action.style == .dark ? .medium : .semibold))
                .underline(action.style == .link && hovering)
                .foregroundStyle(foreground)
                .padding(.horizontal, action.style == .ghost ? 0 : 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(fill))
                .opacity(action.style == .lumen && hovering ? 0.85 : 1)
        }
        .buttonStyle(.plainPointer)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch action.style {
        case .link: Color(hex: hovering ? 0xFCFCFB : 0xB3B2AD)
        case .dark, .softDark, .ghost: Color(hex: 0xFCFCFB)
        case .light, .lumen: Color(hex: 0x1A1A1A)
        }
    }

    private var fill: Color {
        switch action.style {
        case .link, .ghost: .clear
        case .dark: Color(hex: hovering ? 0x30302F : 0x1A1A1A)
        case .softDark: Color(hex: hovering ? 0x5B5B59 : 0x71716E)
        case .light: Color(hex: 0xEEEBE3)
        case .lumen: NT.lumen
        }
    }
}

/// "Continue transcribing?": a big lumen countdown, then Yes (pick a longer limit) or End recording.
private struct MaxLengthCard: View {
    let toast: FlowBarIsland.Toast
    let ends: Date
    let limit: String
    let canExtend: Bool
    @State private var picking = false
    @State private var choice = NotetakerSettings.maxLengthOptions.last ?? 180

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if picking {
                Text("Change auto-end time?").font(Theme.sans(15, .semibold)).foregroundStyle(Color(hex: 0xFCFCFB))
                    .padding(.trailing, 24)
                Text("We'll still check with you before ending it").font(Theme.sans(15)).foregroundStyle(Color(hex: 0xB3B2AD))
                    .padding(.top, 4)
                // A dark select, like the card.
                PopMenuButton(items: NotetakerSettings.maxLengthOptions.filter { $0 > NotetakerSettings.maxLengthMinutes }.map { minutes in
                    PopMenuItem(title: NotetakerSettings.title(forMinutes: minutes), icon: choice == minutes ? "checkmark" : nil) { choice = minutes }
                }, alignment: .leading, dark: true) {
                    HStack {
                        Text(NotetakerSettings.title(forMinutes: choice)).font(Theme.sans(15))
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color(hex: 0xFCFCFB))
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x30302F)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0x464544)))
                }
                .padding(.top, 12)
                Button {
                    NotetakerSettings.maxLengthMinutes = choice
                    FlowBarIsland.shared.hideToast()
                } label: {
                    Text("Save").font(Theme.sans(15, .semibold)).foregroundStyle(Color(hex: 0x1A1A1A))
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(NT.lumen))
                }
                .buttonStyle(.plainPointer).padding(.top, 12)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, ends.timeIntervalSince(context.date))
                    Text("\(TimeFormat.clock(left)) min").font(Theme.sans(32, .semibold).monospacedDigit())
                        .foregroundStyle(Color(hex: 0x1A1A1A))
                        .frame(maxWidth: .infinity).frame(height: 100)
                        .background(RoundedRectangle(cornerRadius: 16).fill(NT.lumen))
                }
                Text(canExtend ? "Continue transcribing?" : "Transcription will end soon")
                    .font(Theme.sans(15, .semibold)).foregroundStyle(Color(hex: 0xFCFCFB)).padding(.top, 12)
                Text(canExtend ? "We'll auto-end transcriptions at \(limit). Would you like to extend this meeting?"
                               : "\(limit) is the limit for transcriptions.")
                    .font(Theme.sans(15)).foregroundStyle(Color(hex: 0xB3B2AD)).padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                    if canExtend {
                        Button { picking = true } label: {
                            Text("Yes").font(Theme.sans(15, .semibold)).foregroundStyle(Color(hex: 0x1A1A1A))
                                .frame(maxWidth: .infinity).frame(height: 36)
                                .background(RoundedRectangle(cornerRadius: 8).fill(NT.lumen))
                        }
                        .buttonStyle(.plainPointer)
                    }
                    Button {
                        FlowBarIsland.shared.hideToast()
                        MeetingRecorder.shared.stop()
                    } label: {
                        Text("End recording").font(Theme.sans(15, .semibold)).foregroundStyle(Color(hex: 0xEEEBE3))
                            .frame(maxWidth: .infinity).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x30302F)))
                    }
                    .buttonStyle(.plainPointer)
                }
                .padding(.top, 12)
            }
        }
        .padding(12)
        .frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color(hex: 0x1A1A1A)))
        .overlay(alignment: .topTrailing) {
            Button { FlowBarIsland.shared.hideToast() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(hex: 0xFCFCFB))
                    .frame(width: 24, height: 24).background(Circle().fill(Color(hex: 0x30302F)))
            }
            .buttonStyle(.plainPointer)
            .padding(picking ? 12 : 20)
            .help("Dismiss")
        }
    }
}
