import SwiftUI
import WhisperKit

/// Dictation languages: everything Whisper understands.
enum Languages {
    /// ISO codes sorted by English name.
    static let all: [String] = Set(Constants.languages.values)
        .sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }

    /// "Japanese", or "Auto-detect".
    static func name(_ code: String) -> String {
        if code == "auto" { return "Auto-detect" }
        return Locale(identifier: "en").localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    /// The language's own name ("日本語"), when it differs from the English one.
    static func nativeName(_ code: String) -> String? {
        guard code != "auto", let native = Locale(identifier: code).localizedString(forLanguageCode: code),
              native.lowercased() != name(code).lowercased() else { return nil }
        return native
    }

    /// "English", "English · Japanese", or "English, Japanese and 3 more"; empty = auto-detect.
    static func summary(_ codes: [String]) -> String {
        if codes.isEmpty { return "Auto-detect (\(all.count) languages)" }
        let names = codes.map(name)
        if names.count <= 3 { return names.joined(separator: " · ") }
        return "\(names[0]), \(names[1]) and \(names.count - 2) more"
    }

    /// Languages this Mac is set up for (e.g. "km" for Khmer), shown near the top of the picker.
    static var preferred: [String] {
        Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
            .filter { Constants.languages.values.contains($0) }
    }
}

/// "Dictation languages": a searchable 3-column grid of languages with a "Selected" column, and an
/// Auto-detect switch. One language → Onword dictates in it; several (or Auto-detect) → it detects which
/// one you're speaking. Languages other than English need the multilingual model, downloaded once.
struct LanguagePicker: View {
    let close: () -> Void
    @ObservedObject private var dictation = DictationController.shared
    @State private var selection: [String] = DictationController.shared.selectedLanguages
    @State private var autoDetect = DictationController.shared.selectedLanguages.isEmpty
    @State private var remembered: [String] = []
    @State private var search = ""
    @State private var order: [String] = []
    @State private var showEmptyError = false

    private var results: [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return order }
        func matches(_ code: String, prefix: Bool) -> Bool {
            let names = [Languages.name(code), Languages.nativeName(code) ?? ""]
            return names.contains { prefix ? $0.lowercased().hasPrefix(query.lowercased())
                                           : $0.localizedCaseInsensitiveContains(query) }
        }
        let starts = order.filter { matches($0, prefix: true) }
        return starts + order.filter { !starts.contains($0) && matches($0, prefix: false) }
    }

    /// Whether saving would need the multilingual model, which isn't on this Mac yet.
    private var needsDownload: Bool {
        let english = !autoDetect && selection == ["en"]
        let model = Transcriber.Model.variant(dictation.model.tier, english: english)
        return Transcriber.localFolder(for: model, downloadBase: AppPaths.models) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dictation languages").font(Theme.sans(18, .semibold))
                    Text("Choose the languages you dictate in. With more than one, Onword detects which you’re speaking.")
                        .font(Theme.sans(16)).foregroundStyle(Theme.inkMuted)
                        .frame(maxWidth: 560, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                HStack(spacing: 8) {
                    Text("Auto-detect").font(Theme.sans(12, .semibold))
                    SettingsSwitch(isOn: Binding(get: { autoDetect }, set: setAutoDetect))
                }
            }

            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.inkTertiary)
                            .frame(width: 20)
                        if autoDetect {
                            Text("Auto-detect is on. Onword detects the language you’re speaking.")
                                .font(Theme.sans(15)).foregroundStyle(Theme.inkTertiary)
                            Spacer()
                        } else {
                            TextField("Search for any language", text: $search).textFieldStyle(.plain).font(Theme.sans(15))
                        }
                    }
                    .padding(12)
                    Rectangle().fill(Theme.border).frame(height: 1)
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                            ForEach(results, id: \.self) { tile($0) }
                        }
                        .padding(12)
                    }
                    .scrollIndicators(.hidden)
                }
                .frame(width: 560, height: 413)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Selected").font(Theme.sans(15, .semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if autoDetect {
                                Label("\(Languages.all.count) languages", systemImage: "globe")
                                    .font(Theme.sans(12)).foregroundStyle(Theme.inkMuted).padding(4)
                            } else {
                                ForEach(selection, id: \.self) { code in
                                    HStack {
                                        Text(Languages.name(code)).font(Theme.sans(12)).foregroundStyle(Theme.inkMuted)
                                        Spacer()
                                        Button { toggle(code) } label: {
                                            Image(systemName: "minus").font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(Theme.inkTertiary).frame(width: 24, height: 24)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plainPointer).help("Remove")
                                    }
                                    .padding(.leading, 4)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    Spacer(minLength: 0)
                    if showEmptyError {
                        Text("Select at least one language or turn on Auto-detect.")
                            .font(Theme.sans(12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    } else if needsDownload {
                        Text("Needs a one-time download (\(Transcriber.Model.variant(dictation.model.tier, english: false).downloadSize)). You can keep dictating meanwhile.")
                            .font(Theme.sans(12)).foregroundStyle(Theme.inkFaint).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        Button("Save and close", action: save).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    }
                }
                .frame(width: 224, height: 413)
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .compositingGroup()   // one shadow for the whole panel, not one per element
        .shadow(color: .black.opacity(0.25), radius: 25, y: 12)
        .onAppear(perform: makeOrder)
    }

    private func tile(_ code: String) -> some View {
        let isSelected = !autoDetect && selection.contains(code)
        return Button { toggle(code) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(Languages.name(code)).font(Theme.sans(15, .semibold)).foregroundStyle(Theme.inkMuted).lineLimit(1)
                Text(Languages.nativeName(code) ?? " ").font(Theme.sans(12)).foregroundStyle(Theme.inkFaint).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Theme.tileSelected : Theme.frame))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Theme.tileRing : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .disabled(autoDetect)
        .opacity(autoDetect ? 0.5 : 1)
    }

    /// Selected first, then this Mac's languages and common ones, then the rest alphabetically.
    private func makeOrder() {
        var seen = Set<String>()
        order = (selection + Languages.preferred + ["en", "es", "zh", "ja"] + Languages.all).filter { seen.insert($0).inserted }
    }

    private func toggle(_ code: String) {
        showEmptyError = false
        if let index = selection.firstIndex(of: code) { selection.remove(at: index) } else { selection.append(code) }
    }

    private func setAutoDetect(_ on: Bool) {
        showEmptyError = false
        autoDetect = on
        if on { remembered = selection } else if selection.isEmpty { selection = remembered }
    }

    private func save() {
        if !autoDetect, selection.isEmpty { showEmptyError = true; return }
        dictation.chooseLanguages(autoDetect ? [] : selection)
        close()
    }
}

/// "Downloading the model for Japanese… 42%", with Cancel, or the error with Try again.
struct PendingModelBanner: View {
    let pending: DictationController.PendingModel
    @ObservedObject private var dictation = DictationController.shared

    var body: some View {
        HStack(spacing: 10) {
            if let failure = pending.failure {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(failure).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Try again") { dictation.retryPendingModel() }.buttonStyle(SecondaryButtonStyle(fullWidth: false))
            } else {
                ProgressView(value: pending.progress).frame(width: 90).tint(Theme.ink)
                Text("Downloading the model for \(Languages.name(pending.language))… \(Int(pending.progress * 100))%")
                    .monospacedDigit()
                Spacer()
            }
            Button("Cancel") { dictation.cancelPendingModel() }.buttonStyle(.plainPointer).foregroundStyle(Theme.inkTertiary)
        }
        .font(Theme.sans(13, .medium))
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
    }
}
