import OnwordCore
import SwiftUI

/// Words Onword should spell your way, and corrections ("flow light" → "Onword").
struct DictionaryPage: View {
    @ObservedObject private var store = DictionaryStore.shared
    @State private var query = ""
    @State private var editing: EditTarget?

    enum EditTarget: Identifiable {
        case new
        case entry(DictionaryStore.Entry)
        var id: String {
            switch self {
            case .new: "new"
            case .entry(let e): e.id
            }
        }
    }

    var body: some View {
        PageScroll {
            PageHeader(title: "Dictionary") {
                Button { editing = .new } label: { Label("Add new", systemImage: "plus") }.buttonStyle(.pill)
            }
            HeroCard(before: "Onword spells the way ", italic: "you", after: " do.",
                     message: "Add names, company jargon and uncommon words so they're spelled right in dictations and meeting notes. Add a correction when Onword keeps hearing something wrong.") {
                Button("Add new word") { editing = .new }.buttonStyle(.pillQuiet)
            }
            SearchField(prompt: "Search vocabulary", text: $query)

            let entries = store.entries(matching: query)
            if entries.isEmpty {
                EmptyState(title: query.isEmpty ? "No words yet." : "No matches",
                           detail: query.isEmpty ? "Words and corrections you add show up here." : "Try a different word.")
            } else {
                TableCard {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        HoverRow {
                            switch entry {
                            case .word(let word):
                                Text(word).font(Theme.sans(15))
                            case .correction(let from, let to):
                                HStack(spacing: 8) {
                                    Text(from).foregroundStyle(Theme.inkTertiary)
                                    Image(systemName: "arrow.right").font(.system(size: 12)).foregroundStyle(Theme.inkTertiary)
                                    Text(to).font(Theme.sans(15))
                                }
                            }
                        } actions: {
                            HStack(spacing: 6) {
                                IconButton(systemImage: "pencil", help: "Edit") { editing = .entry(entry) }
                                IconButton(systemImage: "trash", help: "Delete") { store.remove(entry) }
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { target in
            DictionaryEditor(target: target) { editing = nil }
        }
    }
}

private struct DictionaryEditor: View {
    let target: DictionaryPage.EditTarget
    let done: () -> Void
    @State private var isCorrection = false
    @State private var word = ""
    @State private var heard = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add to dictionary" : "Edit").font(Theme.serif(26))
            Picker("", selection: $isCorrection) {
                Text("Word").tag(false)
                Text("Correction").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!isNew)

            if isCorrection {
                field("When Onword hears", $heard, "flow light")
                field("Write", $word, "Onword")
            } else {
                field("Word or name", $word, "Sokha, Kubernetes, WhisperKit…")
                Text("Onword will expect this word and spell it exactly like this.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: done).buttonStyle(.pillQuiet).keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(.pill).keyboardShortcut(.defaultAction)
                    .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty
                              || (isCorrection && heard.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(24)
        .frame(minWidth: 480)
        .background(Theme.panel)
        .onAppear(perform: load)
    }

    private var isNew: Bool { if case .new = target { true } else { false } }

    private func field(_ label: String, _ text: Binding<String>, _ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.inkSecondary)
            TextField(prompt, text: text).textFieldStyle(.plain).font(Theme.sans(15))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
        }
    }

    private func load() {
        guard case .entry(let entry) = target else { return }
        switch entry {
        case .word(let w): word = w
        case .correction(let from, let to): isCorrection = true; heard = from; word = to
        }
    }

    private func save() {
        let newWord = word.trimmingCharacters(in: .whitespaces)
        let newHeard = heard.trimmingCharacters(in: .whitespaces)
        DictionaryStore.shared.update { d in
            if case .entry(let old) = target {
                switch old {
                case .word(let w): d.vocabulary.removeAll { $0 == w }
                case .correction(let from, _): d.replacements[from] = nil
                }
            }
            if isCorrection {
                d.replacements[newHeard] = newWord
            } else if !d.vocabulary.contains(newWord) {
                d.vocabulary.insert(newWord, at: 0)
            }
        }
        done()
    }
}

/// Text you say a short phrase to insert ("my email" → "me@example.com").
struct SnippetsPage: View {
    @ObservedObject private var store = DictionaryStore.shared
    @State private var query = ""
    @State private var editing: SnippetTarget?

    struct SnippetTarget: Identifiable {
        var trigger: String?
        var id: String { trigger ?? "new" }
    }

    var body: some View {
        PageScroll {
            PageHeader(title: "Snippets") {
                Button { editing = SnippetTarget() } label: { Label("Add new", systemImage: "plus") }.buttonStyle(.pill)
            }
            HeroCard(before: "The stuff ", italic: "you", after: " shouldn’t have to re-type.",
                     message: "Save text you type often — an email address, an intro, a prompt — then say its trigger phrase while dictating to drop it in.") {
                Button("Add new snippet") { editing = SnippetTarget() }.buttonStyle(.pillQuiet)
            }
            SearchField(prompt: "Search snippets", text: $query)

            let snippets = store.snippets(matching: query)
            if snippets.isEmpty {
                EmptyState(title: query.isEmpty ? "No snippets yet." : "No matches",
                           detail: query.isEmpty ? "Text you save shows up here — say its trigger while dictating." : "Try a different word.")
            } else {
                TableCard {
                    ForEach(Array(snippets.enumerated()), id: \.element.trigger) { index, snippet in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        HoverRow {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("“\(snippet.trigger)”").font(Theme.sans(15))
                                Image(systemName: "arrow.right").font(.system(size: 12)).foregroundStyle(Theme.inkTertiary)
                                Text(snippet.text).font(Theme.sans(15)).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                            }
                        } actions: {
                            HStack(spacing: 6) {
                                IconButton(systemImage: "pencil", help: "Edit") { editing = SnippetTarget(trigger: snippet.trigger) }
                                IconButton(systemImage: "trash", help: "Delete") {
                                    store.update { $0.snippets[snippet.trigger] = nil }
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { target in
            SnippetEditor(original: target.trigger) { editing = nil }
        }
    }
}

private struct SnippetEditor: View {
    let original: String?
    let done: () -> Void
    @State private var trigger = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original == nil ? "Add snippet" : "Edit snippet").font(Theme.serif(26))
            VStack(alignment: .leading, spacing: 5) {
                Text("When you say").font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.inkSecondary)
                TextField("my email", text: $trigger).textFieldStyle(.plain).font(Theme.sans(15))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Insert").font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.inkSecondary)
                TextEditor(text: $text).font(Theme.sans(15)).scrollContentBackground(.hidden)
                    .padding(6).frame(height: 120)
                    .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).buttonStyle(.pillQuiet).keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(.pill).keyboardShortcut(.defaultAction)
                    .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || text.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 640)
        .background(Theme.panel)
        .onAppear {
            if let original {
                trigger = original
                text = DictionaryStore.shared.dictionary.snippets[original] ?? ""
            }
        }
    }

    private func save() {
        let key = trigger.trimmingCharacters(in: .whitespaces).lowercased()
        DictionaryStore.shared.update { d in
            if let original { d.snippets[original] = nil }
            d.snippets[key] = text
        }
        done()
    }
}
