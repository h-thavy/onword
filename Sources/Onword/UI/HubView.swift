import AppKit
import SwiftUI

/// Which page the Hub shows; shared so the menu bar and shortcuts can navigate.
@MainActor
final class HubRouter: ObservableObject {
    static let shared = HubRouter()

    enum Page: String, CaseIterable, Identifiable {
        case dictation, notetaker, dictionary, snippets, scratchpad
        var id: String { rawValue }

        var title: String {
            switch self {
            case .dictation: "Dictation"
            case .notetaker: "Notetaker"
            case .dictionary: "Dictionary"
            case .snippets: "Snippets"
            case .scratchpad: "Scratchpad"
            }
        }

        var icon: String {
            switch self {
            case .dictation: "mic"
            case .notetaker: "smallcircle.filled.circle"
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

/// The main window: a sidebar on the warm frame and the page on a
/// white rounded panel.
struct HubView: View {
    @ObservedObject private var router = HubRouter.shared

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(router: router)
                .frame(width: 212)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.panel))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium).strokeBorder(Theme.border))
                .padding([.top, .trailing, .bottom], 8)
        }
        .background(Theme.frame)
        .font(Theme.sans(14))
        .foregroundStyle(Theme.ink)
        .frame(minWidth: 920, minHeight: 600)
        .overlay { SettingsOverlay(router: router) }
    }

    @ViewBuilder
    private var page: some View {
        switch router.page {
        case .dictation: DictationPage()
        case .notetaker: NotetakerPage()
        case .dictionary: DictionaryPage()
        case .snippets: SnippetsPage()
        case .scratchpad: ScratchpadPage()
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var router: HubRouter
    @ObservedObject private var dictation = DictationController.shared
    @ObservedObject private var recorder = MeetingRecorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                LogoMark(size: 30)
                Text("Onword").font(Theme.serif(24))
            }
                .padding(.leading, 8)
                .padding(.top, 40)      // clears the traffic lights
                .padding(.bottom, 18)

            ForEach(HubRouter.Page.allCases) { page in
                NavItem(title: page.title, icon: page.icon, selected: router.page == page,
                        badge: page == .notetaker && recorder.isRecording ? "REC" : nil) {
                    router.page = page
                }
            }

            Spacer()

            StatusCard(dictation: dictation)
                .padding(.bottom, 8)
            NavItem(title: "Settings", icon: "gearshape", selected: false) {
                router.settingsTab = .general
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 14)
    }
}

private struct NavItem: View {
    let title: String
    let icon: String
    let selected: Bool
    var badge: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 18)
                Text(title).font(Theme.sans(14, selected ? .semibold : .medium))
                Spacer()
                if let badge {
                    Text(badge).font(Theme.sans(10, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.recording))
                }
            }
            .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.radius)
                .fill(selected ? Theme.panel : (hovering ? Theme.selected.opacity(0.6) : .clear))
                .shadow(color: .black.opacity(selected ? 0.05 : 0), radius: 1, y: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
                HStack(spacing: 4) {
                    Text("Hold").font(Theme.sans(12.5))
                    KeyChip(text: dictation.hotkey.chip)
                    Text("and speak").font(Theme.sans(12.5))
                }
                Text("Double-tap for hands-free").font(Theme.sans(11.5)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .foregroundStyle(Theme.inkSecondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.panel.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium).strokeBorder(Theme.border))
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

/// Standard page body: scrollable, comfortable reading width, generous padding.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content() }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 36)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}
