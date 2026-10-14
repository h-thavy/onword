import AppKit
import SwiftUI

/// Which page the Hub shows; shared so the menu bar and shortcuts can navigate.
@MainActor
final class HubRouter: ObservableObject {
    static let shared = HubRouter()

    enum Page: String, CaseIterable, Identifiable {
        case dictation, notetaker, insights, dictionary, snippets, scratchpad
        var id: String { rawValue }

        var title: String {
            switch self {
            case .dictation: "Dictation"
            case .notetaker: "Notetaker"
            case .insights: "Insights"
            case .dictionary: "Dictionary"
            case .snippets: "Snippets"
            case .scratchpad: "Scratchpad"
            }
        }

        var icon: String {
            switch self {
            case .dictation: "mic"
            case .notetaker: "smallcircle.filled.circle"
            case .insights: "chart.bar"
            case .dictionary: "book.closed"
            case .snippets: "scissors"
            case .scratchpad: "note.text"
            }
        }
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general, system, notetaker, connections, privacy
        var id: String { rawValue }
    }

    @Published var page: Page = .dictation
    @Published var settingsTab: SettingsTab?
    @Published var selectedMeetingID: UUID?
}

/// The main window: a 52-pt title strip, then a sidebar on the warm frame and the
/// page on a rounded panel (24 pt corners on top, 16 on the bottom).
struct HubView: View {
    @ObservedObject private var router = HubRouter.shared
    @AppStorage("hubSidebarCollapsed") private var collapsed = false

    private let panel = UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 16,
                                               bottomTrailingRadius: 16, topTrailingRadius: 24)

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                TitleStrip(collapsed: $collapsed, canCollapse: geo.size.width >= 1000)
                HStack(spacing: 0) {
                    Sidebar(router: router, collapsed: collapsed)
                        .frame(width: collapsed ? 60 : 216)
                    page
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(panel.fill(Theme.page))
                        .clipShape(panel)
                        .overlay(panel.strokeBorder(Theme.border))
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                }
            }
        }
        .ignoresSafeArea()   // the strip shares the 52 pt title-bar row with the traffic lights
        .background(Theme.frame)
        .font(Theme.sans(15))
        .foregroundStyle(Theme.ink)
        .overlay { SettingsOverlay(router: router) }
        .animation(.easeOut(duration: 0.15), value: collapsed)
    }

    @ViewBuilder
    private var page: some View {
        switch router.page {
        case .dictation: DictationPage()
        case .notetaker: NotetakerPage()
        case .insights: InsightsPage()
        case .dictionary: DictionaryPage()
        case .snippets: SnippetsPage()
        case .scratchpad: ScratchpadPage()
        }
    }
}

/// The full-width draggable strip across the top. The traffic lights sit in the first
/// 76 pt; the sidebar-collapse button is a 32×32 tile at x 92.
private struct TitleStrip: View {
    @Binding var collapsed: Bool
    let canCollapse: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button { collapsed.toggle() } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(Theme.ink)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.buttonFill : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plainPointer)
            .help(collapsed ? "Show sidebar" : "Hide sidebar")
            .disabled(!canCollapse && !collapsed)
            .opacity(canCollapse || collapsed ? 1 : 0.4)
            .onHover { hovering = $0 }
            .padding(.leading, 92)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
    }
}

private struct Sidebar: View {
    @ObservedObject var router: HubRouter
    var collapsed: Bool
    @ObservedObject private var dictation = DictationController.shared
    @ObservedObject private var recorder = MeetingRecorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                // The mark's glyph fills about half its box, so 34 pt makes the bars as tall as the wordmark.
                LogoMark(size: 34).padding(.leading, -4)
                if !collapsed {
                    // Onword's serif wordmark, sized like Wispr's 20 pt-tall wordmark.
                    Text("Onword").font(Theme.serif(26)).padding(.leading, 2)
                }
            }
            .padding(.horizontal, 5).padding(.vertical, 4)
            .padding(.bottom, 16)

            VStack(spacing: 4) {
                ForEach(HubRouter.Page.allCases) { page in
                    NavItem(title: page.title, icon: page.icon, selected: router.page == page,
                            collapsed: collapsed,
                            badge: page == .notetaker && recorder.isRecording ? "REC" : nil) {
                        router.page = page
                    }
                }
            }

            Spacer(minLength: 0)

            if !collapsed {
                StatusCard(dictation: dictation)
                    .padding(.bottom, 8)
            }
            Divider().overlay(Theme.border)
                .padding(.bottom, 8)
            NavItem(title: "Settings", icon: "gearshape", selected: false, collapsed: collapsed) {
                router.settingsTab = .general
            }
        }
        .padding(12)
    }
}

private struct NavItem: View {
    let title: String
    let icon: String
    let selected: Bool
    var collapsed = false
    var badge: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 20, height: 20)
                if !collapsed {
                    Text(title).font(Theme.sans(15, .medium))
                    Spacer()
                    if let badge {
                        Text(badge).font(Theme.sans(10, .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.recording))
                    }
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selected || hovering ? Theme.buttonFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Bottom-of-sidebar reminder of how to dictate, or what needs fixing.
private struct StatusCard: View {
    @ObservedObject var dictation: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch dictation.state {
            case .needsPermissions:
                Label("Permissions needed", systemImage: "exclamationmark.triangle").font(Theme.sans(12.5, .semibold))
                Button("Fix in Settings") { HubRouter.shared.settingsTab = .system }
                    .buttonStyle(.pillQuiet)
            case .loadingModel:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading speech model…").font(Theme.sans(12.5))
                }
            default:
                // The real key, drawn as a Mac keycap; it lights up while you hold it.
                HStack(spacing: 10) {
                    MiniKeycap(key: dictation.hotkey, pressed: dictation.hotkeyIsDown)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hold to speak").font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink)
                        Text("Double-tap: hands-free").font(Theme.sans(11.5)).foregroundStyle(Theme.inkTertiary)
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                }
            }
        }
        .foregroundStyle(Theme.inkSecondary)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mutedCard))
    }
}

extension HotkeyMonitor.Key {
    /// Short label for a key chip.
    var chip: String {
        switch self {
        case .fn: "fn"
        case .rightOption: "right ⌥"
        case .rightCommand: "right ⌘"
        }
    }
}

/// Standard page body: scrollable, centred, 40 pt of padding on the top and sides.
/// Content is capped at `maxWidth` — or max(800, half the window) when nil.
struct PageScroll<Content: View>: View {
    var maxWidth: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) { content() }
                    .frame(maxWidth: maxWidth ?? max(800, geo.size.width / 2), alignment: .leading)
                    .padding(.horizontal, 40)
                    .padding(.top, 40)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
    }
}
