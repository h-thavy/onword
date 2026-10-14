import Foundation
import WhisperKit

/// On-device speech-to-text with WhisperKit. Models download once from Hugging Face, then run offline.
actor Transcriber {
    enum Model: String, CaseIterable, Identifiable {
        case baseEnglish = "base.en"
        case smallEnglish = "small.en"
        case largeTurbo = "large-v3-v20240930_626MB"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .baseEnglish: "Base (English) – fastest, ~150 MB"
            case .smallEnglish: "Small (English) – balanced, ~500 MB"
            case .largeTurbo: "Large v3 Turbo (99 languages) – best, ~630 MB"
            }
        }

        var isEnglishOnly: Bool { rawValue.hasSuffix(".en") }
    }

    enum TranscriberError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "The speech model isn't loaded yet." }
    }

    private var kit: WhisperKit?
    private(set) var loadedModel: Model?

    /// Frees the model's memory (it reloads on the next `load`).
    func unload() {
        kit = nil
        loadedModel = nil
    }

    func load(_ model: Model, downloadBase: URL) async throws {
        if loadedModel == model, kit != nil { return }
        kit = nil
        loadedModel = nil
        let config = WhisperKitConfig(
            model: model.rawValue,
            downloadBase: downloadBase,
            verbose: false,
            prewarm: true,
            load: true,
            download: true
        )
        kit = try await WhisperKit(config)
        loadedModel = model
    }

    /// - Parameters:
    ///   - language: ISO code such as "en", or nil to auto-detect (multilingual models only).
    ///   - prompt: vocabulary hint, e.g. "Anthropic, WhisperKit, Kubernetes".
    func transcribe(_ samples: [Float], language: String?, prompt: String?) async throws -> String {
        guard let kit, let loadedModel else { throw TranscriberError.notLoaded }

        let lang = loadedModel.isEnglishOnly ? "en" : language
        var options = DecodingOptions(
            task: .transcribe,
            language: lang,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: lang == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        if let prompt, let tokenizer = kit.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }

        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Long-form transcription for meetings: keeps segment and word timestamps so speakers can be attached.
    /// Splits on silence (VAD) and decodes chunks in parallel.
    ///
    /// No vocabulary prompt here: in testing, prompt tokens made Whisper merge segments and emit wrong
    /// timestamps (0–19.5 s for a 4.7 s sentence), which breaks speaker alignment. Apply the dictionary's
    /// replacements to the text afterwards instead.
    func transcribeLong(_ samples: [Float], language: String?) async throws -> [TranscriptionResult] {
        guard let kit, let loadedModel else { throw TranscriberError.notLoaded }
        let lang = loadedModel.isEnglishOnly ? "en" : language
        let options = DecodingOptions(
            task: .transcribe,
            language: lang,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: lang == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            concurrentWorkerCount: 4,
            chunkingStrategy: .vad
        )
        return try await kit.transcribe(audioArray: samples, decodeOptions: options)
    }
}
