import AppKit
import ServiceManagement
import SwiftUI

/// Settings, laid out like Wispr Flow's: a 960×640 panel over the Hub with a grouped sidebar on the left and
/// pages of warm cards on the right. Shown by `SettingsOverlay`.
struct SettingsView: View {
    @State var tab: HubRouter.SettingsTab
    @ObservedObject private var dictation = DictationController.shared
    @ObservedObject private var detector = MeetingDetector.shared
    @ObservedObject private var calendar = CalendarService.shared
    @ObservedObject private var google = GoogleCalendar.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var appearance = Appearance.current
    @State private var dialog: Dialog?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showInDock = DockIcon.isShown
    @State private var userName = UserProfile.name ?? ""
    @State private var nameSaved = false
    @AppStorage("showFlowBar") private var showFlowBar = true
    @AppStorage("scratchpadOpenBehavior") private var scratchpadOpenBehavior = "resume"
    @AppStorage(HistoryRetention.key) private var historyRetention = HistoryRetention.keep.rawValue

    enum Dialog: Identifiable {
        case shortcut, microphone, languages, confirmNeverStore
        var id: Self { self }
    }

    private func close() { HubRouter.shared.settingsTab = nil }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Group {
                switch tab {
                case .general: general
                case .system: system
                case .notetaker: notetaker
                case .connections: connections
                case .privacy: privacy
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 960, height: 640)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { dialogView }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .font(Theme.sans(15))
        .foregroundStyle(Theme.ink)
        .animation(.spring(duration: 0.15), value: dialog)
        .background {
            // Esc closes the open dialog, or Settings; ⌥↑ / ⌥↓ move between pages.
            Button("") { if dialog != nil { dialog = nil } else { close() } }
                .keyboardShortcut(.cancelAction).opacity(0)
            Button("") { move(-1) }.keyboardShortcut(.upArrow, modifiers: .option).opacity(0)
            Button("") { move(1) }.keyboardShortcut(.downArrow, modifiers: .option).opacity(0)
        }
        .onAppear {
            updates.checkIfStale()
            if ProcessInfo.processInfo.environment["ONWORD_TEST_SETTINGS"] == "languages" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { dialog = .languages }
            }
        }
    }

    private func move(_ step: Int) {
        let all = HubRouter.SettingsTab.allCases
        guard let index = all.firstIndex(of: tab) else { return }
        tab = all[(index + step + all.count) % all.count]
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            sidebarGroup("Settings", [.general, .system, .notetaker, .connections])
            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 2)
            sidebarGroup("Privacy", [.privacy])
            Spacer()
            Text("Changes save automatically")
                .font(Theme.sans(12)).foregroundStyle(Theme.inkFaint)
                .padding(.horizontal, 8)
            HStack {
                Text("Onword v\(UpdateChecker.currentVersion)")
                Spacer()
                updateButton
            }
            .font(Theme.sans(12)).foregroundStyle(Theme.inkFaint)
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .padding(8)
        .frame(width: 208)
        .frame(maxHeight: .infinity)
        .background(Theme.frame)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
    }

    private func sidebarGroup(_ title: String, _ tabs: [HubRouter.SettingsTab]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(Theme.sans(12, .semibold)).tracking(0.9).foregroundStyle(Theme.inkFaint)
                .padding(8)
            ForEach(tabs) { item in
                Button { tab = item } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.icon).font(.system(size: 15)).frame(width: 20, height: 20)
                        Text(item.title).font(Theme.sans(15, .medium))
                        Spacer()
                    }
                    .padding(8).frame(minHeight: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(tab == item ? Theme.buttonFill : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plainPointer)
            }
        }
    }

    @ViewBuilder private var updateButton: some View {
        switch updates.state {
        case .checking:
            ProgressView().controlSize(.mini).frame(width: 28, height: 28).help("Checking for updates…")
        case .available(let version):
            Button { updates.openRelease() } label: {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 14)).foregroundStyle(Theme.tileRing)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plainPointer).help("Onword \(version) is available — click to see how to update")
        case .upToDate, .unknown:
            Button { updates.check() } label: {
                Image(systemName: updates.state == .upToDate ? "checkmark.icloud" : "icloud")
                    .font(.system(size: 13)).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plainPointer).help(updates.state == .upToDate ? "Up to date; check again?" : "Check for updates")
        }
    }

    // MARK: General

    private var general: some View {
        SettingsPage(title: "General") {
            SettingsSection {
                SettingsLine("Your name", rich: nameDescription) {
                    // Typed text is saved with Save (or Return); everything else in Settings applies instantly.
                    HStack(spacing: 6) {
                        TextField("Name", text: $userName)
                            .textFieldStyle(.plain).font(Theme.sans(15))
                            .onSubmit(saveName)
                        if nameChanged {
                            Button(action: saveName) {
                                Text("Save").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.onPrimary)
                                    .padding(.horizontal, 10).frame(height: 28)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.primary))
                            }
                            .buttonStyle(.plainPointer)
                            .keyboardShortcut(.defaultAction)
                            .transition(.opacity)
                        }
                    }
                    .padding(.leading, 12).padding(.trailing, nameChanged ? 4 : 12).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(nameChanged ? Theme.tileRing : Theme.border))
                    .animation(.easeOut(duration: 0.12), value: nameChanged)
                }
                SettingsLine("Shortcuts", rich: Text("Hold \(Text(dictation.hotkey.title).fontWeight(.semibold).foregroundColor(Theme.ink)) and speak. Double-tap for hands-free, Esc cancels.")) {
                    Button("Change") { dialog = .shortcut }.buttonStyle(SecondaryButtonStyle())
                }
                SettingsLine("Microphone", microphoneDescription) {
                    Button("Change") { dialog = .microphone }.buttonStyle(SecondaryButtonStyle())
                }
                SettingsLine("Languages", languagesDescription) {
                    Button("Change") { dialog = .languages }.buttonStyle(SecondaryButtonStyle())
                }
                SettingsLine("Speed", "Runs on this Mac. More accurate models take longer to load.") {
                    SettingsSelect(value: (dictation.pendingModel?.model.tier ?? dictation.model.tier).title) {
                        ForEach(Transcriber.Model.Tier.allCases) { tier in
                            Button("\(tier.title) — \(tier.detail)") { dictation.chooseTier(tier) }
                        }
                    }
                }
                SettingsLine("Remove filler words", "Drops “um”, “uh” and “hmm” from dictation.") {
                    SettingsSwitch(isOn: $dictation.removeFillers)
                }
                SettingsLine("Theme", last: true) {
                    SettingsSelect(value: appearance.title) {
                        ForEach(Appearance.allCases) { option in
                            Button(option.title) {
                                appearance = option
                                Appearance.current = option
                                WindowManager.shared.applyAppearance()
                            }
                        }
                    }
                }
            }
            if let pending = dictation.pendingModel { PendingModelBanner(pending: pending) }
            if dictation.hotkey == .fn, let conflict = GlobeKey.conflict {
                SettingsSection {
                    SettingsLine("🌐 key conflict", "Your 🌐 key also \(conflict). Set “Press 🌐 key to” → Do Nothing.", last: true) {
                        Button("Open Keyboard") { GlobeKey.openKeyboardSettings() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
    }

    private var nameChanged: Bool {
        userName.trimmingCharacters(in: .whitespacesAndNewlines) != (UserProfile.name ?? "")
    }

    private var nameDescription: Text {
        nameSaved ? Text("Saved \(Image(systemName: "checkmark"))").foregroundColor(Color(red: 0.25, green: 0.55, blue: 0.35))
                  : Text("Used in greetings and for you in meeting notes.")
    }

    private func saveName() {
        guard nameChanged else { return }
        UserProfile.name = userName
        userName = UserProfile.name ?? ""
        nameSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { nameSaved = false }
    }

    private var microphoneDescription: String {
        let active = AudioDevices.resolve(preference: dictation.microphoneUID)?.name ?? "the Mac's microphone"
        switch dictation.microphoneUID {
        case nil, AudioDevices.automatic?: return "Auto-detect · using \(active)"
        case AudioDevices.systemDefault?: return "System default · \(active)"
        default: return active
        }
    }

    private var languagesDescription: String {
        if let pending = dictation.pendingModel {
            return pending.failure == nil
                ? "Downloading the model… \(Int(pending.progress * 100))%"
                : "Download failed — see below"
        }
        return Languages.summary(dictation.selectedLanguages)
    }

    // MARK: System

    private var system: some View {
        SettingsPage(title: "System") {
            SettingsSection(title: "App settings") {
                SettingsLine("Launch app at login") {
                    SettingsSwitch(isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                }
                SettingsLine("Show Flow Bar at all times", "The small bar above the Dock for dictation and Notetaker. It still appears while you dictate.") {
                    SettingsSwitch(isOn: Binding(get: { showFlowBar }, set: { showFlowBar = $0; Self.flowBarSettingChanged() }))
                }
                SettingsLine("Show app in Dock", last: true) {
                    SettingsSwitch(isOn: Binding(get: { showInDock }, set: { showInDock = $0; DockIcon.isShown = $0 }))
                }
            }
            SettingsSection(title: "Permissions") {
                permissionLine("Microphone", "To hear you.", Permissions.microphone) {
                    Task { _ = await Permissions.requestMicrophone() }
                }
                permissionLine("Accessibility", "To read the text field you're in and paste.", Permissions.accessibility) {
                    Permissions.requestAccessibility()
                }
                permissionLine("Input Monitoring", "To notice the shortcut in other apps.", Permissions.inputMonitoring, last: true) {
                    Permissions.requestInputMonitoring()
                }
            }
            SettingsSection(title: "Scratchpad") {
                SettingsLine("Scratchpad open behavior", "What ⌃⌥S shows when you open the Scratchpad.", last: true) {
                    SettingsSelect(value: scratchpadOpenBehavior == "newTab" ? "Open in new tab" : "Resume last note") {
                        Button("Resume last note") { scratchpadOpenBehavior = "resume" }
                        Button("Open in new tab") { scratchpadOpenBehavior = "newTab" }
                    }
                }
            }
            SettingsSection(title: "Data") {
                SettingsLine("Restart tutorial", "Walk through the downloads, permissions, shortcut and practice steps again.", last: true) {
                    Button("Restart tutorial") {
                        close()
                        WindowManager.shared.showOnboarding()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    /// Lets the Flow Bar react to its setting (it reads `showFlowBar` from UserDefaults).
    static func flowBarSettingChanged() {
        NotificationCenter.default.post(name: .flowBarSettingChanged, object: nil)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func permissionLine(_ name: String, _ why: String, _ granted: Bool, last: Bool = false,
                                request: @escaping () -> Void) -> some View {
        SettingsLine(name, why, last: last) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").font(Theme.sans(15, .medium))
                    .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 0.35))
            } else {
                Button("Allow…", action: request).buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    // MARK: Notetaker

    private var notetaker: some View {
        SettingsPage(title: "Notetaker") {
            SettingsSection(title: "Meeting detection") {
                SettingsLine("Notify before scheduled meetings start", "Offers to join the call and take notes.") {
                    SettingsSwitch(isOn: $calendar.remindersEnabled)
                }
                SettingsLine("When a call starts", "Zoom, Teams, FaceTime, Webex, Discord, or Meet / Teams / Slack huddles in a browser.") {
                    SettingsSelect(value: detector.mode.title) {
                        ForEach(MeetingDetector.Mode.allCases) { mode in Button(mode.title) { detector.mode = mode } }
                    }
                }
                SettingsLine("Start or stop Notetaker", "From any app.", last: true) {
                    KeyChip(text: "⌃⌥M")
                }
            }
            SettingsSection(title: "Notes") {
                SettingsLine("Summaries & action items",
                             MeetingSummarizer.shared.unavailableReason ?? "Written on this Mac by Apple Intelligence.") {
                    Image(systemName: MeetingSummarizer.shared.unavailableReason == nil ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(MeetingSummarizer.shared.unavailableReason == nil ? Theme.ink : Theme.inkTertiary)
                }
                SettingsLine("Speaker names", "Class names Onword looks for in Meet, Teams and Slack. Edit if names stop appearing.", last: true) {
                    Button("Edit") {
                        let url = AppPaths.root.appendingPathComponent("speaker-markers.json")
                        if !FileManager.default.fileExists(atPath: url.path) {
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            try? encoder.encode(ActiveSpeakerPoller.defaultMarkers).write(to: url)
                        }
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    // MARK: Connections

    private var connections: some View {
        SettingsPage(title: "Connections") {
            SettingsSection(title: "Calendar") {
                SettingsLine("Google Calendar", googleStatus) {
                    if google.isConnected {
                        Button("Disconnect") { google.disconnect() }.buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button(google.isConnecting ? "Waiting…" : "Connect") { google.connect() }
                            .buttonStyle(SecondaryButtonStyle()).disabled(!google.isConfigured || google.isConnecting)
                    }
                }
                SettingsLine("Mac Calendar", google.isConnected ? "Not used while Google Calendar is connected." : calendarStatus, last: true) {
                    switch calendar.access {
                    case .granted:
                        Label("Allowed", systemImage: "checkmark.circle.fill").font(Theme.sans(15, .medium))
                            .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 0.35))
                    case .notDetermined:
                        Button("Use") { calendar.requestAccess() }.buttonStyle(SecondaryButtonStyle())
                    case .denied:
                        Button("Allow…") { CalendarService.openPrivacySettings() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            if google.isConnected, !calendar.googleCalendars.isEmpty {
                SettingsSection(title: "Calendars to show") {
                    ForEach(Array(calendar.googleCalendars.enumerated()), id: \.element.id) { index, item in
                        SettingsLine(item.summary ?? item.id, item.primary == true ? "Primary" : nil,
                                     last: index == calendar.googleCalendars.count - 1) {
                            SettingsSwitch(isOn: shownBinding(item.id))
                        }
                    }
                }
            } else if calendar.access == .granted, !calendar.calendars.isEmpty {
                SettingsSection(title: "Calendars to show") {
                    ForEach(Array(calendar.calendars.enumerated()), id: \.element.calendarIdentifier) { index, item in
                        SettingsLine(item.title, item.source.title, last: index == calendar.calendars.count - 1) {
                            SettingsSwitch(isOn: shownBinding(item.calendarIdentifier))
                        }
                    }
                }
            }
        }
    }

    private func shownBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !calendar.hiddenCalendarIDs.contains(id) },
                set: { shown in if shown { calendar.hiddenCalendarIDs.remove(id) } else { calendar.hiddenCalendarIDs.insert(id) } })
    }

    private var googleStatus: String {
        if let email = google.connectedEmail { return "Connected as \(email). Read-only; upcoming meetings appear in Notetaker." }
        if !google.isConfigured { return "Not available in this build. Add your Google account under Internet Accounts and use Mac Calendar below — it shows the same meetings." }
        if let error = google.lastError { return error }
        return "See upcoming meetings, join in one click, and name notes after the event."
    }

    private var calendarStatus: String {
        switch calendar.access {
        case .granted:
            let shown = calendar.calendars.filter { !calendar.hiddenCalendarIDs.contains($0.calendarIdentifier) }.count
            return "iCloud, Google, Outlook and Exchange calendars added to this Mac. Reading \(shown) calendar\(shown == 1 ? "" : "s")."
        case .notDetermined: return "iCloud, Google, Outlook and Exchange calendars added to this Mac."
        case .denied: return "Calendar access is off. Allow Onword in System Settings → Privacy & Security → Calendars."
        }
    }

    // MARK: Data and Privacy

    private var privacy: some View {
        SettingsPage(title: "Data and Privacy",
                     description: "Everything Onword hears and writes stays on this Mac. Nothing is sent to a server.") {
            SettingsSection {
                SettingsLine("Local data storage", "How Onword keeps your dictation history (the text, never audio).") {
                    SettingsSelect(value: HistoryRetention(rawValue: historyRetention)?.title ?? HistoryRetention.keep.title) {
                        ForEach(HistoryRetention.allCases) { option in
                            Button(option.title) {
                                if option == .never { dialog = .confirmNeverStore } else { historyRetention = option.rawValue; History.prune() }
                            }
                        }
                    }
                }
                SettingsLine("Your data", "Dictation history, notes, meetings and downloaded models.", last: true) {
                    Button("Open folder") { dictation.openDataFolder() }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    // MARK: Dialogs

    @ViewBuilder private var dialogView: some View {
        switch dialog {
        case .shortcut:
            SettingsDialog(title: "Shortcut", subtitle: "Hold it to talk. Double-tap it for hands-free; press once more to finish.",
                           close: { dialog = nil }) {
                VStack(spacing: 8) {
                    ForEach(HotkeyMonitor.Key.allCases) { key in
                        DialogOption(title: key.title,
                                     detail: key == .fn && GlobeKey.conflict != nil ? "Your 🌐 key needs “Press 🌐 key to: Do Nothing”" : nil,
                                     selected: dictation.hotkey == key) { dictation.hotkey = key }
                    }
                }
                doneRow
            }
        case .microphone:
            SettingsDialog(title: "Microphone", subtitle: "Used for dictation and Notetaker.", close: { dialog = nil }) {
                ScrollView {
                    VStack(spacing: 8) {
                        DialogOption(title: "Auto-detect", detail: "AirPods or a headset when connected, otherwise the Mac's microphone",
                                     selected: dictation.microphoneUID == nil || dictation.microphoneUID == AudioDevices.automatic) {
                            dictation.microphoneUID = AudioDevices.automatic
                        }
                        DialogOption(title: "System default", detail: AudioDevices.defaultInput?.name,
                                     selected: dictation.microphoneUID == AudioDevices.systemDefault) {
                            dictation.microphoneUID = AudioDevices.systemDefault
                        }
                        ForEach(AudioDevices.inputs()) { device in
                            DialogOption(title: device.name, detail: device.isBluetooth ? "Bluetooth — call-quality audio while recording" : nil,
                                         selected: dictation.microphoneUID == device.uid) { dictation.microphoneUID = device.uid }
                        }
                    }
                }
                .frame(maxHeight: 340)
                doneRow
            }
        case .languages:
            ZStack {
                Theme.scrim.opacity(0.3).onTapGesture { dialog = nil }
                LanguagePicker { dialog = nil }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        case .confirmNeverStore:
            SettingsDialog(title: "Stop storing dictation history?",
                           subtitle: "This deletes your dictation history on this Mac and stops saving new dictations.",
                           close: { dialog = nil }) {
                HStack {
                    Spacer()
                    Button("Cancel") { dialog = nil }.buttonStyle(SecondaryButtonStyle(fullWidth: false))
                    Button("Delete and stop") {
                        historyRetention = HistoryRetention.never.rawValue
                        History.prune()
                        dialog = nil
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        case nil:
            EmptyView()
        }
    }

    private var doneRow: some View {
        HStack {
            Spacer()
            Button("Done") { dialog = nil }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }
}

/// Settings over the Hub: a dimmed backdrop and the 960×640 panel scaling in. Click outside or Esc to close.
struct SettingsOverlay: View {
    @ObservedObject var router: HubRouter

    var body: some View {
        ZStack {
            if let tab = router.settingsTab {
                Theme.scrim.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { router.settingsTab = nil }
                    .transition(.opacity)
                SettingsView(tab: tab)
                    .compositingGroup()   // one shadow for the whole panel, not one per element
                    .shadow(color: .black.opacity(0.1), radius: 25, y: 20)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .id(tab)
            }
        }
        .animation(.spring(duration: 0.15), value: router.settingsTab)
    }
}

extension HubRouter.SettingsTab {
    var title: String {
        switch self {
        case .general: "General"
        case .system: "System"
        case .notetaker: "Notetaker"
        case .connections: "Connections"
        case .privacy: "Data and Privacy"
        }
    }

    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .system: "laptopcomputer"
        case .notetaker: "smallcircle.filled.circle"
        case .connections: "link"
        case .privacy: "checkmark.shield"
        }
    }
}

extension Notification.Name {
    /// The "Show Flow Bar at all times" setting changed.
    static let flowBarSettingChanged = Notification.Name("Onword.flowBarSettingChanged")
}

extension Transcriber.Model {
    var shortTitle: String {
        switch self {
        case .baseEnglish: "Base (English)"
        case .smallEnglish: "Small (English)"
        case .largeTurbo: "Large v3 Turbo"
        case .base: "Base"
        case .small: "Small"
        }
    }
}
