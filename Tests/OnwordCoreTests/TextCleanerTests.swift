import XCTest
@testable import OnwordCore

final class TextCleanerTests: XCTestCase {
    let cleaner = TextCleaner()

    func testRemovesFillers() {
        XCTAssertEqual(cleaner.clean("Um, I think, uh, we should ship it."), "I think, we should ship it.")
        XCTAssertEqual(cleaner.clean("Hmm, okay."), "Okay.")
    }

    func testKeepsFillersWhenDisabled() {
        let keep = TextCleaner(removeFillers: false)
        XCTAssertEqual(keep.clean("Um, hello."), "Um, hello.")
    }

    func testStripsWhisperArtifacts() {
        XCTAssertEqual(cleaner.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(cleaner.clean(" (upbeat music) Hello there."), "Hello there.")
        XCTAssertEqual(cleaner.clean("Hello *coughs* there."), "Hello there.")
        XCTAssertEqual(cleaner.clean("(Bell chimes)"), "")
        XCTAssertEqual(cleaner.clean("Check the docs (section two)."), "Check the docs (section two).")
    }

    func testLineCommands() {
        XCTAssertEqual(cleaner.clean("Dear Sam, new paragraph. Thanks for the update."),
                       "Dear Sam,\n\nThanks for the update.")
        XCTAssertEqual(cleaner.clean("First item. New line. Second item."), "First item.\nSecond item.")
    }

    func testScratchThat() {
        XCTAssertEqual(cleaner.clean("Let's meet Monday. Scratch that. Let's meet Tuesday."), "Let's meet Tuesday.")
        XCTAssertEqual(cleaner.clean("Hi team. Ship it today, scratch that, ship it tomorrow."),
                       "Hi team. Ship it tomorrow.")
    }

    func testReplacements() {
        let c = TextCleaner(replacements: ["my email": "me@example.com", "flow light": "Onword"])
        XCTAssertEqual(c.clean("Send it to my email please."), "Send it to me@example.com please.")
        XCTAssertEqual(c.clean("I love flow light."), "I love Onword.")
        // Word boundaries: "flow lighting" must not change.
        XCTAssertEqual(c.clean("Flow lighting is nice."), "Flow lighting is nice.")
    }

    func testContinuesMidSentence() {
        XCTAssertEqual(cleaner.clean("Then we can deploy.", before: "Once tests pass"), " then we can deploy.")
        XCTAssertEqual(cleaner.clean("I agree.", before: "Honestly"), " I agree.")
        XCTAssertEqual(cleaner.clean("API is down.", before: "the"), " API is down.")
    }

    func testStartsNewSentence() {
        XCTAssertEqual(cleaner.clean("then we deploy.", before: "Tests pass. "), "Then we deploy.")
        XCTAssertEqual(cleaner.clean("hello.", before: "Line one\n"), "Hello.")
        XCTAssertEqual(cleaner.clean("hello."), "Hello.")
    }

    func testInsertingBeforeExistingText() {
        XCTAssertEqual(cleaner.clean("Really.", before: "This is ", after: "good"), "really ")
    }

    func testNoLeadingSpaceAfterOpeningBracket() {
        XCTAssertEqual(cleaner.clean("Optional.", before: "("), "optional.")
    }

    func testHallucinationFilter() {
        XCTAssertTrue(TextCleaner.isLikelyHallucination(" Thank you."))
        XCTAssertTrue(TextCleaner.isLikelyHallucination("Thanks for watching!"))
        XCTAssertFalse(TextCleaner.isLikelyHallucination("Thank you for the review."))
    }
}

final class HotkeyGestureTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 0)

    func testHoldIsPushToTalk() {
        var g = HotkeyGesture()
        XCTAssertEqual(g.press(at: t0), .startRecording)
        XCTAssertEqual(g.release(at: t0.addingTimeInterval(1.2)), .finishRecording)
        XCTAssertFalse(g.isRecording)
    }

    func testSingleQuickTapIsDiscarded() {
        var g = HotkeyGesture()
        XCTAssertEqual(g.press(at: t0), .startRecording)
        XCTAssertEqual(g.release(at: t0.addingTimeInterval(0.1)), .discardRecording)
        XCTAssertFalse(g.isRecording)
    }

    func testDoubleTapEntersHandsFreeAndNextPressFinishes() {
        var g = HotkeyGesture()
        _ = g.press(at: t0)
        _ = g.release(at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(g.press(at: t0.addingTimeInterval(0.25)), .startRecording)
        XCTAssertEqual(g.release(at: t0.addingTimeInterval(0.35)), .enterHandsFree)
        XCTAssertTrue(g.isHandsFree)
        XCTAssertEqual(g.release(at: t0.addingTimeInterval(5)), .ignore)
        XCTAssertEqual(g.press(at: t0.addingTimeInterval(10)), .finishRecording)
        XCTAssertFalse(g.isRecording)
    }

    func testSlowSecondTapIsNotHandsFree() {
        var g = HotkeyGesture()
        _ = g.press(at: t0)
        _ = g.release(at: t0.addingTimeInterval(0.1))
        _ = g.press(at: t0.addingTimeInterval(2))
        XCTAssertEqual(g.release(at: t0.addingTimeInterval(2.1)), .discardRecording)
    }
}

final class UserDictionaryTests: XCTestCase {
    func testPromptRespectsLimit() {
        let d = UserDictionary(vocabulary: ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(d.whisperPrompt(), "Alpha, Beta, Gamma")
        XCTAssertEqual(d.whisperPrompt(maxCharacters: 11), "Alpha, Beta")
        XCTAssertNil(UserDictionary().whisperPrompt())
    }

    func testRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try UserDictionary.example.save(to: url)
        XCTAssertEqual(UserDictionary.load(from: url), .example)
    }
}
