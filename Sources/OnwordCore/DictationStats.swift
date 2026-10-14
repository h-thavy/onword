import Foundation

/// The numbers on the Dictation page: total words, speaking speed and day streak.
public struct DictationStats: Equatable {
    public var totalWords: Int
    public var wordsPerMinute: Int
    public var dayStreak: Int

    public struct Item {
        public var date: Date
        public var text: String
        public var seconds: Double
        public init(date: Date, text: String, seconds: Double) {
            self.date = date
            self.text = text
            self.seconds = seconds
        }
    }

    public init(totalWords: Int, wordsPerMinute: Int, dayStreak: Int) {
        self.totalWords = totalWords
        self.wordsPerMinute = wordsPerMinute
        self.dayStreak = dayStreak
    }

    public init(_ items: [Item], now: Date = Date(), calendar: Calendar = .current) {
        let words = items.map { Self.wordCount($0.text) }
        totalWords = words.reduce(0, +)
        let minutes = items.map(\.seconds).reduce(0, +) / 60
        wordsPerMinute = minutes > 0 ? Int((Double(totalWords) / minutes).rounded()) : 0

        // Consecutive days with at least one dictation, ending today (or yesterday, if not yet today).
        let days = Set(items.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var streak = 0
        while days.contains(day) {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        dayStreak = streak
    }

    public static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
