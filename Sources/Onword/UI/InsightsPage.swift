import AppKit
import OnwordCore
import SwiftUI

/// Insights, laid out like Wispr Flow's: words per minute with a percentile gauge, fixes, total words,
/// usage by kind of app, and a day-streak heatmap. Everything is computed on this Mac from history.
struct InsightsPage: View {
    @ObservedObject private var history = HistoryStore.shared
    @State private var tab = Tab.usage
    @State private var copied = false

    enum Tab: String, CaseIterable { case usage = "Your usage", voice = "Your voice" }

    private var insights: Insights {
        Insights(history.items.map {
            .init(date: $0.entry.date, app: $0.entry.app, raw: $0.entry.raw, text: $0.entry.text, seconds: $0.entry.seconds)
        })
    }

    var body: some View {
        let insights = insights
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Insights").font(Theme.sans(24, .semibold))
                    Spacer()
                    ShareBadge(tint: tab == .usage ? IN.fathom : IN.chord) { share(insights) }
                        .help("Copy an image of your insights")
                }
                tabs
                Group {
                    switch tab {
                    case .usage: UsageGrid(insights: insights)
                    case .voice: VoiceTab(history: history)
                    }
                }
            }
            .padding(40)
            .frame(maxWidth: 1046 + 80, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .top) {
            if copied {
                Text("Image copied — paste it anywhere").font(Theme.sans(13, .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Theme.ink)).foregroundStyle(Theme.onPrimary)
                    .padding(.top, 16).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: copied)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    Text(item.rawValue).font(Theme.sans(15, .semibold))
                        .foregroundStyle(tab == item ? Theme.ink : Theme.inkFaint)
                        .padding(12)
                        .overlay(alignment: .bottom) {
                            if tab == item { Rectangle().fill(Theme.ink).frame(height: 2) }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .animation(.spring(duration: 0.15), value: tab)
    }

    /// Renders the usage cards to an image and puts it on the clipboard.
    private func share(_ insights: Insights) {
        let card = UsageGrid(insights: insights, staticHeatmap: true)
            .padding(32).frame(width: 1046).background(Theme.panel)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        guard let image = renderer.nsImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}

/// Insights colours (Wispr's "fathom" teals for data).
enum IN {
    static let fathom900 = Color(hex: 0x1A5C5C)
    static let fathom800 = Color(hex: 0x247872)
    static let fathom700 = Color(hex: 0x369489)
    static let fathom500 = Color(hex: 0x68BDB0)
    static let fathom400 = Color(hex: 0x84CDC1)
    static let fathom100 = Color(hex: 0xCEEDEA)
    static let fathom = Color(hex: 0x034F46)
    static let chord = Color(hex: 0x7232A6)
    static let track = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0x46 / 255, green: 0x45 / 255, blue: 0x44 / 255, alpha: 1)
        : NSColor(srgbRed: 0xC5 / 255, green: 0xC0 / 255, blue: 0xB3 / 255, alpha: 1) })
    static let empty = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0x5B / 255, green: 0x5B / 255, blue: 0x59 / 255, alpha: 1)
        : NSColor(srgbRed: 0xC5 / 255, green: 0xC0 / 255, blue: 0xB3 / 255, alpha: 1) })
    static let future = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0x46 / 255, green: 0x45 / 255, blue: 0x44 / 255, alpha: 1)
        : NSColor(srgbRed: 0xEE / 255, green: 0xEB / 255, blue: 0xE3 / 255, alpha: 1) })

    static func heat(_ level: Int) -> Color {
        switch level {
        case 1: fathom100
        case 2: fathom400
        case 3: fathom700
        case 4: fathom800
        default: empty
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Usage

private struct UsageGrid: View {
    let insights: Insights
    var staticHeatmap = false

    var body: some View {
        // Four equal columns, 24 pt apart: [WPM][Fixes][Total words ×2] / [Usage ×2][Streak ×2].
        VStack(spacing: 24) {
            HStack(alignment: .top, spacing: 24) {
                HStack(alignment: .top, spacing: 24) {
                    WPMCard(insights: insights).frame(maxWidth: .infinity, maxHeight: .infinity)
                    FixesCard(insights: insights).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)
                TotalWordsCard(insights: insights).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 24) {
                UsageCard(insights: insights).frame(maxWidth: .infinity, maxHeight: .infinity)
                StreakCard(insights: insights, interactive: !staticHeatmap).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A warm tile: #F5F4F0 fill, 1 pt border, radius 8, 16 pt padding.
private struct Tile<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.frame))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }
}

private struct BigNumber: View {
    let text: String
    var body: some View { Text(text).font(Theme.sans(28, .semibold)).monospacedDigit() }
}

/// 12 pt semibold uppercase label with 0.075 em tracking.
private struct Caps: View {
    let text: String
    var muted = true
    var body: some View {
        Text(text.uppercased()).font(Theme.sans(12, .semibold)).tracking(0.9)
            .foregroundStyle(muted ? Theme.inkTertiary : Theme.ink)
    }
}

private struct InfoIcon: View {
    let help: String
    var body: some View {
        Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Color(hex: 0xB0ABB2)).help(help)
    }
}

private struct Separator: View {
    var body: some View { RoundedRectangle(cornerRadius: 4).fill(IN.track).frame(height: 1) }
}

private struct WPMCard: View {
    let insights: Insights

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 8) {
                BigNumber(text: "\(insights.wordsPerMinute)")
                HStack(spacing: 4) {
                    Caps(text: "Words per minute")
                    InfoIcon(help: "Compared to global typing speeds")
                }
                Gauge(percentile: insights.percentile)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
    }

    /// A 180° arc: radius 70, 16 pt round-capped stroke, teal fill to the percentile.
    private struct Gauge: View {
        let percentile: Double
        @State private var shown = 0.0

        var body: some View {
            ZStack(alignment: .bottom) {
                Arc().stroke(IN.track, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                Arc().trim(from: 0, to: shown).stroke(IN.fathom900, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                if let top = Insights.topLabel(percentile: percentile) {
                    VStack(spacing: 0) {
                        Text("Top").font(Theme.sans(16)).foregroundStyle(Theme.inkTertiary)
                        Text("\(top)%").font(Theme.sans(20, .semibold))
                    }
                    .padding(.bottom, 4)
                }
            }
            .frame(width: 156, height: 86)
            .onAppear { withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) { shown = percentile / 100 } }
            .onChange(of: percentile) { _, value in withAnimation(.spring) { shown = value / 100 } }
        }

        private struct Arc: Shape {
            func path(in rect: CGRect) -> Path {
                var path = Path()
                path.addArc(center: CGPoint(x: 78, y: 78), radius: 70, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                return path
            }
        }
    }
}

private struct FixesCard: View {
    let insights: Insights

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    BigNumber(text: (insights.wordsCorrected + insights.dictionaryFixes).formatted())
                    Caps(text: "Fixes made by Onword")
                }
                if insights.wordsCorrected + insights.dictionaryFixes > 0 {
                    Separator()
                    VStack(alignment: .leading, spacing: 8) {
                        row(insights.wordsCorrected, "words corrected", "Filler words like “um”, “scratch that” and other corrections")
                        row(insights.dictionaryFixes, "dictionary fixes", "Corrections from your dictionary and snippets")
                    }
                }
            }
        }
    }

    private func row(_ count: Int, _ label: String, _ help: String) -> some View {
        HStack(spacing: 4) {
            (Text(count.formatted()).fontWeight(.medium) + Text("\u{00A0}\(label)")).font(Theme.sans(15))
            InfoIcon(help: help)
        }
    }
}

private struct TotalWordsCard: View {
    let insights: Insights

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        BigNumber(text: insights.totalWords.formatted())
                        Spacer()
                        if let delta = insights.monthlyDelta { deltaBadge(delta) }
                    }
                    Caps(text: "Total words dictated")
                }
                Separator()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("This Mac", systemImage: "laptopcomputer")
                        Text("\(insights.totalWords.formatted()) words").foregroundStyle(Theme.inkMuted)
                    }
                    Spacer()
                    Text(Insights.funFact(totalWords: insights.totalWords))
                        .foregroundStyle(Theme.inkMuted).multilineTextAlignment(.trailing)
                        .frame(maxWidth: 240, alignment: .trailing)
                }
                .font(Theme.sans(15))
            }
        }
    }

    private func deltaBadge(_ delta: Double) -> some View {
        let up = delta > 0
        let previous = insights.previousMonthWords ?? 0
        let current = Int((Double(previous) * (1 + delta / 100)).rounded())
        return Label("\(Int(abs(delta).rounded()))% this month",
                     systemImage: up ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
            .font(Theme.sans(12, .semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(up ? IN.fathom100 : Theme.buttonFill))
            .foregroundStyle(up ? IN.fathom : Theme.inkMuted)
            .help("\(current.formatted()) words compared to \(previous.formatted()) words this time last month")
    }
}

private struct UsageCard: View {
    let insights: Insights

    var body: some View {
        Tile {
            HStack(alignment: .lastTextBaseline) {
                Text("Desktop usage").font(Theme.sans(28, .semibold))
                Spacer()
                Caps(text: "Total apps used | \(insights.appsUsed)", muted: false)
            }
            .padding(.bottom, 24)
            if insights.categories.isEmpty {
                Text("Dictate in a few apps and you’ll see where you use Onword most.")
                    .font(Theme.sans(15)).foregroundStyle(Theme.inkTertiary)
            } else {
                GeometryReader { proxy in
                    let maxPct = insights.categories.map(\.percentage).max() ?? 100
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(insights.categories.enumerated()), id: \.element.category) { index, usage in
                            row(usage, index: index, width: max(35, proxy.size.width * 0.55 * usage.percentage / maxPct))
                        }
                    }
                }
                .frame(height: CGFloat(insights.categories.count) * 44)
            }
        }
    }

    private func row(_ usage: Insights.CategoryUsage, index: Int, width: CGFloat) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon(usage.category)).font(.system(size: 16)).frame(width: 20)
            Text("\(Int(usage.percentage.rounded()))%")
                .font(Theme.sans(12, .semibold)).foregroundStyle(Color(hex: 0xFCFCFB))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(width: width)
                .background(RoundedRectangle(cornerRadius: 4).fill(index == 0 ? IN.fathom900 : index < 3 ? IN.fathom700 : IN.fathom500))
            Caps(text: "\(usage.units) \(usage.category.label)", muted: false).lineLimit(1)
            Spacer(minLength: 0)
        }
        .help("\(usage.words >= 10000 ? "🚀 Power usage" : usage.words >= 1000 ? "👍 Moderate usage" : "🤏 Light usage") · \(usage.words.formatted()) words")
    }

    private func icon(_ category: Insights.Category) -> String {
        switch category {
        case .ai: "cpu"
        case .email: "envelope"
        case .work: "text.bubble"
        case .personal: "ellipsis.bubble"
        case .document: "doc.text"
        case .other: "infinity"
        }
    }
}

private struct StreakCard: View {
    let insights: Insights
    var interactive = true
    @State private var weekOffset = 0

    private let calendar = Calendar.current

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("\(insights.currentStreak) day streak").font(Theme.sans(28, .semibold))
                    Spacer()
                    if insights.longestStreak > 0 {
                        Caps(text: "Longest streak | \(insights.longestStreak) day\(insights.longestStreak == 1 ? "" : "s")", muted: false)
                    }
                }
                GeometryReader { proxy in
                    heatmap(weeks: max(1, Int((proxy.size.width - 29 - 64 + 8) / 24)))
                }
                .frame(height: 16 + 24 + 7 * 24 - 8)
                legend
            }
        }
    }

    private func heatmap(weeks: Int) -> some View {
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.date(byAdding: .day, value: -(calendar.component(.weekday, from: today) - 1), to: today)!
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -weekOffset, to: thisWeek)!
        let starts = (0..<weeks).map { calendar.date(byAdding: .weekOfYear, value: $0 - weeks + 1, to: lastWeek)! }
        let first = insights.firstDay ?? today
        let streakStart = insights.currentStreak > 1
            ? calendar.date(byAdding: .day, value: -(insights.currentStreak - 1), to: lastActiveDay(today))! : nil

        return VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                chevron("chevron.left", enabled: interactive && (starts.first ?? today) > first) { weekOffset += 4 }
                ZStack(alignment: .topLeading) {
                    ForEach(monthLabels(starts), id: \.index) { label in
                        Text(label.text).font(Theme.sans(10)).foregroundStyle(Theme.inkTertiary)
                            .offset(x: CGFloat(label.index) * 24 + 29)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                chevron("chevron.right", enabled: interactive && weekOffset > 0) { weekOffset = max(0, weekOffset - 4) }
            }
            .frame(height: 16)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) {
                        Text($0).font(Theme.sans(10)).foregroundStyle(Theme.inkTertiary).frame(width: 21, height: 16, alignment: .leading)
                    }
                }
                HStack(spacing: 8) {
                    ForEach(starts, id: \.self) { start in
                        VStack(spacing: 8) {
                            ForEach(0..<7, id: \.self) { offset in
                                cell(calendar.date(byAdding: .day, value: offset, to: start)!, today: today, first: first, streakStart: streakStart)
                            }
                        }
                    }
                }
            }
            .padding(.leading, 32)
        }
    }

    private func lastActiveDay(_ today: Date) -> Date {
        insights.days.keys.filter { $0 <= today }.max() ?? today
    }

    private func cell(_ date: Date, today: Date, first: Date, streakStart: Date?) -> some View {
        let visible = date >= first && date <= today
        let day = insights.days[date]
        let inStreak = streakStart.map { date >= $0 && date <= lastActiveDay(today) } ?? false
        return RoundedRectangle(cornerRadius: 2)
            .fill(visible ? IN.heat(Insights.heatLevel(words: day?.words ?? 0)) : IN.future)
            .frame(width: 16, height: 16)
            .overlay { if inStreak { RoundedRectangle(cornerRadius: 3).strokeBorder(IN.fathom800).frame(width: 20, height: 20) } }
            .help(visible ? tooltip(date, day) : "")
    }

    private func tooltip(_ date: Date, _ day: Insights.Day?) -> String {
        let top = day?.topApp.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? day?.topApp ?? "—"
        return "\(date.formatted(.dateTime.month(.wide).day().year()))\nTotal words: \(day?.words ?? 0)\nTotal apps used: \(day?.apps.count ?? 0)\nTop app: \(top)"
    }

    private func monthLabels(_ starts: [Date]) -> [(index: Int, text: String)] {
        var labels: [(index: Int, text: String)] = []
        var lastMonth = -1
        for (index, start) in starts.enumerated() {
            let month = calendar.component(.month, from: start)
            if month != lastMonth {
                if let last = labels.last, index - last.index < 3 { labels.removeLast() }
                labels.append((index, start.formatted(.dateTime.month(.abbreviated))))
                lastMonth = month
            }
        }
        return labels
    }

    private func chevron(_ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12, weight: .semibold)).frame(width: 20, height: 20)
        }
        .buttonStyle(.plain).foregroundStyle(Theme.inkTertiary).opacity(enabled ? 1 : 0.3).disabled(!enabled)
    }

    private var legend: some View {
        HStack(spacing: 8) {
            Text("More")
            ForEach([4, 3, 2, 1], id: \.self) { RoundedRectangle(cornerRadius: 2).fill(IN.heat($0)).frame(width: 16, height: 16) }
            Text("Less")
            Spacer()
            if insights.currentStreak > 1 {
                RoundedRectangle(cornerRadius: 3).strokeBorder(IN.fathom800).frame(width: 20, height: 20)
                Text("Current streak")
            }
        }
        .font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
    }
}

// MARK: - Your voice

/// Peak time, most used word and most corrected word, computed on this Mac. Unlocks at 2,000 words.
private struct VoiceTab: View {
    @ObservedObject var history: HistoryStore
    static let unlockWords = 2000

    private static let stopwords: Set<String> = Set("""
    the be to of and a in that have i it for not on with he as you do at this but his by from they we say her she or an \
    will my one all would there their what so up out if about who get which go me when make can like time no just him know \
    take people into year your good some could them see other than then now look only come its over think also back after \
    use two how our work first well way even new want because any these give day most us is are was were been has had did \
    am does doing done being having
    """.split(separator: " ").map(String.init))

    var body: some View {
        let entries = history.items.map(\.entry)
        let words = entries.map { Insights.wordCount($0.raw.isEmpty ? $0.text : $0.raw) }.reduce(0, +)
        if words < Self.unlockWords {
            VStack(spacing: 12) {
                Text("Unlocks in \((Self.unlockWords - words).formatted()) words").font(Theme.serif(65)).tracking(-2.6)
                Text("Keep dictating — your voice profile is built on this Mac from what you say.")
                    .font(Theme.sans(18)).foregroundStyle(Theme.inkMuted)
                ProgressView(value: Double(words), total: Double(Self.unlockWords)).tint(Theme.tileRing).frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 80)
        } else {
            let peak = peakTime(entries)
            Grid(horizontalSpacing: 24, verticalSpacing: 24) {
                GridRow {
                    card("Most used word", "“\(mostUsedWord(entries) ?? "—")”")
                    card("Most corrected word", "“\(mostCorrectedWord(entries) ?? "—")”")
                }
                GridRow {
                    card("Your peak time", peak.time)
                    card("Where you dictate then", peak.app ?? "—")
                }
            }
            Text("Your dictations are private and only stored on this Mac.").font(Theme.sans(12)).italic()
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    private func card(_ title: String, _ value: String) -> some View {
        Tile {
            VStack(alignment: .leading, spacing: 12) {
                Caps(text: title)
                Text(value).font(Theme.serif(28)).italic()
            }
        }
    }

    private func tokens(_ text: String) -> [String] {
        var out: [String] = []
        text.lowercased().enumerateSubstrings(in: text.lowercased().startIndex..., options: .byWords) { word, _, _, _ in
            if let word, word.count > 1, word.contains(where: \.isLetter) { out.append(word) }
        }
        return out
    }

    private func mostUsedWord(_ entries: [HistoryEntry]) -> String? {
        var counts: [String: Int] = [:]
        for entry in entries { for word in tokens(entry.text) where !Self.stopwords.contains(word) { counts[word, default: 0] += 1 } }
        return counts.max { $0.value < $1.value }?.key
    }

    private func mostCorrectedWord(_ entries: [HistoryEntry]) -> String? {
        var counts: [String: Int] = [:]
        for entry in entries {
            var remaining = tokens(entry.text)
            for word in tokens(entry.raw) {
                if let index = remaining.firstIndex(of: word) { remaining.remove(at: index) } else { counts[word, default: 0] += 1 }
            }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    private func peakTime(_ entries: [HistoryEntry]) -> (time: String, app: String?) {
        let calendar = Calendar.current
        var slots: [String: [HistoryEntry]] = [:]
        for entry in entries {
            let weekday = calendar.component(.weekday, from: entry.date), hour = calendar.component(.hour, from: entry.date)
            slots["\(weekday)-\(hour)", default: []].append(entry)
        }
        guard let best = slots.max(by: { $0.value.count < $1.value.count }), let sample = best.value.first else { return ("—", nil) }
        let time = sample.date.formatted(.dateTime.weekday(.wide)) + " at " + sample.date.formatted(.dateTime.hour())
        var apps: [String: Int] = [:]
        for entry in best.value { if let app = entry.app { apps[app, default: 0] += 1 } }
        let app = apps.max { $0.value < $1.value }.map(\.key).flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        return (time, app)
    }
}

/// Wispr's round SHARE badge: "SHARE•" around a circle with a share icon; spins slowly on hover.
private struct ShareBadge: View {
    let tint: Color
    let action: () -> Void
    @State private var hovering = false
    @State private var angle = 0.0

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Theme.frame)
                ZStack {
                    let characters = Array(String(repeating: "SHARE•", count: 3))
                    ForEach(Array(characters.enumerated()), id: \.offset) { index, char in
                        Text(String(char)).font(.system(size: 9, weight: .bold))
                            .foregroundStyle(tint)
                            .offset(y: -26)
                            .rotationEffect(.degrees(Double(index) / Double(characters.count) * 360))
                    }
                }
                .rotationEffect(.degrees(angle))
                Image(systemName: "square.and.arrow.up").font(.system(size: 18)).foregroundStyle(tint).offset(y: -1)
            }
            .frame(width: 70, height: 70)
            .scaleEffect(hovering ? 1.1 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { over in
            withAnimation(.spring(duration: 0.2)) { hovering = over }
            if over {
                withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) { angle += 360 }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { angle = 0 }
            }
        }
    }
}
