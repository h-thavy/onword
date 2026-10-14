import AppKit
import OnwordCore
import SwiftUI

/// Home: how to dictate, your dictation history by day, and your stats.
struct DictationPage: View {
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var dictation = DictationController.shared
    /// Redraws as soon as the name changes in Settings.
    @AppStorage(UserProfile.key) private var userName = ""
    @State private var query = ""
    @State private var searching = false

    var body: some View {
        PageScroll(maxWidth: 1046) {
            VStack(alignment: .leading, spacing: 6) {
                Text(userName.trimmingCharacters(in: .whitespaces).isEmpty ? greeting : "\(greeting), \(userName.trimmingCharacters(in: .whitespaces))").font(Theme.sans(24, .semibold))
                HStack(spacing: 5) {
                    Text("Hold").foregroundStyle(Theme.inkTertiary)
                    GlowChip(text: dictation.hotkey.chip)
                    Text("in any app and speak. Onword types it for you, privately on this Mac.")
                        .foregroundStyle(Theme.inkTertiary)
                }
                .font(Theme.sans(15))
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 0) {
                    historyHeader.padding(.bottom, 8)
                    historyList
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                StatsCard(stats: history.stats)
                    .frame(width: 250)
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
                    .frame(width: 200)
                Button("Done") { searching = false; query = "" }
                    .buttonStyle(.pillQuiet)
                    .controlSize(.small)
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
            EmptyState(title: query.isEmpty ? "Nothing yet" : "No matches",
                       detail: query.isEmpty ? "Your dictations will show up here." : "Try a different word.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.day) { index, group in
                    SectionLabel(text: group.day)
                        .padding(.top, index == 0 ? 0 : 16)
                        .padding(.bottom, 8)
                    TableCard {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { row, item in
                            if row > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                            HistoryRow(item: item)
                        }
                    }
                    .padding(.bottom, 8)
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
            HStack(spacing: 0) {
                Text(item.entry.date.formatted(date: .omitted, time: .shortened).lowercased()
                        .replacingOccurrences(of: " ", with: ""))
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.inkTertiary)
                    .frame(width: 82, alignment: .leading)   // 98 less the row's 16-pt leading padding
                Text(item.entry.text)
                    .font(Theme.sans(15))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
            }
        } actions: {
            HStack(spacing: 6) {
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
        VStack(alignment: .leading, spacing: 16) {
            stat(stats.totalWords.formatted(), "total words")
            stat("\(stats.wordsPerMinute)", "wpm")
            stat("\(stats.dayStreak)", "day streak")
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLarge).fill(Theme.frame))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge).strokeBorder(Theme.border))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(Theme.serif(28)).tracking(-1.12)
            Text(label).font(Theme.sans(16))
        }
    }
}
