import Foundation
import OnwordCore
import os
import WhisperKit
import CoreML

/// On-device speech-to-text with WhisperKit. Models download once from Hugging Face, then run offline.
actor Transcriber {
    typealias Model = SpeechModel

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

    /// Where the Khmer model is published (a zip of the WhisperKit folder), and where it's kept.
    /// Test hook: ONWORD_KHMER_MODEL_URL (may be a file:// URL).
    static let khmerURL = URL(string: ProcessInfo.processInfo.environment["ONWORD_KHMER_MODEL_URL"]
        ?? "https://github.com/h-thavy/onword/releases/download/khmer-model-1/kasekor-khmer-small.zip")!
    private static func khmerFolder(_ downloadBase: URL) -> URL {
        downloadBase.appending(path: "models").appending(path: "onword").appending(path: Model.khmer.rawValue)
    }

    /// The model's folder if it's already fully downloaded.
    static func localFolder(for model: Model, downloadBase: URL) -> URL? {
        if model == .khmer {
            let folder = khmerFolder(downloadBase)
            return modelFiles.allSatisfy { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) } ? folder : nil
        }
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
        // One load at a time across every Transcriber (dictation, meetings, Khmer): two loading the same model
        // at once can fail, which would look like a damaged download.
        await ModelLoadQueue.shared.acquire()
        do {
            try await loadNow(model, downloadBase: downloadBase, progress: progress)
            await ModelLoadQueue.shared.release()
        } catch {
            await ModelLoadQueue.shared.release()
            throw error
        }
    }

    private func loadNow(_ model: Model, downloadBase: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        if loadedModel == model, kit != nil { return }
        kit = nil
        loadedModel = nil

        if let folder = Self.localFolder(for: model, downloadBase: downloadBase) {
            // Tried twice before it's treated as damaged and downloaded again.
            for attempt in 1...2 {
                do {
                    kit = try await WhisperKit(config(model, folder: folder, downloadBase: downloadBase))
                    loadedModel = model
                    return
                } catch {
                    log.error("Model on disk didn't load, attempt \(attempt) (\(error.localizedDescription, privacy: .public))")
                    if attempt == 1 { try? await Task.sleep(for: .seconds(2)) }
                }
            }
            log.error("Downloading \(model.rawValue, privacy: .public) again")
            try? FileManager.default.removeItem(at: folder)
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
        if model == .khmer { return try await downloadKhmer(downloadBase: downloadBase) }
        let folder = try await WhisperKit.download(
            variant: model.rawValue, downloadBase: downloadBase, from: repo, endpoint: endpoint
        ) { fraction in progress?(fraction.fractionCompleted) }
        guard localFolder(for: model, downloadBase: downloadBase) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return folder
    }

    /// Downloads the Khmer model's zip and unpacks it (the zip holds the model files at its top level).
    private static func downloadKhmer(downloadBase: URL) async throws -> URL {
        let fm = FileManager.default
        let folder = khmerFolder(downloadBase)
        let zip: URL
        if khmerURL.isFileURL {
            zip = khmerURL
        } else {
            let (temp, response) = try await URLSession.shared.download(from: khmerURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            zip = temp
        }
        defer { if !khmerURL.isFileURL { try? fm.removeItem(at: zip) } }
        let unpacking = folder.deletingLastPathComponent().appending(path: "unpacking-" + Model.khmer.rawValue)
        try? fm.removeItem(at: unpacking)
        try fm.createDirectory(at: unpacking, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacking.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0, modelFiles.allSatisfy({ fm.fileExists(atPath: unpacking.appending(path: $0).path) }) else {
            try? fm.removeItem(at: unpacking)
            throw CocoaError(.fileReadCorruptFile)
        }
        try? fm.removeItem(at: folder)
        try fm.moveItem(at: unpacking, to: folder)
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
        return TranscriptMerger.tidySpacing(results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Long-form transcription for meetings: keeps segment and word timestamps so speakers can be attached.
    /// Splits on silence (VAD) and decodes chunks in parallel.
    ///
    /// Which of `languages` is spoken: Whisper's language probabilities, limited to the ones you picked
    /// (otherwise it chooses from all 99, and Khmer audio can come out as another script). Looks at up to
    /// `windows` 30-second stretches spread over the audio. Nil when there's nothing to choose.
    func detectLanguage(_ samples: [Float], among languages: [String], windows: Int = 1) async -> String? {
        guard languages.count >= 2, let kit, let loadedModel, !loadedModel.isEnglishOnly, !samples.isEmpty else { return nil }
        // Speech only: silence between turns pulls Whisper toward English.
        let spans = SpeechSpans.find(samples)
        let speech = spans.isEmpty ? samples : spans.flatMap { samples[$0] }
        let window = 16_000 * 30
        let samples = speech
        let count = max(1, min(windows, samples.count / window))
        var scores: [String: Double] = [:]
        for i in 0..<count {
            let start = count == 1 ? 0 : (samples.count - window) * i / max(1, count - 1)
            let slice = Array(samples[max(0, start)..<min(samples.count, start + window)])
            guard let probs = try? await languageProbabilities(kit, slice, languages) else { continue }
            for (code, p) in probs { scores[code, default: 0] += p }
        }
        log.debug("Language scores: \(languages.map { "\($0) \(String(format: "%.4f", scores[$0] ?? 0))" }.joined(separator: ", "), privacy: .public)")
        guard !scores.isEmpty else { return nil }
        let windowsRead = Double(count)
        guard let best = languages.max(by: { (scores[$0] ?? 0) < (scores[$1] ?? 0) }) else { return nil }
        // Sure about one of yours, or else the one of yours Whisper can't recognize.
        if (scores[best] ?? 0) / windowsRead >= 0.5 { return best }
        return languages.first { Self.poorlyRecognized.contains($0) } ?? best
    }

    /// Whisper's first-step scores for just these languages, as probabilities that add up to 1. WhisperKit's
    /// own detection keeps only its top guess, which for Khmer is often a third language.
    private func languageProbabilities(_ kit: WhisperKit, _ slice: [Float], _ languages: [String]) async throws -> [String: Double] {
        guard let tokenizer = kit.tokenizer,
              let audio = kit.audioProcessor.padOrTrim(fromArray: slice, startAt: 0,
                                                       toLength: kit.featureExtractor.windowSamples ?? Constants.defaultWindowSamples),
              let mel = try await kit.featureExtractor.logMelSpectrogram(fromAudio: audio),
              let encoded = try await kit.audioEncoder.encodeFeatures(mel) as? MLMultiArray,
              let inputs = try kit.textDecoder.prepareDecoderInputs(withPrompt: [tokenizer.specialTokens.startOfTranscriptToken]) as? DecodingInputs
        else { return [:] }
        let output = try await kit.textDecoder.predictLogits(TextDecoderMLMultiArrayInputType(
            inputIds: inputs.inputIds, cacheLength: inputs.cacheLength, keyCache: inputs.keyCache, valueCache: inputs.valueCache,
            kvCacheUpdateMask: inputs.kvCacheUpdateMask, encoderOutputEmbeds: encoded,
            decoderKeyPaddingMask: inputs.decoderKeyPaddingMask)) as? TextDecoderMLMultiArrayOutputType
        guard let logits = output?.logits else { return [:] }
        var all: [String: Double] = [:]
        for code in Constants.languageCodes {
            if let id = tokenizer.convertTokenToId("<|\(code)|>"), id < logits.count { all[code] = logits[id].doubleValue }
        }
        guard let top = all.values.max() else { return [:] }
        let total = all.values.reduce(0) { $0 + exp($1 - top) }
        if ProcessInfo.processInfo.environment["ONWORD_DEBUG_LID"] != nil {
            log.notice("LID top: \(all.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \(String(format: "%.3f", exp($0.value - top) / total))" }.joined(separator: ", "), privacy: .public)")
        }
        return Dictionary(uniqueKeysWithValues: languages.compactMap { code in all[code].map { (code, exp($0 - top) / total) } })
    }

    /// Languages Whisper hardly recognizes: on Khmer speech its top guess was Thai, Vietnamese or Welsh, and
    /// Khmer itself scored under 1%. When Whisper isn't sure about any of your languages, it's one of these.
    static let poorlyRecognized: Set<String> = ["km", "lo", "my", "bo", "si", "su", "jw", "ln", "ha", "sn", "yo", "so", "am", "mi", "haw", "ba", "tt"]

    /// Whisper's own 30-second windows in order (each window continues from the last), not silence-split
    /// chunks: in testing, a quiet chunk with speech in it could come back empty, losing whole sentences.
    ///
    /// No vocabulary prompt: in testing it made Whisper drop and garble whole passages (word errors went from
    /// about 9% to over 50%). Names are corrected afterwards instead (`NameCorrector`).
    /// Transcribes only the stretches with speech (`SpeechSpans`), one at a time, with times in the whole track.
    /// For the Khmer model, which was fine-tuned on short clips and makes text up over long silences
    /// (in testing: 83% of characters wrong on a track with pauses, 4% given only the speech).
    func transcribeSpeech(_ samples: [Float], language: String?) async throws -> [TranscriptionResult] {
        guard let kit, let loadedModel else { throw TranscriberError.notLoaded }
        let options = DecodingOptions(
            task: .transcribe,
            language: loadedModel.isEnglishOnly ? "en" : language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: language == nil && !loadedModel.isEnglishOnly,
            skipSpecialTokens: true,
            // Its timestamps aren't reliable (fine-tuned without them); each stretch is one short utterance,
            // so it gets the stretch's time instead.
            withoutTimestamps: true,
            chunkingStrategy: ChunkingStrategy.none
        )
        var all: [TranscriptionResult] = []
        for span in SpeechSpans.find(samples) {
            let results = try await kit.transcribe(audioArray: Array(samples[span]), decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let result = results.first, !text.isEmpty else { continue }
            let start = Float(span.lowerBound) / 16_000, end = Float(span.upperBound) / 16_000
            // One "word" spanning the stretch, so speaker separation can tag it.
            result.segments = [TranscriptionSegment(start: start, end: end, text: text,
                                                    words: [WordTiming(word: text, tokens: [], start: start, end: end, probability: 1)])]
            all.append(result)
        }
        return all
    }

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

/// Lets one speech model load at a time.
actor ModelLoadQueue {
    static let shared = ModelLoadQueue()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}
