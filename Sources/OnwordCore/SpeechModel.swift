import Foundation

/// Local Whisper models supported by Onword. Raw values are persisted in the existing `model` setting.
public enum SpeechModel: String, CaseIterable, Identifiable {
    case baseEnglish = "base.en"
    case smallEnglish = "small.en"
    case largeTurbo = "large-v3-v20240930_626MB"
    case base = "base"     // multilingual
    case small = "small"   // multilingual
    /// Whisper Small fine-tuned for Khmer (Hongleng/kasekor-asr-v0.0, Apache-2.0), converted for WhisperKit.
    /// The standard models can't write Khmer (in testing they turned it into English or broken characters);
    /// this one got about 4–7% of characters wrong. Used for audio detected as Khmer.
    case khmer = "kasekor-khmer-small"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .baseEnglish: "Base (English) – fastest, ~150 MB"
        case .smallEnglish: "Small (English) – balanced, ~500 MB"
        case .largeTurbo: "Large v3 Turbo (99 languages) – best, ~630 MB"
        case .base: "Base (99 languages) – fastest, ~150 MB"
        case .small: "Small (99 languages) – balanced, ~500 MB"
        case .khmer: "Khmer – ~480 MB"
        }
    }

    /// Speed/accuracy choice; the language decides which model of that size is used.
    public enum Tier: String, CaseIterable, Identifiable {
        case fast, balanced, best
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .fast: "Fast"
            case .balanced: "Balanced"
            case .best: "Most accurate"
            }
        }
        public var detail: String {
            switch self {
            case .fast: "Quickest, a little less accurate"
            case .balanced: "Recommended"
            case .best: "Slower to load, needs more memory"
            }
        }
    }

    public var tier: Tier {
        switch self {
        case .baseEnglish, .base: .fast
        case .smallEnglish, .small, .khmer: .balanced
        case .largeTurbo: .best
        }
    }

    /// The model for a size and language: English gets the English-only model (faster and more accurate
    /// for English); every other language shares one multilingual model of that size.
    public static func variant(_ tier: Tier, english: Bool) -> SpeechModel {
        switch tier {
        case .fast: english ? .baseEnglish : .base
        case .balanced: english ? .smallEnglish : .small
        case .best: .largeTurbo
        }
    }

    public var isEnglishOnly: Bool { rawValue.hasSuffix(".en") }

    public var downloadSize: String {
        switch self {
        case .baseEnglish, .base: "about 150 MB"
        case .smallEnglish, .small, .khmer: "about 500 MB"
        case .largeTurbo: "about 630 MB"
        }
    }

    /// Free space needed to download and compile the model, with headroom.
    public var bytesNeeded: Int64 {
        switch self {
        case .baseEnglish, .base: 400_000_000
        case .smallEnglish, .small, .khmer: 1_000_000_000
        case .largeTurbo: 1_400_000_000
        }
    }

    public var shortTitle: String {
        switch self {
        case .baseEnglish: "Base (English)"
        case .smallEnglish: "Small (English)"
        case .largeTurbo: "Large v3 Turbo"
        case .base: "Base"
        case .small: "Small"
        case .khmer: "Khmer"
        }
    }

    public var displayName: String { "Whisper \(shortTitle)" }

    /// Choices for the requested language, preserving the existing tier-to-model mapping.
    /// Khmer's specialized model is routed automatically after language detection, not chosen as a tier.
    public static func choices(english: Bool) -> [SpeechModel] {
        Tier.allCases.map { variant($0, english: english) }
    }
}
