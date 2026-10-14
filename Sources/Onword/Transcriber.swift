import Foundation
import os
import WhisperKit

/// On-device speech-to-text with WhisperKit. Models download once from Hugging Face, then run offline.
actor Transcriber {
    enum Model: String, CaseIterable, Identifiable {
        case baseEnglish = "base.en"
        case smallEnglish = "small.en"
        case largeTurbo = "large-v3-v20240930_626MB"
        case base = "base"     // multilingual
        case small = "small"   // multilingual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .baseEnglish: "Base (English) – fastest, ~150 MB"
            case .smallEnglish: "Small (English) – balanced, ~500 MB"
            case .largeTurbo: "Large v3 Turbo (99 languages) – best, ~630 MB"
            case .base: "Base (99 languages) – fastest, ~150 MB"
            case .small: "Small (99 languages) – balanced, ~500 MB"
            }
        }

        /// Speed/accuracy choice shown in Settings; the language decides which model of that size is used.
        enum Tier: String, CaseIterable, Identifiable {
            case fast, balanced, best
            var id: String { rawValue }
            var title: String {
                switch self {
                case .fast: "Fast"
                case .balanced: "Balanced"
                case .best: "Most accurate"
                }
            }
            var detail: String {
                switch self {
                case .fast: "Quickest, a little less accurate"
                case .balanced: "Recommended"
                case .best: "Slower to load, needs more memory"
                }
            }
        }

        var tier: Tier {
            switch self {
            case .baseEnglish, .base: .fast
            case .smallEnglish, .small: .balanced
            case .largeTurbo: .best
            }
        }

        /// The model for a size and language: English gets the English-only model (faster and more accurate
        /// for English); every other language shares one multilingual model of that size.
        static func variant(_ tier: Tier, english: Bool) -> Model {
            switch tier {
            case .fast: english ? .baseEnglish : .base
            case .balanced: english ? .smallEnglish : .small
            case .best: .largeTurbo
            }
        }

        var isEnglishOnly: Bool { rawValue.hasSuffix(".en") }

        var downloadSize: String {
            switch self {
            case .baseEnglish, .base: "about 150 MB"
            case .smallEnglish, .small: "about 500 MB"
            case .largeTurbo: "about 630 MB"
            }
        }

        /// Free space needed to download and compile the model, with headroom.
        var bytesNeeded: Int64 {
            switch self {
            case .baseEnglish, .base: 400_000_000
            case .smallEnglish, .small: 1_000_000_000
            case .largeTurbo: 1_400_000_000
            }
        }
    }

    enum TranscriberError: LocalizedError {
        case notLoaded
        case notEnoughSpace(needed: Int64)
        var errorDescription: String? {
            switch self {
            case .notLoaded: "The speech model isn't loaded yet."
            case .notEnoughSpace(let needed):
                "Not enough disk space. Free up about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) and try again."
            }
        }
    }

    static let repo = "argmaxinc/whisperkit-coreml"
    /// Test hook: ONWORD_TEST_HF_ENDPOINT points downloads at another server (e.g. an unreachable one).
    private static let endpoint = ProcessInfo.processInfo.environment["ONWORD_TEST_HF_ENDPOINT"] ?? "https://huggingface.co"
    private static let modelFiles = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]

    /// The model's folder if it's already fully downloaded.
    static func localFolder(for model: Model, downloadBase: URL) -> URL? {
        let repoFolder = downloadBase.appending(path: "models").appending(path: repo)
        let folders = (try? FileManager.default.contentsOfDirectory(at: repoFolder, includingPropertiesForKeys: nil)) ?? []
        return folders.first { folder in
            folder.lastPathComponent.hasSuffix("-" + model.rawValue) && modelFiles.allSatisfy {
                FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
            }
        }
    }

    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "dictation")
    private var kit: WhisperKit?
    private(set) var loadedModel: Model?

    /// Frees the model's memory (it reloads on the next `load`).
    func unload() {
        kit = nil
        loadedModel = nil
    }

    /// Loads the model, downloading it first only if it isn't on disk yet, so an already-downloaded model
    /// loads offline. A model that's on disk but won't load (a damaged download) is deleted and fetched again.
    /// `progress` reports the download, 0…1.
    func load(_ model: Model, downloadBase: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if loadedModel == model, kit != nil { return }
        kit = nil
        loadedModel = nil

        if let folder = Self.localFolder(for: model, downloadBase: downloadBase) {
            do {
                kit = try await WhisperKit(config(model, folder: folder, downloadBase: downloadBase))
                loadedModel = model
                return
            } catch {
                log.error("Model on disk didn't load (\(error.localizedDescription, privacy: .public)); downloading it again")
                try? FileManager.default.removeItem(at: folder)
            }
        }

        let folder = try await Self.download(model, downloadBase: downloadBase, progress: progress)
        do {
            kit = try await WhisperKit(config(model, folder: folder, downloadBase: downloadBase))
            loadedModel = model
        } catch {
            try? FileManager.default.removeItem(at: folder)   // so the next attempt starts clean
            throw error
        }
    }

    /// Downloads a model without loading it (e.g. a language's model while dictation keeps using another).
    static func download(_ model: Model, downloadBase: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if let folder = localFolder(for: model, downloadBase: downloadBase) { return folder }
        try checkFreeSpace(model.bytesNeeded, at: downloadBase)
        let folder = try await WhisperKit.download(
            variant: model.rawValue, downloadBase: downloadBase, from: repo, endpoint: endpoint
        ) { fraction in progress?(fraction.fractionCompleted) }
        guard localFolder(for: model, downloadBase: downloadBase) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return folder
    }

    private func config(_ model: Model, folder: URL, downloadBase: URL) -> WhisperKitConfig {
        WhisperKitConfig(model: model.rawValue, downloadBase: downloadBase, modelFolder: folder.path,
                         verbose: false, prewarm: true, load: true, download: false)
    }

    private static func checkFreeSpace(_ needed: Int64, at url: URL) throws {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available < needed {
            throw TranscriberError.notEnoughSpace(needed: needed)
        }
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
    /// Whisper's own 30-second windows in order (each window continues from the last), not silence-split
    /// chunks: in testing, a quiet chunk with speech in it could come back empty, losing whole sentences.
    ///
    /// No vocabulary prompt: in testing it made Whisper drop and garble whole passages (word errors went from
    /// about 9% to over 50%). Names are corrected afterwards instead (`NameCorrector`).
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
            chunkingStrategy: ChunkingStrategy.none
        )
        return try await kit.transcribe(audioArray: samples, decodeOptions: options)
    }
}
