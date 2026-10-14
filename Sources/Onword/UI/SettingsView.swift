import AppKit
import SwiftUI

/// Settings sheet: a section list on the left, rows of
/// "setting · current value · Change" on the right.
struct SettingsView: View {
    @State var tab: HubRouter.SettingsTab
    @ObservedObject private var dictation = DictationController.shared
    @ObservedObject private var detector = MeetingDetector.shared
    @ObservedObject private var calendar = CalendarService.shared
    @ObservedObject private var google = GoogleCalendar.shared
    @Environment(\.dismiss) private var dismiss
    @State private var appearance = Appearance.current

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: "Settings").padding(.leading, 12).padding(.bottom, 6)
                ForEach(HubRouter.SettingsTab.allCases) { item in
                    Button { tab = item } label: {
                        Text(item.title).font(Theme.sans(14, tab == item ? .semibold : .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(tab == item ? Theme.panel : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("Onword \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.inkTertiary).padding(.leading, 12)
            }
            .padding(.horizontal, 10).padding(.vertical, 22)
            .frame(width: 190)
            .background(Theme.frame)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(tab.title).font(Theme.serif(30))
                    Spacer()
                    IconButton(systemImage: "xmark", help: "Close") { dismiss() }
                }
                .padding(.bottom, 18)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch tab {
                        case .general: general
                        case .system: system
                        case .notetaker: notetaker
                        case .connections: connections
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
            .padding(.horizontal, 28).padding(.top, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.panel)
        }
        .frame(width: 780, height: 540)
        .font(Theme.sans(14))
        .foregroundStyle(Theme.ink)
    }

    // MARK: General

    @ViewBuilder
    private var general: some View {
        group("Dictation") {
            SettingsRow(title: "Shortcut", detail: "Hold \(dictation.hotkey.title) and speak. Double-tap for hands-free, Esc cancels.") {
                changeMenu(dictation.hotkey.title) {
                    ForEach(HotkeyMonitor.Key.allCases) { key in Button(key.title) { dictation.hotkey = key } }
                }
            }
            if dictation.hotkey == .fn, let conflict = GlobeKey.conflict {
                SettingsRow(title: "🌐 key conflict", detail: "Your 🌐 key also \(conflict). Set “Press 🌐 key to” → Do Nothing.") {
                    Button("Open Keyboard") { GlobeKey.openKeyboardSettings() }.buttonStyle(.pillQuiet)
                }
            }
            SettingsRow(title: "Microphone", detail: microphoneDetail) {
                changeMenu(microphoneName) {
                    Button("System default (\(AudioDevices.defaultInput?.name ?? "none"))") { dictation.microphoneUID = nil }
                    Divider()
                    ForEach(AudioDevices.inputs()) { device in Button(device.name) { dictation.microphoneUID = device.uid } }
                }
            }
            SettingsRow(title: "Speech model", detail: "Runs on this Mac. Bigger is more accurate but slower to load.") {
                changeMenu(dictation.model.shortTitle) {
                    ForEach(Transcriber.Model.allCases) { model in Button(model.title) { dictation.model = model } }
                }
            }
            SettingsRow(title: "Language", detail: dictation.model.isEnglishOnly ? "English-only model. Choose Large v3 Turbo for 99 languages." : nil, last: true) {
                if dictation.model.isEnglishOnly {
                    Text("English").foregroundStyle(Theme.inkTertiary)
                } else {
                    changeMenu(languageName(dictation.language)) {
                        Button("Auto-detect") { dictation.language = "auto" }
                        Divider()
                        ForEach(Self.languages, id: \.self) { code in Button(languageName(code)) { dictation.language = code } }
                    }
                }
            }
        }
        group("Appearance") {
            SettingsRow(title: "Theme", detail: "Light, Dark, or follow the system.", last: true) {
                changeMenu(appearance.title) {
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
        group("Writing") {
            SettingsRow(title: "Remove filler words", detail: "Drops “um”, “uh”, “hmm”.", last: true) {
                Toggle("", isOn: $dictation.removeFillers).toggleStyle(.switch).labelsHidden().tint(Theme.primary)
            }
        }
    }

    // MARK: System

    @ViewBuilder
    private var system: some View {
        group("Permissions") {
            permissionRow("Microphone", "To hear you.", Permissions.microphone) {
                Task { _ = await Permissions.requestMicrophone() }
            }
            permissionRow("Accessibility", "To read the text field you're in and paste.", Permissions.accessibility) {
                Permissions.requestAccessibility()
            }
            permissionRow("Input Monitoring", "To notice the shortcut in other apps.", Permissions.inputMonitoring, last: true) {
                Permissions.requestInputMonitoring()
            }
        }
        group("Setup") {
            SettingsRow(title: "Run setup again", detail: "Permissions, microphone test, shortcut and a practice dictation.", last: true) {
                Button("Start") {
                    dismiss()
                    WindowManager.shared.showOnboarding()
                }
                .buttonStyle(.pillQuiet)
            }
        }
        group("Data") {
            SettingsRow(title: "Your data", detail: "Dictation history (text only), notes, meetings and models, all on this Mac.", last: true) {
                Button("Open folder") { dictation.openDataFolder() }.buttonStyle(.pillQuiet)
            }
        }
    }

    // MARK: Notetaker

    @ViewBuilder
    private var notetaker: some View {
        group("Meetings") {
            SettingsRow(title: "When a call starts", detail: "Zoom, Teams, FaceTime, Webex, Discord, or Meet / Teams / Slack huddles in a browser.") {
                changeMenu(detector.mode.title) {
                    ForEach(MeetingDetector.Mode.allCases) { mode in Button(mode.title) { detector.mode = mode } }
                }
            }
            SettingsRow(title: "Start or stop recording", detail: "From anywhere.") {
                KeyChip(text: "⌃⌥M")
            }
            SettingsRow(title: "Summaries & action items",
                        detail: MeetingSummarizer.shared.unavailableReason ?? "Written on this Mac by Apple Intelligence.", last: true) {
                Image(systemName: MeetingSummarizer.shared.unavailableReason == nil ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(MeetingSummarizer.shared.unavailableReason == nil ? Theme.ink : Theme.inkTertiary)
            }
        }
        group("Speaker names") {
            SettingsRow(title: "Active-speaker markers", detail: "Class names Onword looks for in Meet, Teams and Slack. Edit if names stop appearing.", last: true) {
                Button("Edit") {
                    let url = AppPaths.root.appendingPathComponent("speaker-markers.json")
                    if !FileManager.default.fileExists(atPath: url.path) {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try? encoder.encode(ActiveSpeakerPoller.defaultMarkers).write(to: url)
                    }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.pillQuiet)
            }
        }
    }

    // MARK: Connections

    @ViewBuilder
    private var connections: some View {
        group("Calendar") {
            SettingsRow(title: "Google Calendar", detail: googleStatus) {
                if google.isConnected {
                    Button("Disconnect") { google.disconnect() }.buttonStyle(.pillQuiet)
                } else {
                    Button(google.isConnecting ? "Waiting for Google…" : "Connect") { google.connect() }
                        .buttonStyle(.pill).disabled(!google.isConfigured || google.isConnecting)
                }
            }
            SettingsRow(title: "Mac Calendar (iCloud, Outlook, Exchange)",
                        detail: google.isConnected ? "Not used while Google Calendar is connected." : calendarStatus) {
                switch calendar.access {
                case .granted:
                    Label("Allowed", systemImage: "checkmark.circle.fill").font(Theme.sans(13)).foregroundStyle(Theme.inkTertiary)
                case .notDetermined:
                    Button("Use") { calendar.requestAccess() }.buttonStyle(.pillQuiet)
                case .denied:
                    Button("Allow…") { CalendarService.openPrivacySettings() }.buttonStyle(.pillQuiet)
                }
            }
            SettingsRow(title: "Remind me when a meeting starts", detail: "Offers to join the call and take notes.", last: true) {
                Toggle("", isOn: $calendar.remindersEnabled).toggleStyle(.switch).labelsHidden().tint(Theme.primary)
            }
        }
        if google.isConnected, !calendar.googleCalendars.isEmpty {
            group("Calendars to show") {
                ForEach(Array(calendar.googleCalendars.enumerated()), id: \.element.id) { index, item in
                    SettingsRow(title: item.summary ?? item.id, detail: item.primary == true ? "Primary" : nil,
                                last: index == calendar.googleCalendars.count - 1) {
                        Toggle("", isOn: Binding(
                            get: { !calendar.hiddenCalendarIDs.contains(item.id) },
                            set: { shown in
                                if shown { calendar.hiddenCalendarIDs.remove(item.id) } else { calendar.hiddenCalendarIDs.insert(item.id) }
                            }))
                        .toggleStyle(.switch).labelsHidden().tint(Theme.primary)
                    }
                }
            }
        } else if calendar.access == .granted, !calendar.calendars.isEmpty {
            group("Calendars to show") {
                ForEach(Array(calendar.calendars.enumerated()), id: \.element.calendarIdentifier) { index, item in
                    SettingsRow(title: item.title, detail: item.source.title, last: index == calendar.calendars.count - 1) {
                        Toggle("", isOn: Binding(
                            get: { !calendar.hiddenCalendarIDs.contains(item.calendarIdentifier) },
                            set: { shown in
                                if shown { calendar.hiddenCalendarIDs.remove(item.calendarIdentifier) }
                                else { calendar.hiddenCalendarIDs.insert(item.calendarIdentifier) }
                            }))
                        .toggleStyle(.switch).labelsHidden().tint(Color(nsColor: item.color))
                    }
                }
            }
        }
    }

    private var googleStatus: String {
        if let email = google.connectedEmail { return "Connected as \(email). Read-only; upcoming meetings appear in Notetaker." }
        if !google.isConfigured { return "Not available in this build (no Google sign-in configured)." }
        if let error = google.lastError { return error }
        return "Sign in with Google to see upcoming meetings, join in one click, and name notes after the event."
    }

    private var calendarStatus: String {
        switch calendar.access {
        case .granted:
            let shown = calendar.calendars.filter { !calendar.hiddenCalendarIDs.contains($0.calendarIdentifier) }.count
            return "Reading \(shown) calendar\(shown == 1 ? "" : "s"). Upcoming meetings appear in Notetaker."
        case .notDetermined: return "See upcoming meetings, join in one click, and name notes after the event."
        case .denied: return "Calendar access is off. Allow Onword in System Settings → Privacy & Security → Calendars."
        }
    }

    // MARK: Helpers

    private func group(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        let content = rows()
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title)
            SettingsCard { content }
        }
    }

    /// "Current value · Change" control.
    private func changeMenu(_ value: String, @ViewBuilder items: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(value).font(Theme.sans(13)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            Menu { items() } label: { Text("Change").font(Theme.sans(13, .semibold)) }
                .menuStyle(.button)
                .buttonStyle(.pillQuiet)
                .menuIndicator(.hidden)
                .fixedSize()
        }
    }

    private func permissionRow(_ name: String, _ why: String, _ granted: Bool, last: Bool = false,
                               request: @escaping () -> Void) -> some View {
        SettingsRow(title: name, detail: why, last: last) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").font(Theme.sans(13)).foregroundStyle(Theme.inkTertiary)
            } else {
                Button("Allow…", action: request).buttonStyle(.pill)
            }
        }
    }

    private var microphoneName: String {
        dictation.microphoneUID.flatMap { AudioDevices.device(uid: $0)?.name } ?? "System default"
    }

    private var microphoneDetail: String {
        let active = dictation.microphoneUID.flatMap { AudioDevices.device(uid: $0) } ?? AudioDevices.defaultInput
        if active?.isBluetooth == true {
            return "Bluetooth mics like AirPods switch to call-quality audio when recording and can miss the first second. The built-in mic is more reliable."
        }
        return "Used for dictation and Notetaker."
    }

    static let languages = ["en", "km", "th", "vi", "zh", "ja", "ko", "fr", "de", "es", "it", "pt"]

    private func languageName(_ code: String) -> String {
        code == "auto" ? "Auto-detect" : (Locale.current.localizedString(forLanguageCode: code) ?? code)
    }
}

extension Transcriber.Model {
    var shortTitle: String {
        switch self {
        case .baseEnglish: "Base (English)"
        case .smallEnglish: "Small (English)"
        case .largeTurbo: "Large v3 Turbo"
        }
    }
}
