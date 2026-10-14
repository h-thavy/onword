import AppKit
import SwiftUI

/// One choice in a dropdown.
struct SelectOption: Identifiable {
    var id: String
    var title: String
    var detail: String?
    var icon: String?
    var action: () -> Void
}

/// Wispr Flow's dropdowns, drawn by Onword instead of macOS menus:
/// - `.select`: a 36-pt trigger (1-pt outline, chevron that turns over when open) opening a list 4 pt below,
///   padding 4, radius 6, up to 260 tall; the selected item has a sand fill and weight 600.
/// - `.menu` (Theme): the same trigger with a rounder menu (radius 10, padding 6) and a check on the current item.
/// Long lists, or `searchable`, get a search field at the top.
struct SettingsSelect: View {
    enum Style { case select, menu }

    let value: String
    let options: [SelectOption]
    var selectedID: String?
    var style: Style = .select
    var searchable = false
    var searchPrompt = "Search"
    /// The open list's width; defaults to the trigger's.
    var menuWidth: CGFloat?
    @State private var anchor = AnchorBox()
    @State private var hovering = false
    @ObservedObject private var popup = SelectPopup.shared
    @State private var id = UUID()

    private var open: Bool { popup.openID == id }

    var body: some View {
        Button {
            if open { popup.close() } else {
                popup.show(id: id, options: options, selectedID: selectedID ?? options.first { $0.title == value }?.id,
                           style: style, searchable: searchable || options.count > 8, searchPrompt: searchPrompt,
                           below: anchor.view, width: menuWidth)
            }
        } label: {
            HStack(spacing: 8) {
                Text(value).font(Theme.sans(15)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(open ? -180 : 0))
                    .animation(.timingCurve(0.05, 0.6, 0.4, 0.95, duration: 0.2), value: open)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12).frame(height: 36)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering || open ? Theme.frame : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(hovering || open ? Theme.inkFaint : Theme.border, lineWidth: hovering || open ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .background(AnchorReader(box: anchor))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onAppear {
            // Test hook: ONWORD_TEST_SELECT=<shown value> opens that dropdown (for snapshots).
            guard ProcessInfo.processInfo.environment["ONWORD_TEST_SELECT"] == value else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                popup.show(id: id, options: options, selectedID: selectedID ?? options.first { $0.title == value }?.id,
                           style: style, searchable: searchable || options.count > 8 || ProcessInfo.processInfo.environment["ONWORD_TEST_SELECT_SEARCH"] != nil,
                           searchPrompt: searchPrompt, below: anchor.view, width: menuWidth)
            }
        }
    }
}

/// The open dropdown list, in its own small window so it can extend past the view that opened it.
@MainActor
final class SelectPopup: ObservableObject {
    static let shared = SelectPopup()
    @Published private(set) var openID: UUID?
    private var panel: NSPanel?
    private var monitors: [Any] = []

    func show(id: UUID, options: [SelectOption], selectedID: String?, style: SettingsSelect.Style, searchable: Bool,
              searchPrompt: String, below view: NSView?, width: CGFloat?) {
        close()
        guard let view, let window = view.window else { return }
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        let listWidth = max(width ?? anchor.width, style == .menu ? 160 : 120)
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let content = SelectListView(options: options, selectedID: selectedID, style: style, searchable: searchable,
                                     searchPrompt: searchPrompt, width: listWidth) { [weak self] option in
            self?.close()
            option.action()
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        let shadowMargin: CGFloat = 14
        var origin = NSPoint(x: anchor.minX - shadowMargin, y: anchor.minY - 4 - size.height + shadowMargin)
        if let screen = window.screen?.visibleFrame {
            if origin.y < screen.minY { origin.y = anchor.maxY + 4 - shadowMargin }
            origin.x = min(max(screen.minX, origin.x), screen.maxX - size.width)
        }
        let panel = SelectPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentView = host
        panel.alphaValue = 0
        if searchable { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.08; panel.animator().alphaValue = 1 }
        self.panel = panel
        openID = id

        let closeIt: () -> Void = { [weak self] in MainActor.assumeIsolated { self?.close() } }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in closeIt() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak panel] event in
            if event.type == .keyDown {
                if event.keyCode == 53 { closeIt(); return nil }
                return event
            }
            if event.window !== panel {
                closeIt()
                // A click on the trigger only closes the list.
                return event.window === window && view.frame.contains(view.convert(event.locationInWindow, from: nil)) ? nil : event
            }
            return event
        }) { monitors.append(m) }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        panel = nil
        openID = nil
    }
}

private final class SelectPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct SelectListView: View {
    let options: [SelectOption]
    let selectedID: String?
    let style: SettingsSelect.Style
    let searchable: Bool
    let searchPrompt: String
    let width: CGFloat
    let choose: (SelectOption) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [SelectOption] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return options }
        return options.filter { $0.title.localizedCaseInsensitiveContains(q) || ($0.detail ?? "").localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if searchable {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.inkTertiary)
                    TextField(searchPrompt, text: $query).textFieldStyle(.plain).font(Theme.sans(15))
                        .focused($searchFocused)
                        .onSubmit { if let first = filtered.first { choose(first) } }
                }
                .padding(.horizontal, 8).frame(height: 32)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                .padding(.bottom, 4)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: style == .menu ? 2 : 0) {
                    ForEach(filtered) { option in
                        SelectRow(option: option, selected: option.id == selectedID, style: style) { choose(option) }
                    }
                    if filtered.isEmpty {
                        Text("No results").font(Theme.sans(15)).foregroundStyle(Theme.inkTertiary)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(style == .menu ? 6 : 4)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: style == .menu ? 10 : 6).fill(style == .menu ? Theme.page : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: style == .menu ? 10 : 6).strokeBorder(Theme.border))
        .shadow(color: Color(hex: 0x1A1A1A).opacity(style == .menu ? 0.1 : 0.06), radius: style == .menu ? 7 : 4, y: style == .menu ? 6 : 2)
        .padding(14)
        .onAppear { if searchable { DispatchQueue.main.async { searchFocused = true } } }
    }
}

private struct SelectRow: View {
    let option: SelectOption
    let selected: Bool
    let style: SettingsSelect.Style
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon = option.icon { Image(systemName: icon).font(.system(size: 13)).frame(width: 16) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(option.title).font(Theme.sans(15, selected ? .semibold : .regular))
                    if let detail = option.detail {
                        Text(detail).font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                Spacer(minLength: 8)
                if style == .menu, selected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).frame(width: 16)
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, style == .menu ? 10 : 8).padding(.vertical, style == .menu ? 8 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: style == .menu ? 6 : 4)
                .fill(selected && style == .select ? Theme.frame : hovering ? Theme.frame : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .onHover { hovering = $0 }
    }
}
