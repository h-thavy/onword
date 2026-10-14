import AppKit
import OnwordCore
import SwiftUI

/// Home: how to dictate, your dictation history by day, and your stats.
struct DictationPage: View {
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var dictation = DictationController.shared
    @State private var query = ""
    @State private var searching = false

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting).font(Theme.serif(34))
                HStack(spacing: 5) {
                    Text("Hold").foregroundStyle(Theme.inkTertiary)
                    KeyChip(text: dictation.hotkey.chip)
                    Text("in any app and speak. Onword types it for you, privately on this Mac.")
                        .foregroundStyle(Theme.inkTertiary)
                }
                .font(Theme.sans(14))
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    historyHeader
                    historyList
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                StatsCard(stats: history.stats)
                    .frame(width: 190)
            }
        }
        .onAppear { history.reload() }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    private var historyHeader: some View {
        HStack {
            if searching {
                SearchField(prompt: "Search past transcripts", text: $query)
                Button("Done") { searching = false; query = "" }.buttonStyle(.pillQuiet)
            } else {
                Spacer()
                IconButton(systemImage: "magnifyingglass", help: "Search past transcripts") { searching = true }
            }
        }
    }

    @ViewBuilder
    private var historyList: some View {
        let groups = history.grouped(matching: query)
        if groups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(query.isEmpty ? "Nothing yet" : "No matches").font(Theme.sans(15, .semibold))
                Text(query.isEmpty ? "Your dictations will show up here." : "Try a different word.")
                    .foregroundStyle(Theme.inkTertiary)
            }
            .padding(.vertical, 30)
        } else {
            ForEach(groups, id: \.day) { group in
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: group.day).padding(.leading, 12).padding(.bottom, 4)
                    ForEach(group.items) { item in
                        HistoryRow(item: item)
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryStore.Item
    @State private var copied = false

    var body: some View {
        HoverRow {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(item.entry.date.formatted(date: .omitted, time: .shortened).lowercased()
                        .replacingOccurrences(of: " ", with: ""))
                    .font(Theme.sans(12.5).monospacedDigit())
                    .foregroundStyle(Theme.inkTertiary)
                    .frame(width: 58, alignment: .leading)
                Text(item.entry.text)
                    .font(Theme.sans(14))
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        } actions: {
            HStack(spacing: 2) {
                IconButton(systemImage: copied ? "checkmark" : "doc.on.doc", help: "Copy transcript") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.entry.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                IconButton(systemImage: "trash", help: "Delete") { HistoryStore.shared.delete(item) }
            }
        }
    }
}

private struct StatsCard: View {
    let stats: DictationStats

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            stat(stats.totalWords.formatted(), "total words")
            stat("\(stats.wordsPerMinute)", "wpm")
            stat("\(stats.dayStreak)", stats.dayStreak == 1 ? "day streak" : "day streak")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium).strokeBorder(Theme.border))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(Theme.serif(32))
            Text(label).font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
        }
    }
}
