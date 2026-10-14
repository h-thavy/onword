import AppKit
import SwiftUI

/// A folder of meeting notes (Wispr Flow's Notetaker folders, kept on this Mac). A note can be in any
/// number of folders; deleting a folder keeps its notes.
struct NoteFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var description: String?
    var createdAt = Date()
}

@MainActor
final class FolderStore: ObservableObject {
    static let shared = FolderStore()

    /// By name, as Wispr Flow lists them.
    @Published private(set) var folders: [NoteFolder] = []
    private var url: URL { AppPaths.root.appendingPathComponent("folders.json") }

    private init() {
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            folders = (try? decoder.decode([NoteFolder].self, from: data)) ?? []
        }
        sort()
    }

    func folder(_ id: UUID) -> NoteFolder? { folders.first { $0.id == id } }

    @discardableResult
    func create(name: String, description: String?) -> NoteFolder {
        let folder = NoteFolder(name: String(name.trimmingCharacters(in: .whitespaces).prefix(200)),
                                description: description.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)) }
                                    .flatMap { $0.isEmpty ? nil : $0 })
        folders.append(folder)
        save()
        return folder
    }

    func update(_ id: UUID, name: String, description: String?) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = String(name.trimmingCharacters(in: .whitespaces).prefix(200))
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        folders[i].description = trimmed.isEmpty ? nil : String(trimmed.prefix(2000))
        save()
    }

    /// Only the folder goes; its notes stay in your library.
    func delete(_ id: UUID) {
        folders.removeAll { $0.id == id }
        save()
        for meeting in MeetingStore.shared.meetings where meeting.folderIDs?.contains(id) == true {
            MeetingStore.shared.update(meeting.id) { $0.folderIDs?.removeAll { $0 == id } }
        }
    }

    /// Notes in a folder, newest first.
    func notes(in id: UUID) -> [Meeting] {
        MeetingStore.shared.meetings.filter { $0.folderIDs?.contains(id) == true && ($0.status != .draft || !$0.notes.isEmpty) }
    }

    func toggle(_ folder: UUID, for meeting: UUID) {
        MeetingStore.shared.update(meeting) { m in
            var ids = m.folderIDs ?? []
            if let i = ids.firstIndex(of: folder) { ids.remove(at: i) } else { ids.append(folder) }
            m.folderIDs = ids.isEmpty ? nil : ids
        }
    }

    /// A meeting's folders, in folder order.
    func folders(of meeting: Meeting) -> [NoteFolder] {
        let ids = Set(meeting.folderIDs ?? [])
        return folders.filter { ids.contains($0.id) }
    }

    private func sort() {
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func save() {
        sort()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(folders).write(to: url, options: .atomic)
    }
}

// MARK: - Chips

/// The folder chip on a note: folder icon, the first folder's name (14 characters) and "+N". On past-note rows
/// it shrinks to the icon until the row is hovered. With no folders: a dashed "Add to folder" chip
/// ("Create folder" while you have none; "Add folder" under a note's title).
struct FolderChip: View {
    let meeting: Meeting
    /// On a past-note row: collapsed to the icon unless the row is hovered; hidden when empty and not hovered.
    var inRow = false
    var rowHovered = false
    @ObservedObject private var store = FolderStore.shared
    @State private var anchor = AnchorBox()
    @State private var hovering = false

    var body: some View {
        let folders = store.folders(of: meeting)
        Group {
            if let first = folders.first {
                chip {
                    Image(systemName: "folder").font(.system(size: 11))
                    if !inRow || rowHovered || open {
                        Text(first.name.count > 14 ? String(first.name.prefix(14)) + "…" : first.name)
                        if folders.count > 1 { Text("+\(folders.count - 1)").foregroundStyle(Theme.inkTertiary) }
                    }
                }
                .help(first.name)
            } else if !inRow || rowHovered || open {
                Button(action: tap) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder").font(.system(size: 11))
                        Text(inRow ? (store.folders.isEmpty ? "Create folder" : "Add to folder") : "Add folder")
                    }
                    .font(Theme.sans(12)).foregroundStyle(inRow ? Theme.inkTertiary : NT.pillInk).lineLimit(1).fixedSize()
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: inRow ? 4 : 6).fill(hovering || open ? Theme.buttonFill : .clear))
                    .overlay(RoundedRectangle(cornerRadius: inRow ? 4 : 6)
                        .strokeBorder(hovering || open ? Theme.buttonFill : (inRow ? Theme.inkTertiary.opacity(0.6) : Theme.border),
                                      style: StrokeStyle(lineWidth: 1, dash: hovering || open ? [] : [3, 2])))
                }
                .buttonStyle(.plainPointer)
                .onHover { hovering = $0 }
            }
        }
        .background(AnchorReader(box: anchor))
    }

    private var open: Bool { FolderPicker.shared.openMeetingID == meeting.id }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let collapsed = inRow && !rowHovered && !open
        return Button(action: tap) {
            HStack(spacing: 8, content: content)
                .font(Theme.sans(12)).foregroundStyle(hovering ? Theme.ink : NT.pillInk).lineLimit(1).fixedSize()
                .padding(.horizontal, collapsed ? 4 : 8).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: collapsed ? 4 : 6)
                    .fill(open ? Theme.buttonFill : hovering ? NT.sidePanel : .clear))
                .overlay(RoundedRectangle(cornerRadius: collapsed ? 4 : 6)
                    .strokeBorder(open ? Theme.buttonFill : collapsed ? .clear : Theme.border))
        }
        .buttonStyle(.plainPointer)
        .onHover { hovering = $0 }
    }

    private func tap() {
        // With no folders at all, go straight to creating one (and file this note in it).
        if store.folders.isEmpty {
            FolderEditor.shared.create(prefill: "", over: anchor.view?.window) { FolderStore.shared.toggle($0.id, for: meeting.id) }
        } else {
            FolderPicker.shared.toggle(for: meeting.id, below: anchor.view)
        }
    }
}

// MARK: - Picker

/// "Add to folder": search, a checklist that stays open (a note can be in several folders), each folder's "…"
/// to edit it, and "Create new folder" (named from the search).
@MainActor
final class FolderPicker: ObservableObject {
    static let shared = FolderPicker()
    @Published private(set) var openMeetingID: UUID?
    private var panel: NSPanel?
    private var monitors: [Any] = []

    func toggle(for meetingID: UUID, below view: NSView?) {
        if openMeetingID == meetingID { close(); return }
        close()
        guard let view, let window = view.window else { return }
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let host = NSHostingView(rootView: FolderPickerView(meetingID: meetingID, window: window)
            .environment(\.colorScheme, dark ? .dark : .light))
        let size = host.fittingSize
        var origin = NSPoint(x: anchor.minX - 14, y: anchor.minY - 4 - size.height + 14)
        if let screen = window.screen?.visibleFrame, origin.y < screen.minY { origin.y = anchor.maxY + 4 - 14 }
        let panel = PickerPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        openMeetingID = meetingID
        let closeIt: () -> Void = { [weak self] in MainActor.assumeIsolated { self?.close() } }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in closeIt() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown], handler: { [weak panel] event in
            if event.type == .keyDown { if event.keyCode == 53 { closeIt(); return nil }; return event }
            if event.window !== panel && !(PopMenu.shared.isOpen) {
                // A click on the chip itself just closes (the chip's own action would reopen it).
                if event.window === window, view.frame.contains(view.convert(event.locationInWindow, from: nil)) { closeIt(); return nil }
                closeIt()
            }
            return event
        }) { monitors.append(m) }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        panel = nil
        openMeetingID = nil
    }
}

private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct FolderPickerView: View {
    let meetingID: UUID
    weak var window: NSWindow?
    @ObservedObject private var store = FolderStore.shared
    @ObservedObject private var meetings = MeetingStore.shared
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [NoteFolder] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? store.folders : store.folders.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let checked = Set(meetings.meeting(meetingID)?.folderIDs ?? [])
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Color(hex: 0x878683))
                TextField("Search folders", text: $query).textFieldStyle(.plain).font(Theme.sans(15)).focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkTertiary) }
                        .buttonStyle(.plainPointer)
                }
            }
            .padding(.leading, 8).padding(.trailing, 10).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .padding(.init(top: 12, leading: 12, bottom: 10, trailing: 12))
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filtered) { folder in
                        FolderPickerRow(folder: folder, checked: checked.contains(folder.id)) {
                            store.toggle(folder.id, for: meetingID)
                        } edit: {
                            FolderPicker.shared.close()
                            FolderEditor.shared.edit(folder, over: window)
                        }
                    }
                    if filtered.isEmpty {
                        Text(store.folders.isEmpty ? "No folders yet." : "No folders match that name.")
                            .font(Theme.sans(15)).foregroundStyle(Theme.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                .padding(.init(top: 6, leading: 8, bottom: 8, trailing: 8))
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            CreateFolderFooter {
                let name = query
                FolderPicker.shared.close()
                FolderEditor.shared.create(prefill: name, over: window) { FolderStore.shared.toggle($0.id, for: meetingID) }
            }
            .padding(.init(top: 6, leading: 8, bottom: 8, trailing: 8))
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: Color(hex: 0x1A1A1A).opacity(0.1), radius: 7, y: 6)
        .padding(14)
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }
}

private struct FolderPickerRow: View {
    let folder: NoteFolder
    let checked: Bool
    let toggle: () -> Void
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).opacity(checked ? 1 : 0).frame(width: 16)
                    Text(folder.name).font(Theme.sans(15)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 8).frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainPointer)
            PopMenuButton(items: [.init(title: "Edit", icon: "pencil", action: edit)]) {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .opacity(hovering ? 1 : 0)
            .padding(.trailing, 4)
        }
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(checked ? (hovering ? Theme.buttonFill : Theme.frame) : (hovering ? NT.sidePanel : .clear)))
        .onHover { hovering = $0 }
    }
}

private struct CreateFolderFooter: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                Text("Create new folder").font(Theme.sans(15))
                Spacer()
            }
            .foregroundStyle(hovering ? Theme.ink : Color(hex: 0x878683))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? NT.sidePanel : Theme.page))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .onHover { hovering = $0 }
    }
}

// MARK: - Create / Edit / Delete

/// The "Create folder" / "Edit folder" dialog and the delete confirmation, shown over the window they came from.
@MainActor
final class FolderEditor {
    static let shared = FolderEditor()
    private var panel: NSPanel?

    func create(prefill: String, over window: NSWindow?, onSaved: @escaping (NoteFolder) -> Void = { _ in }) {
        present(over: window) { close in
            FolderEditorView(folder: nil, prefill: prefill, close: close) { name, description in
                onSaved(FolderStore.shared.create(name: name, description: description))
            }
        }
    }

    func edit(_ folder: NoteFolder, over window: NSWindow?) {
        present(over: window) { close in
            FolderEditorView(folder: folder, prefill: folder.name, close: close) { name, description in
                FolderStore.shared.update(folder.id, name: name, description: description)
            }
        }
    }

    /// "Delete the folder “X”?" — opens a moment after the editor closes, as in Wispr Flow.
    func confirmDelete(_ folder: NoteFolder, over window: NSWindow?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.present(over: window) { close in
                DeleteFolderView(folder: folder, close: close)
            }
        }
    }

    private func present<Content: View>(over window: NSWindow?, @ViewBuilder content: (@escaping () -> Void) -> Content) {
        dismiss()
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let frame = window.frame
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let close: () -> Void = { [weak self] in MainActor.assumeIsolated { self?.dismiss() } }
        let root = ZStack {
            Color.black.opacity(0.3).onTapGesture(perform: close)
            content(close)
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        let panel = ModalPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = window.level
        panel.contentView = NSHostingView(rootView: root)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func dismiss() {
        if let panel { panel.parent?.removeChildWindow(panel) }
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class ModalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { MainActor.assumeIsolated { FolderEditor.shared.dismiss() } }
}

private struct FolderEditorView: View {
    let folder: NoteFolder?
    let prefill: String
    let close: () -> Void
    let save: (String, String?) -> Void
    @State private var name = ""
    @State private var description = ""
    @FocusState private var nameFocused: Bool

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(folder == nil ? "Create folder" : "Edit folder").font(Theme.sans(20, .semibold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plainPointer).help("Close")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(Theme.sans(15, .medium))
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Color(hex: 0x878683))
                    TextField("Folder name", text: $name).textFieldStyle(.plain).font(Theme.sans(15)).focused($nameFocused)
                        .onChange(of: name) { _, value in if value.count > 200 { name = String(value.prefix(200)) } }
                        .onSubmit { if canSave { commit() } }
                }
                .padding(.horizontal, 12).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(nameFocused ? Theme.inkFaint : Theme.border, lineWidth: nameFocused ? 2 : 1))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Description").font(Theme.sans(15, .medium))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $description).font(Theme.sans(15)).scrollContentBackground(.hidden)
                        .padding(.horizontal, 5).padding(.vertical, 6)
                        .onChange(of: description) { _, value in if value.count > 2000 { description = String(value.prefix(2000)) } }
                    if description.isEmpty {
                        Text("Helps Onword suggest when to use this folder").font(Theme.sans(15)).foregroundStyle(Theme.inkTertiary)
                            .padding(.horizontal, 10).padding(.vertical, 8).allowsHitTesting(false)
                    }
                }
                .frame(height: 102)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }
            HStack {
                if let folder {
                    Button {
                        close()
                        FolderEditor.shared.confirmDelete(folder, over: NSApp.keyWindow?.parent ?? NSApp.mainWindow)
                    } label: { Label("Delete", systemImage: "trash") }
                        .buttonStyle(PillButtonStyle(prominent: false, bordered: true)).controlSize(.small)
                        .help("Delete folder")
                }
                Spacer()
                Button(folder == nil ? "Create" : "Save", action: commit)
                    .buttonStyle(.pill).controlSize(.small)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.page))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
        .font(Theme.sans(15))
        .foregroundStyle(Theme.ink)
        .onAppear {
            name = prefill
            description = folder?.description ?? ""
            DispatchQueue.main.async { nameFocused = true }
        }
    }

    private func commit() {
        guard canSave else { return }
        let unchanged = folder != nil && name == folder?.name && description == (folder?.description ?? "")
        if !unchanged { save(name, description) }
        close()
    }
}

private struct DeleteFolderView: View {
    let folder: NoteFolder
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Delete the folder “\(folder.name)”?").font(Theme.sans(18, .semibold))
                Text("Only the folder is deleted. Your notes stay in your library.").font(Theme.sans(15)).foregroundStyle(Theme.inkFaint)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: close).buttonStyle(.pillQuiet).controlSize(.small).keyboardShortcut(.cancelAction)
                Button("Delete") {
                    if HubRouter.shared.openFolderID == folder.id { HubRouter.shared.openFolderID = nil }
                    FolderStore.shared.delete(folder.id)
                    close()
                }
                .buttonStyle(PillButtonStyle(tint: Color(hex: 0xEE6A6A))).controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.page))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
        .foregroundStyle(Theme.ink)
    }
}
