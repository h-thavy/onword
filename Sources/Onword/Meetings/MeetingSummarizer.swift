import Foundation
import OnwordCore
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Meeting notes written by Apple's on-device language model (macOS 26, Apple Intelligence).
/// Free and private: no API key, nothing leaves the Mac. The model's context is ~4k tokens, so long
/// transcripts are summarized in parts first ("map"), then the part notes are combined ("reduce").
@MainActor
final class MeetingSummarizer: ObservableObject {
    static let shared = MeetingSummarizer()

    @Published private(set) var working: Set<UUID> = []
    @Published private(set) var progress: [UUID: String] = [:]

    private let log = Logger(subsystem: "io.github.h-thavy.onword", category: "summary")

    /// Characters of transcript per model call; leaves room for instructions and the answer.
    private let chunkCharacters = 6000

    /// Why summaries can't run, or nil when they can.
    var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in System Settings to get meeting summaries."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is still downloading its model. Try again later."
            case .unavailable(.deviceNotEligible):
                return "This Mac doesn't support Apple Intelligence, which writes the summaries."
            case .unavailable:
                return "Apple Intelligence isn't available right now."
            }
        }
        #endif
        return "Meeting summaries need macOS 26 with Apple Intelligence."
    }

    func summarize(_ id: UUID) {
        guard unavailableReason == nil, !working.contains(id),
              let meeting = MeetingStore.shared.meeting(id), !meeting.segments.isEmpty else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            working.insert(id)
            let lines = TranscriptText.lines(meeting.segments, name: meeting.name(for:))
            let checkLines = meeting.segments.map { ActionItemCheck.Line(speaker: meeting.name(for: $0.speaker), text: $0.text) }
            Task {
                defer {
                    working.remove(id)
                    progress[id] = nil
                }
                do {
                    var notes = try await generate(lines: lines) { [weak self] message in self?.progress[id] = message }
                    // Keep only to-dos the transcript actually supports.
                    let proposed = notes.actionItems.count
                    notes.actionItems = notes.actionItems.filter {
                        ActionItemCheck.isGrounded(quote: $0.quote, owner: $0.owner, lines: checkLines)
                    }
                    log.notice("Action items: \(notes.actionItems.count) kept, \(proposed - notes.actionItems.count) dropped as unsupported")
                    MeetingStore.shared.update(id) { m in
                        m.summary = notes.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                        m.decisions = notes.decisions.filter { !$0.isEmpty }
                        m.todos = notes.actionItems.filter { !$0.task.isEmpty }.map {
                            MeetingTodo(task: $0.task, owner: $0.owner.nilIfBlank, due: $0.due.nilIfBlank)
                        }
                        m.summaryError = nil
                    }
                    log.notice("Summary written")
                } catch {
                    log.error("Summary failed: \(error.localizedDescription)")
                    MeetingStore.shared.update(id) { $0.summaryError = Self.describe(error) }
                }
            }
        }
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private func generate(lines: [String], progress: @escaping (String) -> Void) async throws -> GeneratedNotes {
        let chunks = TranscriptText.chunks(lines, maxCharacters: chunkCharacters)
        if chunks.count == 1 {
            progress("Writing summary…")
            return try await respond(Self.finalPrompt(source: "Transcript", text: chunks[0]))
        }

        // Map: notes for each part of a long meeting.
        var points: [String] = []
        var items: [GeneratedTodo] = []
        for (index, chunk) in chunks.enumerated() {
            progress("Reading part \(index + 1) of \(chunks.count)…")
            let part: PartNotes = try await respond(
                "Take notes on this part (\(index + 1) of \(chunks.count)) of a meeting transcript.\n\n" + chunk)
            points += part.keyPoints
            items += part.actionItems
        }

        // Reduce: combine the part notes (squeezed again if they're still too long).
        progress("Writing summary…")
        var notesText = points.map { "- " + $0 }.joined(separator: "\n")
        if notesText.count > chunkCharacters { notesText = String(notesText.prefix(chunkCharacters)) }
        var final: GeneratedNotes = try await respond(Self.finalPrompt(source: "Notes taken during the meeting", text: notesText))
        if final.actionItems.isEmpty { final.actionItems = items }
        return final
    }

    @available(macOS 26, *)
    private func respond<T: Generable>(_ prompt: String) async throws -> T {
        let session = LanguageModelSession(instructions: Self.instructions)
        return try await session.respond(to: prompt, generating: T.self).content
    }

    private static let instructions = """
        You write short, factual meeting notes from a transcript. Refer to people by the names used in the \
        transcript. Only include what was actually said; never invent decisions, owners or dates. If an \
        action item has no clear owner or due date, leave that field empty.
        """

    private static func finalPrompt(source: String, text: String) -> String {
        "Write the meeting notes.\n\n\(source):\n\(text)"
    }

    @available(macOS 26, *)
    private static func describe(_ error: Error) -> String {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation: return "Apple Intelligence declined to summarize this transcript."
            case .exceededContextWindowSize: return "This transcript part was too long for the on-device model."
            default: break
            }
        }
        return error.localizedDescription
    }
    #endif
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct GeneratedNotes {
    @Guide(description: "Two to four sentences: what the meeting was about and what was concluded.")
    var summary: String
    @Guide(description: "Decisions that were agreed on. Empty if none.")
    var decisions: [String]
    @Guide(description: "Concrete tasks someone committed to do. Empty if none.")
    var actionItems: [GeneratedTodo]
}

@available(macOS 26, *)
@Generable
struct GeneratedTodo {
    @Guide(description: "The task, starting with a verb.")
    var task: String
    @Guide(description: "Name of the person who will do it, or empty if not stated.")
    var owner: String
    @Guide(description: "When it is due, as said in the meeting, or empty if not stated.")
    var due: String
    @Guide(description: "The exact words from the transcript where someone commits to or is asked to do this task.")
    var quote: String
}

@available(macOS 26, *)
@Generable
struct PartNotes {
    @Guide(description: "The important points in this part, one short sentence each, with names.")
    var keyPoints: [String]
    @Guide(description: "Tasks someone committed to in this part. Empty if none.")
    var actionItems: [GeneratedTodo]
}
#endif

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
