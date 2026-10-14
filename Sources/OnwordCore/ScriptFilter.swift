import Foundation

/// Removes text in writing systems none of your languages use: Whisper sometimes answers unclear or
/// low-resource speech (Khmer with a small model) with phonetic symbols ("Ḍʃʃʀ ḍʃʀ ʀᴀᴀʀ") or broken characters
/// (�). Words made mostly of such letters are dropped; Latin is always kept.
public enum ScriptFilter {
    public static func clean(_ text: String, languages: [String]) -> String {
        guard !text.isEmpty else { return text }
        let allowed = Set(languages.flatMap { scripts[$0] ?? [] })
        let words = text.replacingOccurrences(of: "\u{FFFD}", with: "").split(separator: " ", omittingEmptySubsequences: true)
        let kept = words.filter { word in
            let letters = word.unicodeScalars.filter { $0.properties.isAlphabetic }
            guard !letters.isEmpty else { return true }
            let foreign = letters.filter { !isAllowed($0, allowed) }.count
            return Double(foreign) / Double(letters.count) <= 0.5
        }
        return kept.joined(separator: " ")
    }

    private enum Script { case khmer, cjk, kana, hangul, thai, lao, myanmar, cyrillic, greek, arabic, hebrew, devanagari, bengali, tamil, georgian, armenian, ethiopic, sinhala, telugu, kannada, malayalam, gujarati, gurmukhi, tibetan }

    private static let scripts: [String: [Script]] = [
        "km": [.khmer], "zh": [.cjk], "yue": [.cjk], "ja": [.kana, .cjk], "ko": [.hangul], "th": [.thai], "lo": [.lao],
        "my": [.myanmar], "ru": [.cyrillic], "uk": [.cyrillic], "be": [.cyrillic], "bg": [.cyrillic], "sr": [.cyrillic],
        "mk": [.cyrillic], "kk": [.cyrillic], "mn": [.cyrillic], "tg": [.cyrillic], "ba": [.cyrillic], "tt": [.cyrillic],
        "el": [.greek], "ar": [.arabic], "fa": [.arabic], "ur": [.arabic], "ps": [.arabic], "sd": [.arabic],
        "he": [.hebrew], "yi": [.hebrew], "hi": [.devanagari], "mr": [.devanagari], "ne": [.devanagari], "sa": [.devanagari],
        "bn": [.bengali], "as": [.bengali], "ta": [.tamil], "ka": [.georgian], "hy": [.armenian], "am": [.ethiopic],
        "si": [.sinhala], "te": [.telugu], "kn": [.kannada], "ml": [.malayalam], "gu": [.gujarati], "pa": [.gurmukhi],
        "bo": [.tibetan],
    ]

    private static func isAllowed(_ scalar: Unicode.Scalar, _ allowed: Set<Script>) -> Bool {
        let v = scalar.value
        // Latin (with accents, including Vietnamese), always allowed.
        if v < 0x0250 || (0x1E00...0x1EFF).contains(v) || (0x2C60...0x2C7F).contains(v) || (0xA720...0xA7FF).contains(v) { return true }
        func has(_ script: Script, _ ranges: ClosedRange<UInt32>...) -> Bool {
            allowed.contains(script) && ranges.contains { $0.contains(v) }
        }
        return has(.khmer, 0x1780...0x17FF, 0x19E0...0x19FF)
            || has(.cjk, 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2FFFF, 0x3000...0x303F)
            || has(.kana, 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F)
            || has(.hangul, 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F)
            || has(.thai, 0x0E00...0x0E7F) || has(.lao, 0x0E80...0x0EFF) || has(.myanmar, 0x1000...0x109F)
            || has(.cyrillic, 0x0400...0x052F) || has(.greek, 0x0370...0x03FF, 0x1F00...0x1FFF)
            || has(.arabic, 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF)
            || has(.hebrew, 0x0590...0x05FF) || has(.devanagari, 0x0900...0x097F) || has(.bengali, 0x0980...0x09FF)
            || has(.tamil, 0x0B80...0x0BFF) || has(.georgian, 0x10A0...0x10FF) || has(.armenian, 0x0530...0x058F)
            || has(.ethiopic, 0x1200...0x137F) || has(.sinhala, 0x0D80...0x0DFF) || has(.telugu, 0x0C00...0x0C7F)
            || has(.kannada, 0x0C80...0x0CFF) || has(.malayalam, 0x0D00...0x0D7F) || has(.gujarati, 0x0A80...0x0AFF)
            || has(.gurmukhi, 0x0A00...0x0A7F) || has(.tibetan, 0x0F00...0x0FFF)
    }
}
