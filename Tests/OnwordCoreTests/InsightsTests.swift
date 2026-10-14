import XCTest
@testable import OnwordCore

final class InsightsTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private func day(_ offset: Int, from now: Date) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }

    func testWordsPerMinuteUsesRawWordsOverMinutes() {
        let now = Date()
        let insights = Insights([
            .init(date: now, app: "com.apple.mail", raw: "one two three four five six", text: "One two three four five six.", seconds: 3),
            .init(date: now, app: "com.apple.mail", raw: "a b c d", text: "A b c d.", seconds: 3),
            .init(date: now, app: nil, raw: "too long", text: "Too long.", seconds: 500),   // ignored for WPM
        ], now: now, calendar: calendar)
        XCTAssertEqual(insights.wordsPerMinute, 100)   // 10 words / 0.1 min
        XCTAssertEqual(insights.totalWords, 12)
    }

    func testPercentileInterpolatesAndLabels() {
        XCTAssertEqual(Insights.percentile(wpm: 40), 50)
        XCTAssertEqual(Insights.percentile(wpm: 45), 60)
        XCTAssertEqual(Insights.percentile(wpm: 200), 99.9)
        XCTAssertEqual(Insights.percentile(wpm: 0), 0)
        XCTAssertEqual(Insights.topLabel(percentile: 29), "71")
        XCTAssertEqual(Insights.topLabel(percentile: 99.9), "0.1")
        XCTAssertNil(Insights.topLabel(percentile: 0))
    }

    func testFixesFromDiff() {
        let change = Insights.wordDiff(from: "um hi dara are you free on friday scratch that saturday", to: "Hi Dara, are you free on Saturday?")
        XCTAssertEqual(change.removed, 4)   // um, friday, scratch, that
        XCTAssertEqual(change.added, 0)
        XCTAssertEqual(Insights.wordDiff(from: "flow light rocks", to: "Onword rocks").added, 1)
    }

    func testCategoriesAndApps() {
        XCTAssertEqual(Insights.category(for: "com.apple.mail"), .email)
        XCTAssertEqual(Insights.category(for: "com.tinyspeck.slackmacgap"), .work)
        XCTAssertEqual(Insights.category(for: "com.openai.chat"), .ai)
        XCTAssertEqual(Insights.category(for: "net.whatsapp.WhatsApp"), .personal)
        XCTAssertEqual(Insights.category(for: "com.apple.Notes"), .document)
        XCTAssertEqual(Insights.category(for: "com.cmuxterm.app"), .other)
        XCTAssertEqual(Insights.category(for: nil), .other)
    }

    func testStreaks() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        let entries = [-6, -5, -1, 0].map { Insights.Dictation(date: day($0, from: now), app: nil, raw: "hello there", text: "Hello there.", seconds: 1) }
        let insights = Insights(entries, now: now, calendar: calendar)
        XCTAssertEqual(insights.currentStreak, 2)
        XCTAssertEqual(insights.longestStreak, 2)
        // Today not dictated yet: the streak still counts through yesterday.
        let yesterdayOnly = Insights(Array(entries.dropLast()), now: now, calendar: calendar)
        XCTAssertEqual(yesterdayOnly.currentStreak, 1)
    }

    func testHeatLevelsAndFunFact() {
        XCTAssertEqual([0, 1, 249, 250, 600, 750].map(Insights.heatLevel), [0, 1, 1, 2, 3, 4])
        XCTAssertEqual(Insights.funFact(totalWords: 18), "You’ve written 3 thank-you notes!")
        XCTAssertEqual(Insights.funFact(totalWords: 0), "You’ve written nothing yet — start dictating!")
    }
}
