import AppKit
import SwiftUI

/// The microphone choices as Wispr Flow shows them.
@MainActor
enum MicrophoneChoice {
    /// What the dialog shows as selected for a stored preference.
    static func selectedUID(_ preference: String?) -> String {
        switch preference {
        case AudioDevices.automatic?, AudioDevices.systemDefault?: return AudioDevices.systemDefault
        case let uid?: return uid
        case nil: return AudioDevices.builtInInput?.uid ?? AudioDevices.systemDefault
        }
    }

    /// "Built-in mic (recommended)", "Auto-detect (hot pot)", "hot pot (Bluetooth)".
    static func title(for uid: String, connected: [AudioDevices.Device]) -> String {
        if uid == AudioDevices.systemDefault {
            return AudioDevices.defaultInput.map { "Auto-detect (\($0.name))" } ?? "Auto-detect"
        }
        if let device = connected.first(where: { $0.uid == uid }) { return device.displayName }
        return MicRanking.entries.first { $0.uid == uid }?.name ?? uid
    }

    /// The preference's current microphone, for the General settings row.
    static func summary(_ preference: String?) -> String {
        title(for: selectedUID(preference), connected: AudioDevices.inputs())
    }

    /// Uses `uid` for dictation and puts it first in the ranking.
    static func choose(_ uid: String) {
        let connected = AudioDevices.inputs()
        MicRanking.promote(uid, name: title(for: uid, connected: connected), connected: connected)
        DictationController.shared.microphoneUID = uid
    }
}

/// Live loudness of the chosen microphone while the dialog is open.
@MainActor
final class MicLevelMonitor: ObservableObject {
    @Published private(set) var level: Float = 0
    private var recorder: AudioRecorder?
    private var timer: Timer?

    func start() {
        stop()
        let recorder = AudioRecorder()
        recorder.keepsSamples = false
        guard (try? recorder.start()) != nil else { return }
        self.recorder = recorder
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let recorder = self.recorder else { return }
                self.level = self.level * 0.7 + recorder.level * 0.3
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        _ = recorder?.stop()
        recorder = nil
        level = 0
    }
}

/// Seven stacked segments that light up from the bottom with the level (lavender on sand).
struct VerticalLevelMeter: View {
    let level: Float
    var segments = 7

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { index in
                let lit = Float(segments - index) <= level * Float(segments) * 1.6 + 0.0001 && level > 0.02
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(lit ? Color(hex: 0xA26EC1) : Theme.buttonFill)
                    .frame(width: 18, height: 5)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

/// Settings → Microphone, like Wispr Flow's: device cards (the selected one in lavender with a live meter),
/// "Find the right mic for you →" and Edit Ranking.
struct MicrophoneDialog: View {
    let close: () -> Void
    @ObservedObject private var dictation = DictationController.shared
    @StateObject private var meter = MicLevelMonitor()
    @State private var devices: [AudioDevices.Device] = AudioDevices.inputs()
    @State private var editing = false
    @State private var ranking: [MicRanking.Entry] = []
    @State private var showVirtual = false
    @State private var quiz: MicQuiz.Step?
    @State private var dragging: MicRanking.Entry?

    private var selected: String { MicrophoneChoice.selectedUID(dictation.microphoneUID) }
    private var real: [AudioDevices.Device] { devices.filter { !$0.isVirtual } }
    private var virtual: [AudioDevices.Device] { devices.filter(\.isVirtual) }

    /// Connected microphones (and Auto-detect) in ranking order.
    private var choices: [MicRanking.Entry] {
        MicRanking.merged(with: real).filter { entry in
            entry.uid == AudioDevices.systemDefault || real.contains { $0.uid == entry.uid }
        }
    }

    var body: some View {
        ZStack {
            Theme.scrim.opacity(0.3).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 32) {
                header
                if let quiz {
                    MicQuiz(step: Binding(get: { quiz }, set: { self.quiz = $0 })) { self.quiz = nil }
                } else {
                    VStack(alignment: .trailing, spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                if editing { rankingList } else { list }
                            }
                        }
                        .frame(width: 464, height: 402)
                        footer
                    }
                }
            }
            .padding(24)
            .frame(width: 512, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.page))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            .compositingGroup()
            .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .onAppear {
            meter.start()
            ranking = MicRanking.merged(with: real)
        }
        .onDisappear { meter.stop() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            let now = AudioDevices.inputs()
            if now.map(\.uid) != devices.map(\.uid) { devices = now }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(quiz == nil ? "Microphone" : "Find the right mic").font(Theme.sans(18, .semibold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plainPointer)
                .help("Close")
            }
            if quiz == nil {
                Text("Used for dictation. Notetaker always uses Auto-detect.").font(Theme.sans(15)).foregroundStyle(Theme.inkFaint)
            }
        }
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        ForEach(choices) { entry in
            MicCard(title: MicrophoneChoice.title(for: entry.uid, connected: devices),
                    detail: detail(for: entry.uid),
                    selected: entry.uid == selected, level: meter.level) { pick(entry.uid) }
        }
        if !virtual.isEmpty {
            Button { showVirtual.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: showVirtual ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                    Text("Show other devices (\(virtual.count))")
                }
                .font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
            }
            .buttonStyle(.plainPointer)
            if showVirtual {
                ForEach(virtual) { device in
                    MicCard(title: device.displayName, detail: nil, selected: device.uid == selected, level: meter.level) { pick(device.uid) }
                }
            }
        }
    }

    private func detail(for uid: String) -> String? {
        if uid == AudioDevices.systemDefault { return "From computer settings" }
        if let device = devices.first(where: { $0.uid == uid }), device.isAirPods {
            return "AirPods may be slow to start and have more errors in dictation. We recommend the built in microphone."
        }
        return nil
    }

    private func pick(_ uid: String) {
        MicrophoneChoice.choose(uid)
        ranking = MicRanking.merged(with: real)
        meter.start()   // listen to the newly chosen mic
    }

    // MARK: Ranking

    private var rankingList: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 8) {
                ForEach(ranking) { entry in
                    let connected = entry.uid == AudioDevices.systemDefault || real.contains { $0.uid == entry.uid }
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal").font(.system(size: 12)).foregroundStyle(Theme.inkTertiary)
                        MicCard(title: MicrophoneChoice.title(for: entry.uid, connected: devices),
                                detail: entry.uid == AudioDevices.systemDefault ? "From computer settings" : nil,
                                selected: connected && entry.uid == selected, level: meter.level, compact: true) {}
                            .opacity(connected ? 1 : 0.45)
                            .overlay(alignment: .trailing) {
                                if !connected {
                                    Button {
                                        ranking.removeAll { $0.uid == entry.uid }
                                        MicRanking.entries = ranking
                                    } label: {
                                        Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                                            .frame(width: 24, height: 24).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plainPointer)
                                    .help("Forget device")
                                    .padding(.trailing, 16)
                                }
                            }
                    }
                    .contentShape(Rectangle())
                    .onDrag {
                        dragging = entry
                        return NSItemProvider(object: entry.uid as NSString)
                    }
                    .onDrop(of: [.text], delegate: RankDropDelegate(target: entry, ranking: $ranking, dragging: $dragging))
                    .pointerCursor()
                }
            }
            VStack {
                Image(systemName: "arrow.up").font(.system(size: 9, weight: .semibold))
                Spacer()
                Image(systemName: "arrow.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.inkTertiary)
            .padding(.vertical, 8)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if editing {
                Text("Drag to reorder microphone preference ranking").font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
            } else {
                Button { quiz = .desk } label: {
                    Text("Find the right mic for you →").font(Theme.sans(12)).foregroundStyle(Color(hex: 0xA26EC1))
                }
                .buttonStyle(LinkHoverStyle())
            }
            Spacer()
            Button(editing ? "Done Editing" : "Edit Ranking") {
                if editing { MicRanking.entries = ranking } else { ranking = MicRanking.merged(with: real) }
                editing.toggle()
            }
            .buttonStyle(.pillQuiet).controlSize(.small)
        }
        .padding(.top, 20)
    }
}

/// One microphone: 20-pt padding, radius 6, sand fill; lavender with a 2-pt border when selected.
private struct MicCard: View {
    let title: String
    let detail: String?
    let selected: Bool
    let level: Float
    var compact = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(Theme.sans(16, .semibold)).lineLimit(1).truncationMode(.tail)
                    if let detail {
                        Text(detail).font(Theme.sans(15)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected { VerticalLevelMeter(level: level) }
            }
            .foregroundStyle(Theme.ink)
            .padding(compact ? 16 : 20)
            .frame(maxWidth: .infinity, minHeight: compact ? 0 : 68, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? border : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .animation(.easeOut(duration: 0.2), value: selected)
    }

    private var fill: Color {
        if selected { return scheme == .dark ? Color(hex: 0x502B66) : Color(hex: 0xFCF7FF) }
        return hovering ? Theme.buttonFill : Theme.frame
    }

    private var border: Color { scheme == .dark ? Color(hex: 0xD2ACE9) : Color(hex: 0xA26EC1) }
}

private struct RankDropDelegate: DropDelegate {
    let target: MicRanking.Entry
    @Binding var ranking: [MicRanking.Entry]
    @Binding var dragging: MicRanking.Entry?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = ranking.firstIndex(of: dragging), let to = ranking.firstIndex(of: target) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            ranking.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        MicRanking.entries = ranking
        return true
    }
}

/// Underline on hover (the quiz link).
private struct LinkHoverStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { LinkBody(configuration: configuration) }

    private struct LinkBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label.underline(hovering).onHover { hovering = $0 }.pointerCursor()
        }
    }
}

// MARK: - Quiz

/// "Find the right mic for you": where you work, what you own, then a recommendation.
struct MicQuiz: View {
    enum Step { case desk, owned, result }
    enum Mic: String, CaseIterable, Identifiable {
        case dji = "DJI Mic", gooseneck = "Gooseneck Mic", headset = "Headset", podcast = "Podcast Mic"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .dji: "mic.badge.plus"
            case .gooseneck: "mic"
            case .headset: "headphones"
            case .podcast: "music.mic"
            }
        }
    }

    @Binding var step: Step?
    let done: () -> Void
    @State private var sameDesk: Bool?
    @State private var owned: Set<Mic> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch step {
            case .desk?: desk
            case .owned?: ownedStep
            default: result
            }
            HStack {
                Button { back() } label: { Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)) }
                    .buttonStyle(.pillQuiet).controlSize(.small).help("Back")
                Spacer()
                if step == .result {
                    Button("Done", action: done).buttonStyle(.pill).controlSize(.small)
                } else {
                    Button("Next") { step = step == .desk ? .owned : .result }
                        .buttonStyle(.pill).controlSize(.small)
                        .disabled(step == .desk && sameDesk == nil)
                }
            }
        }
        .frame(width: 464, height: 402 + 52, alignment: .topLeading)
    }

    private var desk: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Do you work at the same desk every day?", "Help us identify the best microphone setup for you.")
            choice("Yes", "Mostly the same desk", sameDesk == true) { sameDesk = true }
            choice("No", "I change my work location often", sameDesk == false) { sameDesk = false }
            Spacer(minLength: 0)
        }
    }

    private var ownedStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Do you own any of these?", "Select all that apply.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Mic.allCases) { mic in
                    let on = owned.contains(mic)
                    Button {
                        if on { owned.remove(mic) } else { owned.insert(mic) }
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: mic.icon).font(.system(size: 26))
                            Text(mic.rawValue).font(Theme.sans(15, .semibold))
                        }
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity).frame(height: 110)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color(hex: 0xFCF7FF) : Theme.frame))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Color(hex: 0xA26EC1) : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plainPointer)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var result: some View {
        let best: Mic = sameDesk == false ? .dji : .podcast
        let other: Mic = sameDesk == false ? .headset : .gooseneck
        let ownsBest = owned.contains(best) || owned.contains(other)
        return VStack(alignment: .leading, spacing: 16) {
            title(ownsBest ? "You've got a good setup!" : "Your ideal setup", nil)
            recommendation(best, badge: "Best option", text: description(best))
            recommendation(other, badge: "Another option", text: description(other))
            if owned == [.headset] || (owned.isEmpty && sameDesk == false) {
                Text("Wired and Bluetooth headphones aren't ideal for whispering because the mic is far from your mouth.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.inkTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func description(_ mic: Mic) -> String {
        switch mic {
        case .podcast: sameDesk == false ? "This might be hard to use when moving around." : "Podcast mics are the highest-quality option for whispering."
        case .gooseneck: sameDesk == false ? "This might be hard to use when moving around." : "Gooseneck mics are great for whispering at your desk!"
        case .headset: "Headsets with mics work well when whispering."
        case .dji: "Lav mics are great for whispering anywhere!"
        }
    }

    private func title(_ text: String, _ subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(Theme.sans(16, .semibold))
            if let subtitle { Text(subtitle).font(Theme.sans(15)).foregroundStyle(Theme.inkFaint) }
        }
    }

    private func choice(_ title: String, _ detail: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.sans(16, .semibold))
                Text(detail).font(Theme.sans(15)).foregroundStyle(Theme.inkSecondary)
            }
            .foregroundStyle(Theme.ink)
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color(hex: 0xFCF7FF) : Theme.frame))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Color(hex: 0xA26EC1) : .clear, lineWidth: 2))
        }
        .buttonStyle(.plainPointer)
    }

    private func recommendation(_ mic: Mic, badge: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: mic.icon).font(.system(size: 22)).frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.page))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(mic.rawValue).font(Theme.sans(15, .semibold))
                    Text(badge).font(Theme.sans(12, .medium)).foregroundStyle(Color(hex: 0x1A1A1A))
                        .padding(.horizontal, 8).frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xF0D7FF)))
                }
                Text(text).font(Theme.sans(15)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.frame))
    }

    private func back() {
        switch step {
        case .owned?: step = .desk
        case .result?: step = .owned
        default: done()
        }
    }
}
