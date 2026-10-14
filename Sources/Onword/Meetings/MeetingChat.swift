import Foundation
import OnwordCore
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

/// "Ask anything", answered on this Mac by Apple Intelligence: about one meeting (the Notepad's chat and
/// quick prompts) or across your recent meetings (the Hub's Ask bar). Wispr Flow does this on its servers;
/// here nothing leaves the Mac.
@MainActor
final class MeetingChat: ObservableObject {
    static let shared = MeetingChat()

    /// Meetings (or `hubID` for the Hub's chat) with an answer being written.
    @Published private(set) var answering: Set<UUID> = []
    /// The Hub's conversation (not saved).
    @Published private(set) var hubMessages: [ChatMessage] = []
    static let hubID = UUID(uuidString: "00000000-0000-0000-0000-00000000A5C0")!

    /// Where "What did I miss?" last caught you up to, per meeting (transcript line count).
    private var caughtUp: [UUID: Int] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "chat")

    static let livePrompts = ["What did I miss?", "Make me sound smart", "Suggest questions"]
    static let afterPrompts = ["Write a follow-up email", "Make notes longer", "Identify blind spots"]
    static let hubPrompts = ["Coach me", "List recent todos", "Write a weekly recap"]

    var unavailableReason: String? { MeetingSummarizer.shared.unavailableReason }

    // MARK: - One meeting

    func ask(_ question: String, about id: UUID) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !answering.contains(id), let meeting = MeetingStore.shared.meeting(id) else { return }
        MeetingStore.shared.update(id) { $0.chat = ($0.chat ?? []) + [ChatMessage(role: .user, text: question)] }

        let lines = transcriptLines(meeting)
        if question == "What did I miss?" {
            let from = caughtUp[id] ?? 0
            caughtUp[id] = lines.count
            if lines.count <= from {
                appendAnswer("Nothing new since you last looked.", to: id)
                return
            }
            let recent = Array(lines[max(from, lines.count - 80)...])
            run(id: id, prompt: Self.missedPrompt(recent: recent, meeting: meeting)) { _ in }
            return
        }
        let context = Self.context(for: meeting, lines: lines)
        let prompt = Self.prompt(for: question, context: context)
        run(id: id, prompt: prompt) { answer in
            // Drafts become Docs, as Wispr's chat artifacts do.
            if question == "Write a follow-up email" {
                MeetingStore.shared.update(id) {
                    $0.docs = ($0.docs ?? []) + [MeetingDoc(title: "Follow-up email", body: answer)]
                }
            }
        }
    }

    func stop(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        answering.remove(id)
    }

    func clear(_ id: UUID) {
        stop(id)
        if id == Self.hubID { hubMessages = [] } else { MeetingStore.shared.update(id) { $0.chat = [] } }
    }

    // MARK: - Across meetings (Hub)

    func askHub(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !answering.contains(Self.hubID) else { return }
        hubMessages.append(ChatMessage(role: .user, text: question))
        let recent = MeetingStore.shared.meetings.filter { $0.status == .ready }.prefix(12)
        var context = ""
        for m in recent {
            var block = "## \(m.displayTitle) (\(m.startedAt.formatted(date: .abbreviated, time: .shortened)))\n"
            if let summary = m.summary { block += summary + "\n" }
            let todos = m.activeTodos.map { "- [\($0.done ? "x" : " ")] \($0.task)\($0.owner.map { " (\($0))" } ?? "")" }
            if !todos.isEmpty { block += "Action items:\n" + todos.joined(separator: "\n") + "\n" }
            if m.summary == nil { block += TranscriptText.lines(m.segments, name: m.name(for:)).prefix(20).joined(separator: "\n") + "\n" }
            if context.count + block.count > 7000 { break }
            context += block + "\n"
        }
        let instruction: String
        switch question {
        case "Coach me": instruction = "Give the user two or three specific, kind suggestions to run better meetings, based on these meetings."
        case "List recent todos": instruction = "List the open action items from these meetings as a checklist, grouped by meeting."
        case "Write a weekly recap": instruction = "Write a short recap of the week from these meetings: highlights, decisions, and what's next."
        default: instruction = question
        }
        let prompt = "My recent meetings:\n\n\(context.isEmpty ? "(none yet)" : context)\n\nRequest: \(instruction)"
        run(id: Self.hubID, prompt: prompt) { _ in }
    }

    // MARK: - Model

    private func run(id: UUID, prompt: String, done: @escaping (String) -> Void) {
        if let reason = unavailableReason {
            appendAnswer(reason, to: id)
            return
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            answering.insert(id)
            appendAnswer("", to: id)
            tasks[id] = Task {
                defer {
                    answering.remove(id)
                    tasks[id] = nil
                }
                do {
                    let session = LanguageModelSession(instructions: Self.instructions)
                    var latest = ""
                    for try await partial in session.streamResponse(to: prompt) {
                        latest = partial.content
                        replaceLastAnswer(latest, in: id)
                    }
                    done(latest)
                } catch is CancellationError {
                } catch {
                    log.error("Chat failed: \(error.localizedDescription)")
                    replaceLastAnswer("Couldn't answer: \(error.localizedDescription)", in: id)
                }
            }
        }
        #endif
    }

    private func appendAnswer(_ text: String, to id: UUID) {
        let message = ChatMessage(role: .assistant, text: text)
        if id == Self.hubID { hubMessages.append(message) } else { MeetingStore.shared.update(id) { $0.chat = ($0.chat ?? []) + [message] } }
    }

    private func replaceLastAnswer(_ text: String, in id: UUID) {
        if id == Self.hubID {
            if let i = hubMessages.lastIndex(where: { $0.role == .assistant }) { hubMessages[i].text = text }
        } else {
            MeetingStore.shared.update(id) { m in
                if let i = m.chat?.lastIndex(where: { $0.role == .assistant }) { m.chat?[i].text = text }
            }
        }
    }

    // MARK: - Prompts

    private static let instructions = """
        You help someone during and after their meetings. Answer from the meeting material you're given; \
        in transcripts, the words are a more reliable signal than the speaker labels. If something isn't in \
        the material, say so. Keep answers under 250 words, plain and direct, using short lists where they help.
        """

    private func transcriptLines(_ meeting: Meeting) -> [String] {
        if meeting.status == .recording, MeetingRecorder.shared.currentID == meeting.id {
            let previous = TranscriptText.lines(meeting.segments, name: meeting.name(for:))
            return previous + MeetingRecorder.shared.liveSegments.map { "\($0.speaker == "me" ? "You" : "Them"): \($0.text)" }
        }
        return TranscriptText.lines(meeting.segments, name: meeting.name(for:))
    }

    private static func context(for meeting: Meeting, lines: [String]) -> String {
        var text = "Meeting: \(meeting.displayTitle)\n"
        let people = (meeting.attendees ?? []) + (meeting.participants ?? [])
        if !people.isEmpty { text += "Participants: \(people.joined(separator: ", "))\n" }
        let folders = FolderStore.shared.folders(of: meeting).map(\.name)
        if !folders.isEmpty { text += "Filed in folders: \(folders.joined(separator: ", "))\n" }
        if !meeting.notes.isEmpty { text += "\nMy notes:\n\(meeting.notes.prefix(2000))\n" }
        if let summary = meeting.summary { text += "\nSummary:\n\(summary)\n" }
        // The most recent part of the transcript that fits.
        var transcript = ""
        for line in lines.reversed() {
            if transcript.count + line.count > 6000 { break }
            transcript = line + "\n" + transcript
        }
        if !transcript.isEmpty { text += "\nTranscript:\n\(transcript)" }
        return text
    }

    private static func missedPrompt(recent: [String], meeting: Meeting) -> String {
        "Recent part of the meeting \"\(meeting.displayTitle)\":\n\(recent.joined(separator: "\n"))\n\n"
            + "Speak from the user's side: in a few bullet points, catch me up on what I missed."
    }

    private static func prompt(for question: String, context: String) -> String {
        let request: String
        switch question {
        case "Make me sound smart": request = "Suggest one or two thoughtful things I could say next in this meeting, in my voice."
        case "Suggest questions": request = "Suggest three good questions I could ask next, based on the conversation."
        case "Write a follow-up email": request = "Write a short follow-up email to the participants: thanks, key decisions, next steps with owners."
        case "Make notes longer": request = "Expand my notes into fuller meeting notes using the transcript. Keep my structure."
        case "Identify blind spots": request = "Point out risks, open questions or things nobody addressed in this meeting."
        default: request = question
        }
        return "\(context)\n\nRequest: \(request)"
    }
}
