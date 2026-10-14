import Foundation

/// The Insights page's numbers, computed on this Mac from dictation history with the same formulas
/// Wispr Flow uses (it computes most of them on its servers).
public struct Insights: Equatable {
    public struct Dictation {
        public var date: Date
        public var app: String?
        public var raw: String
        public var text: String
        public var seconds: Double
        public init(date: Date, app: String?, raw: String, text: String, seconds: Double) {
            self.date = date
            self.app = app
            self.raw = raw
            self.text = text
            self.seconds = seconds
        }
    }

    public enum Category: String, CaseIterable, Equatable {
        case ai, email, work, personal, document, other
        public var label: String {
            switch self {
            case .ai: "AI prompts"
            case .email: "emails"
            case .work: "work messages"
            case .personal: "personal messages"
            case .document: "documents"
            case .other: "other tasks"
            }
        }
    }

    public struct CategoryUsage: Equatable {
        public var category: Category
        public var words: Int
        public var dictations: Int
        public var percentage: Double
        /// What the bar's caption counts: emails ≈ 2 dictations, documents ≈ 5, others 1.
        public var units: Int {
            switch category {
            case .email: Int((Double(dictations) / 2).rounded())
            case .document: Int((Double(dictations) / 5).rounded())
            default: dictations
            }
        }
    }

    public struct Day: Equatable {
        public var words: Int
        public var apps: [String: Int]
        public var topApp: String? { apps.max { $0.value < $1.value }?.key }
    }

    public var wordsPerMinute: Int
    /// 0…100, where on a typing-speed distribution this WPM falls (0 = not enough data).
    public var percentile: Double
    public var totalWords: Int
    public var wordsCorrected: Int
    public var dictionaryFixes: Int
    /// This month so far vs. last month up to the same day, in percent; nil without last-month data.
    public var monthlyDelta: Double?
    public var previousMonthWords: Int?
    public var categories: [CategoryUsage]
    public var appsUsed: Int
    public var currentStreak: Int
    public var longestStreak: Int
    /// Keyed by the local start of day.
    public var days: [Date: Day]
    public var firstDay: Date?

    public init(_ dictations: [Dictation], now: Date = Date(), calendar: Calendar = .current) {
        let counted = dictations.map { (entry: $0, words: Self.wordCount($0.raw.isEmpty ? $0.text : $0.raw)) }
            .filter { $0.words > 0 }
            .sorted { $0.entry.date < $1.entry.date }

        // WPM: the last 100 dictations under 400 s; raw words over speaking minutes.
        let recent = counted.filter { $0.entry.seconds < 400 }.suffix(100)
        let minutes = recent.map(\.entry.seconds).reduce(0, +) / 60
        wordsPerMinute = minutes > 0 ? Int((Double(recent.map(\.words).reduce(0, +)) / minutes).rounded()) : 0
        percentile = Self.percentile(wpm: Double(wordsPerMinute))

        totalWords = counted.map(\.words).reduce(0, +)
        var corrected = 0, fixes = 0
        for item in counted {
            let change = Self.wordDiff(from: item.entry.raw, to: item.entry.text)
            corrected += change.removed
            fixes += change.added
        }
        wordsCorrected = corrected
        dictionaryFixes = fixes

        // Monthly change: this month to date vs. last month up to the same day of the month.
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
        let lastMonthSameDay = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        let thisMonth = counted.filter { $0.entry.date >= monthStart && $0.entry.date <= now }.map(\.words).reduce(0, +)
        let lastMonth = counted.filter { $0.entry.date >= lastMonthStart && $0.entry.date <= lastMonthSameDay }
            .map(\.words).reduce(0, +)
        previousMonthWords = lastMonth > 0 ? lastMonth : nil
        monthlyDelta = lastMonth > 0 ? Double(thisMonth - lastMonth) / Double(lastMonth) * 100 : nil

        var byCategory: [Category: (words: Int, dictations: Int)] = [:]
        for item in counted {
            let category = Self.category(for: item.entry.app)
            byCategory[category, default: (0, 0)].words += item.words
            byCategory[category, default: (0, 0)].dictations += 1
        }
        let total = max(1, byCategory.values.map(\.words).reduce(0, +))
        categories = byCategory.map {
            CategoryUsage(category: $0.key, words: $0.value.words, dictations: $0.value.dictations,
                          percentage: Double($0.value.words) / Double(total) * 100)
        }
        .sorted { $0.words > $1.words }
        appsUsed = Set(counted.compactMap { $0.entry.app?.lowercased() }).count

        var days: [Date: Day] = [:]
        for item in counted {
            let day = calendar.startOfDay(for: item.entry.date)
            days[day, default: Day(words: 0, apps: [:])].words += item.words
            if let app = item.entry.app { days[day, default: Day(words: 0, apps: [:])].apps[app, default: 0] += item.words }
        }
        self.days = days
        firstDay = counted.first.map { calendar.startOfDay(for: $0.entry.date) }

        // Streaks: consecutive days with any words. The current one may end today or yesterday.
        let active = Set(days.keys)
        var longest = 0, run = 0
        var previous: Date?
        for day in active.sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day { run += 1 } else { run = 1 }
            longest = max(longest, run)
            previous = day
        }
        longestStreak = longest
        let today = calendar.startOfDay(for: now)
        var cursor = active.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        var current = 0
        while active.contains(cursor) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        currentStreak = current
    }

    // MARK: - Formulas

    /// Words, counted the way a word-segmenter does (works for Japanese and Thai as well as English).
    public static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }

    /// A global typing-speed distribution (WPM → share of typists slower), interpolated like Wispr's.
    static let buckets: [Double] = [10, 20, 30, 40, 50, 60, 75, 85, 95, 120, 150]
    static let quantiles: [Double] = [0.03, 0.10, 0.25, 0.50, 0.70, 0.82, 0.90, 0.95, 0.97, 0.99, 0.999]

    public static func percentile(wpm: Double) -> Double {
        guard wpm > 0 else { return 0 }
        guard let upper = buckets.firstIndex(where: { $0 > wpm }) else { return 99.9 }
        if upper == 0 { return round1(wpm / buckets[0] * quantiles[0] * 100) }
        let lower = upper - 1
        let low = quantiles[lower] * 100, high = quantiles[upper] * 100
        let fraction = (wpm - buckets[lower]) / (buckets[upper] - buckets[lower])
        return round1(min(low + fraction * (high - low), 99.9))
    }

    private static func round1(_ value: Double) -> Double { (value * 10).rounded(.toNearestOrEven) / 10 }

    /// "71" for the gauge's "Top 71%", nil when there's no percentile yet.
    public static func topLabel(percentile: Double) -> String? {
        let p = min(max(percentile, 0), 100)
        guard p > 0 else { return nil }
        let top = 100 - p
        return top < 1 ? String(format: "%.1f", max(0.1, top)) : String(min(99, Int(top.rounded())))
    }

    /// Words the clean-up removed (fillers, "scratch that") and added (dictionary and snippet replacements),
    /// from a word-level diff of what was heard and what was typed.
    public static func wordDiff(from raw: String, to text: String) -> (removed: Int, added: Int) {
        func tokens(_ s: String) -> [String] {
            var out: [String] = []
            s.lowercased().enumerateSubstrings(in: s.lowercased().startIndex..., options: .byWords) { word, _, _, _ in
                if let word { out.append(word) }
            }
            return out
        }
        let a = tokens(raw), b = tokens(text)
        guard !a.isEmpty || !b.isEmpty else { return (0, 0) }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        let common = table[0][0]
        return (a.count - common, b.count - common)
    }

    /// Heatmap shade: 0 (none) … 4 (750+ words).
    public static func heatLevel(words: Int) -> Int {
        switch words {
        case ..<1: 0
        case ..<250: 1
        case ..<500: 2
        case ..<750: 3
        default: 4
        }
    }

    /// "You've written 3 postcards!"
    public static func funFact(totalWords total: Int) -> String {
        guard total > 0 else { return "You’ve written nothing yet — start dictating!" }
        let bins: [(max: Int, divisor: Int, one: String, many: String)] = [
            (50, 5, "thank-you note", "thank-you notes"), (100, 10, "meme caption", "meme captions"),
            (200, 10, "thank-you note", "thank-you notes"), (350, 14, "meme caption", "meme captions"),
            (1000, 50, "postcard", "postcards"), (2000, 100, "folk tale", "folk tales"),
            (3000, 200, "wedding vow", "wedding vows"), (5000, 300, "tweet", "tweets"),
            (6000, 500, "news article", "news articles"), (7000, 700, "cover letter", "cover letters"),
            (10000, 900, "email newsletter", "email newsletters"), (15000, 7500, "instruction manual", "instruction manuals"),
            (20000, 9000, "Dr. Seuss book", "Dr. Seuss books"), (30000, 10000, "college essay", "college essays"),
            (50000, 4300, "short film script", "short film scripts"), (70000, 35000, "book chapter", "book chapters"),
            (100000, 35000, "podcast season", "podcast seasons"), (.max, 100000, "complete book", "complete books"),
        ]
        let bin = bins.first { total <= $0.max } ?? bins[bins.count - 1]
        let count = max(1, total / bin.divisor)
        return "You’ve written \(count) \(count == 1 ? bin.one : bin.many)!"
    }

    // MARK: - Categories (Wispr's lists, matched by prefix in this order)

    public static func category(for app: String?) -> Category {
        guard let id = app?.lowercased().trimmingCharacters(in: .whitespaces), !id.isEmpty else { return .other }
        for (category, prefixes) in categoryPrefixes where prefixes.contains(where: { id.hasPrefix($0) }) {
            return category
        }
        return .other
    }

    static let categoryPrefixes: [(Category, [String])] = [
        (.ai, ["com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop", "com.todesktop.230313mzl4w4u92",
               "com.exafunction.windsurf", "com.microsoft.vscode", "ai.perplexity.perplexity-mac", "dev.warp.warp-stable",
               "com.mitchellh.ghostty", "chatgpt.com", "chat.openai.com", "gemini.google.com", "claude.ai", "perplexity.com"]),
        (.email, ["com.apple.mail", "com.microsoft.outlook", "com.google.gmail", "com.superhuman.electron",
                  "com.mimestream.mimestream", "org.mozilla.thunderbird", "it.bloop.airmail2", "com.readdle.sparkdesktop",
                  "com.readdle.smartemail-mac", "com.edisonmail.edisonmail", "com.frontapp.front", "com.hey.app.desktop",
                  "io.canarymail.mac", "com.missiveapp.osx", "mail.google.com", "outlook.live.com", "outlook.office.com"]),
        (.work, ["com.microsoft.teams", "com.slack.slack", "com.tinyspeck.slackmacgap", "us.zoom.xos", "com.cisco.webexmeetingsapp",
                 "com.ringcentral", "com.mattermost", "com.electron.lark", "app.slack.com", "teams.microsoft.com", "linkedin.com"]),
        (.personal, ["com.apple.mobilesms", "net.whatsapp.whatsapp", "desktop.whatsapp", "com.facebook.archon", "im.beeper",
                     "ru.keepcoder.telegram", "com.tdesktop.telegram", "org.whispersystems.signal-desktop",
                     "com.discordapp.discord", "com.hnc.discord", "com.tencent.xinwechat", "jp.naver.line.mac",
                     "com.viber.osx", "com.kakao.kakaotalkmac", "web.whatsapp.com", "messenger.com", "discord.com"]),
        (.document, ["notion.id", "com.notion.id", "com.microsoft.word", "com.apple.iwork.pages", "com.evernote.evernote",
                     "com.bear-writer.bear", "md.obsidian", "com.dayoneapp.dayone", "com.omnigroup.omnifocus",
                     "com.microsoft.excel", "com.microsoft.powerpoint", "com.microsoft.onenote", "com.apple.notes",
                     "com.linear", "com.figma.desktop", "com.apple.dt.xcode", "com.google.android.studio", "com.jetbrains",
                     "com.sublimetext", "com.panic.nova", "com.barebones.bbedit", "abnerworks.typora", "com.apple.iwork.numbers",
                     "com.apple.iwork.keynote", "com.adobe", "com.readdle.pdfexpert", "com.apple.reminders", "com.apple.ical",
                     "com.apple.stickies", "com.apple.textedit", "io.github.h-thavy.onword", "docs.google.com", "notion.so"]),
    ]
}
