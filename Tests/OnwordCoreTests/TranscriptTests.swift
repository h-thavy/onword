import XCTest
@testable import OnwordCore

final class TranscriptTests: XCTestCase {
    func seg(_ start: Double, _ end: Double, _ speaker: String, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, speaker: speaker, text: text)
    }

    func testMergeInterleavesByTimeAndJoinsSameSpeaker() {
        let me = [seg(0, 2, "me", "Hi everyone."), seg(2.5, 4, "me", "Let's start."), seg(10, 12, "me", "Sounds good.")]
        let others = [seg(5, 9, "s1", "Thanks for joining.")]
        let merged = TranscriptMerger.merge([me, others])
        XCTAssertEqual(merged.map(\.speaker), ["me", "s1", "me"])
        XCTAssertEqual(merged[0].text, "Hi everyone. Let's start.")
        XCTAssertEqual(merged[0].end, 4)
    }

    func testMergeDoesNotJoinAcrossLongPause() {
        let merged = TranscriptMerger.merge([[seg(0, 1, "me", "One."), seg(5, 6, "me", "Two.")]])
        XCTAssertEqual(merged.count, 2)
    }

    func testMergeDropsEmptySegments() {
        XCTAssertTrue(TranscriptMerger.merge([[seg(0, 1, "me", "  ")]]).isEmpty)
    }

    func testRemoveEchoDropsMicCopiesOfRemoteSpeech() {
        let others = [seg(10, 14, "s1", "The budget is approved for next quarter.")]
        let me = [
            seg(10.2, 14.1, "me", "the budget is approved for next quarter"),  // echo through speakers
            seg(20, 22, "me", "Great, thank you."),                            // real
        ]
        let kept = TranscriptMerger.removeEcho(me: me, others: others)
        XCTAssertEqual(kept.map(\.text), ["Great, thank you."])
    }

    func testRemoveEchoKeepsOverlappingButDifferentSpeech() {
        let others = [seg(0, 5, "s1", "Can everyone see my screen?")]
        let me = [seg(1, 3, "me", "Yes, I can see it.")]
        XCTAssertEqual(TranscriptMerger.removeEcho(me: me, others: others).count, 1)
    }

    func testReassignMergesSpeakers() {
        let segments = [seg(0, 2, "s1", "Hello."), seg(2.5, 4, "s3", "Welcome back."), seg(5, 6, "s2", "Hi.")]
        let merged = TranscriptMerger.reassign(segments, from: "s3", to: "s1")
        XCTAssertEqual(merged.map(\.speaker), ["s1", "s2"])
        XCTAssertEqual(merged[0].text, "Hello. Welcome back.")
    }

    func testDropHallucinations() {
        let segments = [seg(0, 4, "s1", "Next Tuesday works."), seg(24, 24.4, "s1", "you"), seg(30, 35, "s2", "Thank you for the update.")]
        XCTAssertEqual(TranscriptMerger.dropHallucinations(segments).map(\.text), ["Next Tuesday works.", "Thank you for the update."])
    }

    func testClock() {
        XCTAssertEqual(TimeFormat.clock(0), "0:00")
        XCTAssertEqual(TimeFormat.clock(75.9), "1:15")
        XCTAssertEqual(TimeFormat.clock(3725), "1:02:05")
    }

    func testMarkdownUsesSpeakerNames() {
        let md = TranscriptExporter.markdown(title: "Standup", date: Date(timeIntervalSince1970: 0),
                                             segments: [seg(42, 45, "s1", "Shipped it.")],
                                             speakerNames: ["s1": "Dara"])
        XCTAssertTrue(md.hasPrefix("# Standup"))
        XCTAssertTrue(md.contains("**Dara** [0:42]: Shipped it."))
    }
}

final class NoteTests: XCTestCase {
    func testTitleAndPreview() {
        let note = Note(body: "\n# Groceries\n\nmilk\neggs")
        XCTAssertEqual(note.title, "Groceries")
        XCTAssertEqual(note.preview, "milk")
        XCTAssertEqual(Note(body: "   \n").title, "New note")
    }

    func testSortPinnedFirstThenRecent() {
        let old = Note(body: "old", updated: Date(timeIntervalSince1970: 1))
        let new = Note(body: "new", updated: Date(timeIntervalSince1970: 2))
        let pinned = Note(body: "pinned", updated: Date(timeIntervalSince1970: 0), pinned: true)
        XCTAssertEqual([old, new, pinned].sortedForList().map(\.body), ["pinned", "new", "old"])
    }

    func testSearch() {
        XCTAssertTrue(Note(body: "Call Sokha about the invoice").matches("sokha"))
        XCTAssertFalse(Note(body: "Call Sokha").matches("invoice"))
        XCTAssertTrue(Note(body: "anything").matches(" "))
    }
}

final class LiveHelpersTests: XCTestCase {
    func testSilenceCutWaitsForEnoughAudio() {
        XCTAssertNil(SilenceCut.index(in: [Float](repeating: 0.5, count: 16_000 * 5)))
    }

    func testSilenceCutFindsThePause() {
        // 9 s of "speech" with a 0.4 s pause at 7.5 s.
        var samples = [Float](repeating: 0.3, count: 16_000 * 9)
        for i in Int(7.5 * 16_000)..<Int(7.9 * 16_000) { samples[i] = 0 }
        let cut = SilenceCut.index(in: samples)!
        XCTAssertEqual(Double(cut) / 16_000, 7.7, accuracy: 0.15)
    }

    func testChunksRespectLimitAndKeepLines() {
        let lines = (1...10).map { "Speaker \($0): " + String(repeating: "word ", count: 10) }
        let chunks = TranscriptText.chunks(lines, maxCharacters: 200)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 200 })
        XCTAssertEqual(chunks.joined(separator: "\n").components(separatedBy: "\n").count, 10)
    }

    func testOverlongLineIsSplitOnWords() {
        let chunks = TranscriptText.chunks([String(repeating: "abc ", count: 100)], maxCharacters: 50)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 50 })
        XCTAssertGreaterThan(chunks.count, 5)
    }
}

final class DictationStatsTests: XCTestCase {
    let calendar = Calendar(identifier: .gregorian)
    func day(_ d: Int, hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: hour))!
    }

    func testTotalsAndSpeed() {
        let stats = DictationStats([
            .init(date: day(13), text: "one two three four five six", seconds: 3),   // 6 words
            .init(date: day(13), text: "seven eight nine ten eleven twelve", seconds: 3),
        ], now: day(13, hour: 18), calendar: calendar)
        XCTAssertEqual(stats.totalWords, 12)
        XCTAssertEqual(stats.wordsPerMinute, 120)
    }

    func testStreakCountsBackFromToday() {
        let items = [11, 12, 13, 9].map { DictationStats.Item(date: day($0), text: "hi", seconds: 1) }
        XCTAssertEqual(DictationStats(items, now: day(13, hour: 20), calendar: calendar).dayStreak, 3)
        // Nothing yet today: the streak up to yesterday still counts.
        XCTAssertEqual(DictationStats(items, now: day(14, hour: 8), calendar: calendar).dayStreak, 3)
        // A missed day breaks it.
        XCTAssertEqual(DictationStats(items, now: day(16), calendar: calendar).dayStreak, 0)
    }

    func testDictionaryReadsOldFilesWithoutSnippets() throws {
        let old = #"{"vocabulary":["Sokha"],"replacements":{"btw":"by the way"}}"#
        let dict = try JSONDecoder().decode(UserDictionary.self, from: Data(old.utf8))
        XCTAssertEqual(dict.snippets, [:])
        XCTAssertEqual(dict.allReplacements, ["btw": "by the way"])
    }
}
