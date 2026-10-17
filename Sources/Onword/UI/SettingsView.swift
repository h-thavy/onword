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
    @AppStorage("notetakerOpenNotepad") private var openNotepad = true
    @AppStorage("notetakerStopWhenCallEnds") private var stopWhenCallEnds = true
    @AppStorage("notetakerSkipMicWhenMuted") private var skipMicWhenMuted = true
    @AppStorage("notetakerMaxLength") private var maxLength = 120
    @AppStorage("notetakerReminderLead") private var reminderLead = 15
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showInDock = DockIcon.isShown
    @State private var userName = UserProfile.name ?? ""
    @AppStorage("showFlowBar") private var showFlowBar = true
    @AppStorage("scratchpadOpenBehavior") private var scratchpadOpenBehavior = "resume"
    @AppStorage(HistoryRetention.key) private var historyRetention = HistoryRetention.keep.rawValue

    enum Dialog: Identifiable {
        case shortcut, microphone, languages, voiceModel, confirmNeverStore
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
            switch ProcessInfo.processInfo.environment["ONWORD_TEST_SETTINGS"] {
            case "languages"?: DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { dialog = .languages }
            case "microphone"?: DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { dialog = .microphone }
            default: break
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
            // One click: download, verify, replace the app and relaunch.
            Button { updates.update() } label: {
                Label("Update", systemImage: "arrow.down.circle.fill")
                    .font(Theme.sans(12, .semibold)).foregroundStyle(Theme.onPrimary)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(Capsule().fill(Theme.tileRing))
            }
            .buttonStyle(.plainPointer).help("Update to Onword \(version) and relaunch")
        case .downloading(_, let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress).frame(width: 44).tint(Theme.tileRing)
                Text("\(Int(progress * 100))%").monospacedDigit()
            }
            .help("Downloading the update…")
        case .installing:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Installing…") }
        case .failed(let message):
            Button { updates.check() } label: {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(.orange)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plainPointer).help("\(message) Click to try again.")
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
            VoiceModelSettings { dialog = .voiceModel }
            SettingsSection {
                SettingsLine("Your name", "Used in greetings and for you in meeting notes.") {
                    TextField("Name", text: $userName)
                        .textFieldStyle(.plain).font(Theme.sans(15))
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                        .onChange(of: userName) { _, value in UserProfile.name = value }
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
                SettingsLine("Remove filler words", "Drops “um”, “uh” and “hmm” from dictation.") {
                    SettingsSwitch(isOn: $dictation.removeFillers)
                }
                SettingsLine("Theme", last: true) {
                    SettingsSelect(value: appearance.title,
                                   options: Appearance.allCases.map { option in
                                       SelectOption(id: option.rawValue, title: option.title,
                                                    icon: option == .light ? "sun.max" : option == .dark ? "moon" : "desktopcomputer") {
                                           appearance = option
                                           Appearance.current = option
                                           WindowManager.shared.applyAppearance()
                                       }
                                   },
                                   selectedID: appearance.rawValue, style: .menu)
                }
            }
            if dictation.hotkey == .fn, let conflict = GlobeKey.conflict {
                SettingsSection {
                    SettingsLine("🌐 key conflict", "Your 🌐 key also \(conflict). Set “Press 🌐 key to” → Do Nothing.", last: true) {
                        Button("Open Keyboard") { GlobeKey.openKeyboardSettings() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
    }

    private var microphoneDescription: String { MicrophoneChoice.summary(dictation.microphoneUID) }

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
                    Task { _ = await Permissions.requestMicrophone(from: .settings) }
                }
                permissionLine("Accessibility", "To read the text field you're in and paste.", Permissions.accessibility) {
                    Permissions.requestAccessibility(from: .settings)
                }
                permissionLine("Input Monitoring", "To notice the shortcut in other apps.", Permissions.inputMonitoring, last: true) {
                    Permissions.requestInputMonitoring(from: .settings)
                }
            }
            SettingsSection(title: "Scratchpad") {
                SettingsLine("Scratchpad open behavior", "What ⌃⌥S shows when you open the Scratchpad.", last: true) {
                    SettingsSelect(value: scratchpadOpenBehavior == "newTab" ? "Open in new tab" : "Resume last note",
                                   options: [SelectOption(id: "resume", title: "Resume last note") { scratchpadOpenBehavior = "resume" },
                                             SelectOption(id: "newTab", title: "Open in new tab") { scratchpadOpenBehavior = "newTab" }],
                                   selectedID: scratchpadOpenBehavior == "newTab" ? "newTab" : "resume")
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
                    SettingsSelect(value: calendar.remindersEnabled
                                   ? (NotetakerSettings.reminderLeadOptions.first { $0.seconds == reminderLead }?.title ?? "Right before") : "Never",
                                   options: NotetakerSettings.reminderLeadOptions.map { option in
                                       SelectOption(id: "\(option.seconds)", title: option.title) {
                                           reminderLead = option.seconds
                                           calendar.remindersEnabled = option.seconds >= 0
                                       }
                                   },
                                   selectedID: calendar.remindersEnabled ? "\(reminderLead)" : "-1", style: .menu, menuWidth: 280)
                }
                SettingsLine("Automatically detect any call", "Zoom, Teams, FaceTime, Webex, Discord, or Meet / Teams / Slack huddles in a browser.") {
                    SettingsSelect(value: detector.mode.title,
                                   options: MeetingDetector.Mode.allCases.map { mode in
                                       SelectOption(id: mode.rawValue, title: mode.title) { detector.mode = mode }
                                   },
                                   selectedID: detector.mode.rawValue, style: .menu)
                }
                SettingsLine("Start or stop Notetaker", "From any app.", last: true) {
                    KeyChip(text: "⌥M")
                }
            }
            SettingsSection(title: "Recording") {
                SettingsLine("Open Notepad when starting Notetaker", "Shows your notes, the live transcript and Ask anything.") {
                    SettingsSwitch(isOn: $openNotepad)
                }
                SettingsLine("Stop Notetaker when a call ends", "Counts down first, so you can keep going.") {
                    SettingsSwitch(isOn: $stopWhenCallEnds)
                }
                SettingsLine("Don't record me while I'm muted", "When Zoom, Google Meet or Teams shows you muted, your mic is left out of the notes.") {
                    SettingsSwitch(isOn: $skipMicWhenMuted)
                }
                SettingsLine("Maximum meeting length", "Notetaker checks in 5 minutes before it stops.", last: true) {
                    SettingsSelect(value: NotetakerSettings.title(forMinutes: maxLength),
                                   options: NotetakerSettings.maxLengthOptions.map { minutes in
                                       SelectOption(id: "\(minutes)", title: NotetakerSettings.title(forMinutes: minutes)) { maxLength = minutes }
                                   },
                                   selectedID: "\(maxLength)")
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
                        if google.isConnecting {
                            GoogleSignInWaiting(google: google)
                        } else {
                            Button("Connect") { google.connect() }
                                .buttonStyle(SecondaryButtonStyle()).disabled(!google.isConfigured)
                        }
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
        if google.isConnecting {
            let browser = google.openedIn.map { " in \($0)" } ?? ""
            return "Sign in to Google\(browser) to finish. Don't see it? It may be on another screen: Open again. Is your Google account in a different browser? Copy the link and paste it there."
        }
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
                    SettingsSelect(value: HistoryRetention(rawValue: historyRetention)?.title ?? HistoryRetention.keep.title,
                                   options: HistoryRetention.allCases.map { option in
                                       SelectOption(id: "\(option.rawValue)", title: option.title) {
                                           if option == .never { dialog = .confirmNeverStore } else { historyRetention = option.rawValue; History.prune() }
                                       }
                                   },
                                   selectedID: "\(historyRetention)", menuWidth: 300)
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
            MicrophoneDialog { dialog = nil }
        case .languages:
            ZStack {
                Theme.scrim.opacity(0.3).onTapGesture { dialog = nil }
                LanguagePicker { dialog = nil }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        case .voiceModel:
            VoiceModelPicker { dialog = nil }
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

/// While Google sign-in waits: copy the sign-in link (for a browser other than the default, where your
/// account is), open it again in the default browser (it can open out of sight), or cancel.
private struct GoogleSignInWaiting: View {
    @ObservedObject var google: GoogleCalendar
    @State private var copied = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button {
                google.copySignInLink()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link")
            }
            .buttonStyle(SecondaryButtonStyle())
            HStack(spacing: 14) {
                Button("Open again") { google.openSignIn() }
                Button("Cancel") { google.cancelSignIn() }
            }
            .buttonStyle(.plainPointer)
            .font(Theme.sans(13, .medium)).foregroundStyle(Theme.inkMuted)
        }
    }
}
