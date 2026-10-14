import SwiftUI
import WhisperKit

/// Dictation languages: everything Whisper understands.
enum Languages {
    /// ISO codes, sorted by English name, with "auto" (detect) first.
    static let all: [String] = ["auto"] + Set(Constants.languages.values)
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
}

/// A searchable list of languages. Picking one that needs a model not on this Mac yet starts its download;
/// dictation switches once it's ready.
struct LanguagePicker: View {
    @ObservedObject private var dictation = DictationController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var selected: String { dictation.pendingModel?.language ?? dictation.activeLanguage }
    private var tier: Transcriber.Model.Tier { dictation.pendingModel?.model.tier ?? dictation.model.tier }

    private var results: [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Languages.all }
        return Languages.all.filter {
            Languages.name($0).localizedCaseInsensitiveContains(query)
                || (Languages.nativeName($0)?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.hasPrefix(query.lowercased())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Language").font(Theme.serif(26))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 6)
            Text("English uses a fast English-only model. Every other language shares one multilingual model, downloaded once (\(Transcriber.Model.variant(tier, english: false).downloadSize)).")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.inkTertiary)
                TextField("Search languages", text: $search).textFieldStyle(.plain)
            }
            .font(Theme.sans(14))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
            .padding(.horizontal, 24).padding(.vertical, 14)

            if let pending = dictation.pendingModel {
                PendingModelBanner(pending: pending).padding(.horizontal, 24).padding(.bottom, 12)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results, id: \.self) { code in row(code) }
                }
                .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium).strokeBorder(Theme.border))
                .padding(.horizontal, 24).padding(.bottom, 22)
            }
        }
        .frame(width: 520, height: 600)
        .background(Theme.panel)
        .foregroundStyle(Theme.ink)
    }

    private func row(_ code: String) -> some View {
        let model = Transcriber.Model.variant(tier, english: code == "en")
        let onDisk = Transcriber.localFolder(for: model, downloadBase: AppPaths.models) != nil
        return Button { dictation.chooseLanguage(code) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Languages.name(code)).font(Theme.sans(14, .medium))
                    if let native = Languages.nativeName(code) {
                        Text(native).font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
                    } else if code == "auto" {
                        Text("Recognises whichever language you speak").font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                Spacer()
                if !onDisk {
                    Label("Download · \(model.downloadSize)", systemImage: "arrow.down.circle")
                        .font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
                }
                if code == selected {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(code == selected ? Theme.selected : .clear)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.border) }
    }
}

/// "Downloading the Japanese model… 42%", with Cancel, or the error with Try again.
struct PendingModelBanner: View {
    let pending: DictationController.PendingModel
    @ObservedObject private var dictation = DictationController.shared

    var body: some View {
        HStack(spacing: 10) {
            if let failure = pending.failure {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(failure).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Try again") { dictation.retryPendingModel() }.buttonStyle(.pillQuiet)
            } else {
                ProgressView(value: pending.progress).frame(width: 90).tint(Theme.ink)
                Text("Downloading the model for \(Languages.name(pending.language))… \(Int(pending.progress * 100))%")
                    .monospacedDigit()
                Spacer()
            }
            Button("Cancel") { dictation.cancelPendingModel() }.buttonStyle(.plain).foregroundStyle(Theme.inkTertiary)
        }
        .font(Theme.sans(12.5, .medium))
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.selected))
    }
}
