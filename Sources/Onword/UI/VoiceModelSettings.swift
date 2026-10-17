import SwiftUI

/// Names the local backend and the model actually ready for dictation, separately from a pending choice.
struct VoiceModelSettings: View {
    let choose: () -> Void
    @ObservedObject private var dictation = DictationController.shared

    var body: some View {
        SettingsSection(title: "Local voice model") {
            SettingsLine("WhisperKit · Core ML", "Speech recognition runs on this Mac. Model files download once; audio stays on your Mac.", last: true) {
                Button("Change model", action: choose).buttonStyle(SecondaryButtonStyle())
                    .disabled(dictation.state == .recording || dictation.state == .transcribing)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("\(dictation.modelReady ? "Active" : "Selected"): \(dictation.model.displayName)")
                    .font(Theme.sans(15, .semibold))
                if let failure = dictation.modelFailure {
                    Text(failure).foregroundStyle(.orange)
                    Button("Try again") { dictation.retryModel() }.buttonStyle(SecondaryButtonStyle(fullWidth: false))
                } else if dictation.modelReady {
                    Label("Ready · works offline", systemImage: "checkmark.circle")
                } else {
                    Text(dictation.modelStatus)
                    if let progress = dictation.modelProgress {
                        ProgressView(value: progress).tint(Theme.ink)
                    }
                }
                if let pending = dictation.pendingModel { PendingModelBanner(pending: pending) }
                Text("Live meeting transcripts use your dictation model. Final meeting transcripts use Whisper Large v3 Turbo, with your dictation model as a local fallback.")
                if dictation.selectedLanguages.contains("km") || dictation.language == "km" {
                    Text("Khmer speech uses a separate Whisper Small fine-tune when available (about 500 MB).")
                }
            }
            .font(Theme.sans(13)).foregroundStyle(Theme.inkFaint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct VoiceModelPicker: View {
    let close: () -> Void
    @ObservedObject private var dictation = DictationController.shared

    private var choice: Transcriber.Model { dictation.pendingModel?.model ?? dictation.model }
    private var english: Bool { (dictation.pendingModel?.language ?? dictation.activeLanguage) == "en" }

    var body: some View {
        SettingsDialog(title: "Local voice model", subtitle: "WhisperKit runs Whisper on this Mac using Core ML. Your languages determine whether Base and Small use English-only or multilingual models.", width: 560, close: close) {
            VStack(spacing: 8) {
                ForEach(Transcriber.Model.choices(english: english)) { model in
                    DialogOption(title: model.displayName,
                                 detail: "\(model.tier.title) · \(model.downloadSize) · \(availability(model))",
                                 selected: model == choice) {
                        dictation.chooseTier(model.tier)
                        close()
                    }
                }
            }
            .disabled(dictation.state == .recording || dictation.state == .transcribing)
            Text("Missing models download from Hugging Face when selected. You can keep using the active model during download. Selection is saved on this Mac; downloaded models stay available offline.")
                .font(Theme.sans(13)).foregroundStyle(Theme.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done", action: close).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func availability(_ model: Transcriber.Model) -> String {
        Transcriber.localFolder(for: model, downloadBase: AppPaths.models) == nil ? "Download needed" : "On this Mac"
    }
}
