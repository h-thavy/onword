import Foundation
import OnwordCore

/// A recorded meeting. Stored as Meetings/<id>/meeting.json next to its two audio tracks:
/// mic.caf (you) and system.caf (everyone else, via the process tap).
struct Meeting: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case recording, processing, ready, failed
    }

    var id = UUID()
    var title: String
    var startedAt = Date()
    var duration: Double = 0
    var status: Status = .recording
    var statusDetail: String?
    var hasSystemAudio = false
    /// Speaker key → display name. Keys: "me" for the microphone, "s1", "s2"… from diarization.
    var speakerNames: [String: String] = [:]
    var segments: [TranscriptSegment] = []
    /// Your own notes, typed or dictated during/after the meeting.
    var notes = ""
    /// Call app the meeting was on, if one was detected (MeetingPlatform raw value).
    var platform: String?
    /// Names read from the call app's participant tiles.
    var participants: [String]?
    /// From the calendar event this meeting was recorded for.
    var calendarEventID: String?
    var attendees: [String]?
    /// Notes written by the on-device model after the meeting.
    var summary: String?
    var decisions: [String]?
    var todos: [MeetingTodo]?
    var summaryError: String?

    var folder: URL { AppPaths.meetings.appendingPathComponent(id.uuidString, isDirectory: true) }
    var micURL: URL { folder.appendingPathComponent("mic.caf") }
    var systemURL: URL { folder.appendingPathComponent("system.caf") }
    /// Active-speaker observations from the call app (JSON lines of `SpeakerObservation`).
    var speakersURL: URL { folder.appendingPathComponent("speakers.jsonl") }

    func name(for speaker: String) -> String {
        if speaker == "me" {
            // You follow the name in Settings, unless you renamed yourself in this meeting.
            let stored = speakerNames[speaker]
            if stored == nil || stored == "Me" { return UserProfile.name ?? "Me" }
            return stored!
        }
        return speakerNames[speaker] ?? speaker.uppercased()
    }

    /// Speakers in order of first appearance.
    var speakers: [String] {
        var seen = Set<String>()
        return segments.map(\.speaker).filter { seen.insert($0).inserted }
    }

    var markdown: String {
        var md = TranscriptExporter.markdown(title: title, date: startedAt, segments: segments,
                                             speakerNames: Dictionary(uniqueKeysWithValues: speakers.map { ($0, name(for: $0)) }),
                                             summary: summary)
        var extra = ""
        if let decisions, !decisions.isEmpty {
            extra += "## Decisions\n\n" + decisions.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if let todos, !todos.isEmpty {
            extra += "## Action items\n\n" + todos.map(\.markdown).joined(separator: "\n") + "\n\n"
        }
        if !extra.isEmpty, let range = md.range(of: "## Transcript") { md.insert(contentsOf: extra, at: range.lowerBound) }
        if !notes.isEmpty { md += "## Notes\n\n\(notes)\n" }
        return md
    }

    static func defaultTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM, HH:mm"
        return "Meeting – \(f.string(from: date))"
    }
}

/// An action item from a meeting's notes.
struct MeetingTodo: Codable, Identifiable, Equatable {
    var id = UUID()
    var task: String
    var owner: String?
    var due: String?
    var done = false

    var markdown: String {
        var line = "- [\(done ? "x" : " ")] \(task)"
        let details = [owner, due.map { "due \($0)" }].compactMap { $0 }
        if !details.isEmpty { line += " (\(details.joined(separator: ", ")))" }
        return line
    }
}

@MainActor
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    @Published private(set) var meetings: [Meeting] = []

    private init() { reload() }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: AppPaths.meetings, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded: [Meeting] = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")) else { return nil }
            return try? decoder.decode(Meeting.self, from: data)
        }
        meetings = loaded.map { (meeting: Meeting) -> Meeting in
            // A meeting still marked "recording" after a relaunch was cut off by a quit or crash.
            var m = meeting
            if m.status == .recording && MeetingRecorder.shared.currentID != m.id {
                m.status = .failed
                m.statusDetail = "Recording was interrupted. Use Re-process to transcribe the audio that was saved."
            }
            return m
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    func save(_ meeting: Meeting) {
        try? FileManager.default.createDirectory(at: meeting.folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(meeting) {
            try? data.write(to: meeting.folder.appendingPathComponent("meeting.json"), options: .atomic)
        }
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
    }

    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard var meeting = meeting(id) else { return }
        change(&meeting)
        save(meeting)
    }

    func delete(_ id: UUID) {
        guard let meeting = meeting(id) else { return }
        try? FileManager.default.removeItem(at: meeting.folder)
        meetings.removeAll { $0.id == id }
    }
}
