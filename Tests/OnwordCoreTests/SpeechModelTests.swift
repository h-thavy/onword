import XCTest
@testable import OnwordCore

final class SpeechModelTests: XCTestCase {
    func testExistingSavedModelIdentifiersStillRestore() {
        let saved: [(String, SpeechModel)] = [
            ("base.en", .baseEnglish), ("small.en", .smallEnglish),
            ("base", .base), ("small", .small),
            ("large-v3-v20240930_626MB", .largeTurbo), ("kasekor-khmer-small", .khmer)
        ]
        for (rawValue, expected) in saved {
            XCTAssertEqual(SpeechModel(rawValue: rawValue), expected)
            XCTAssertEqual(expected.rawValue, rawValue)
        }
    }

    func testEnglishPickerPreservesSpeedChoices() {
        XCTAssertEqual(SpeechModel.choices(english: true), [.baseEnglish, .smallEnglish, .largeTurbo])
    }

    func testMultilingualPickerPreservesSpeedChoices() {
        let choices = SpeechModel.choices(english: false)
        XCTAssertEqual(choices, [.base, .small, .largeTurbo])
        XCTAssertFalse(choices.contains(where: \.isEnglishOnly))
        // Khmer remains an automatic language-specific route, not a general-purpose tier.
        XCTAssertFalse(choices.contains(.khmer))
    }

    func testEveryChoiceSelectsTheNamedModelForItsLanguage() {
        for english in [true, false] {
            for choice in SpeechModel.choices(english: english) {
                XCTAssertEqual(SpeechModel.variant(choice.tier, english: english), choice)
            }
        }
    }
}
