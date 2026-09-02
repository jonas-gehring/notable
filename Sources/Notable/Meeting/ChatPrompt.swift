import Foundation

/// Who authored a chat turn. Mirrors the persisted `chat_messages.role` values.
enum ChatRole: String, Sendable {
    case user
    case assistant
}

/// One prior message in the ongoing chat, serialized into the user prompt as a
/// `Frage:`/`Antwort:` block (the `complete` API is a single system+user
/// round-trip, so history has to live inside the user text).
struct ChatTurn: Sendable {
    let role: ChatRole
    let text: String
}

/// A pure, storage-independent view of one transcript segment — deliberately
/// not `RecordingStore`'s row type, so `ChatPrompt` stays testable in isolation.
struct ChatTranscriptSegment: Sendable {
    /// "Ich" / "Sprecher n"; nil when unknown.
    let speaker: String?
    /// Segment start in seconds from meeting start (used for approximate position).
    let start: TimeInterval
    let text: String
}

/// Everything the chat prompt needs about the one open meeting.
struct ChatContext: Sendable {
    let meetingTitle: String?
    let date: Date
    let segments: [ChatTranscriptSegment]
    /// The user's own notes — a higher-trust block the model should prefer.
    let userNotes: String?
    /// One-shot meeting summary, used only as an overview in the context-window
    /// fallback when the full transcript is too large.
    let summary: String?
}

/// Provider-independent prompt for "chat over one meeting transcript".
/// Pure: no clock access, no storage — the app feeds it a `ChatContext`,
/// the prior turns and the new question, and hands the result to
/// `SummarizationProvider.complete(system:user:)`. Only transcript text ever
/// leaves the device.
enum ChatPrompt {
    static let system = """
    Du beantwortest Fragen zu EINEM Meeting ausschließlich auf Basis des \
    mitgelieferten Transkripts (und der eigenen Notizen des Nutzers, falls \
    vorhanden). Antworte auf Deutsch, knapp und präzise. Wenn die Antwort nicht \
    im Transkript steht, sage das klar statt zu raten. Nenne, wenn hilfreich, \
    Sprecher ("Ich", "Sprecher n") und ungefähre Stelle. Erfinde nichts.
    """

    /// Builds the user message: meeting header, transcript (full or, above the
    /// character threshold, a summary + keyword-relevant excerpt), the user's
    /// own notes, the prior conversation, and finally the new question.
    static func user(
        context: ChatContext,
        history: [ChatTurn],
        question: String,
        maxTranscriptChars: Int = 120_000
    ) -> String {
        var header = "Meeting"
        if let title = context.meetingTitle, !title.isEmpty {
            header += ": \(title)"
        }
        header += " am \(context.date.formatted(date: .long, time: .shortened))"

        let fullTranscript = render(context.segments)

        var body = header + "\n\n"

        if fullTranscript.count > maxTranscriptChars {
            // Context-window fallback: the whole transcript would blow the
            // budget, so we ship an overview plus only the segments around
            // keyword hits. Clearly marked so the model knows it is partial.
            body += "Transkript (AUSZUG — das vollständige Transkript ist zu lang, "
                + "enthalten sind nur eine Übersicht und die zur Frage relevanten "
                + "Abschnitte):\n\n"
            if let summary = context.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                body += "Übersicht (Zusammenfassung des gesamten Meetings):\n\n"
                    + summary + "\n\n"
            }
            let picked = relevantSegments(context.segments, for: question)
            body += "Relevante Transkript-Abschnitte:\n\n" + render(picked)
        } else {
            body += "Transkript:\n\n" + fullTranscript
        }

        // The user's own notes: a clearly labelled, higher-trust block.
        if let notes = context.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines),
           !notes.isEmpty {
            body += "\n\nEigene Notizen des Nutzers (verlässlichste Quelle — bei "
                + "Widersprüchen zum Transkript bevorzugen):\n\n" + notes
        }

        // Prior conversation, serialized as alternating Frage:/Antwort: blocks.
        if !history.isEmpty {
            body += "\n\nBisheriger Gesprächsverlauf:\n"
            for turn in history {
                let label = turn.role == .user ? "Frage" : "Antwort"
                body += "\n\(label): \(turn.text)"
            }
        }

        body += "\n\nNeue Frage:\n\n" + question
        return body
    }

    /// Keyword-relevant window used by the context fallback: every segment whose
    /// text contains a significant word (length >= 4, case-insensitive) from the
    /// question, plus `neighbours` segments on each side of every hit,
    /// de-duplicated and returned in chronological (input) order.
    static func relevantSegments(
        _ segments: [ChatTranscriptSegment],
        for question: String,
        neighbours: Int = 1
    ) -> [ChatTranscriptSegment] {
        let keywords = significantWords(question)
        guard !keywords.isEmpty else { return [] }

        var keep = Set<Int>()
        for (index, segment) in segments.enumerated() {
            let haystack = segment.text.lowercased()
            guard keywords.contains(where: { haystack.contains($0) }) else { continue }
            let lower = max(0, index - neighbours)
            let upper = min(segments.count - 1, index + neighbours)
            for i in lower...upper { keep.insert(i) }
        }
        return keep.sorted().map { segments[$0] }
    }

    // MARK: - Helpers

    /// Lowercased, de-duplicated question words of length >= 4.
    private static func significantWords(_ question: String) -> Set<String> {
        let parts = question.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(parts.map(String.init).filter { $0.count >= 4 })
    }

    /// Renders segments to one line each: `[mm:ss Sprecher] Text`.
    private static func render(_ segments: [ChatTranscriptSegment]) -> String {
        segments.map { segment in
            let speaker = segment.speaker?.isEmpty == false ? segment.speaker! : "?"
            return "[\(timestamp(segment.start)) \(speaker)] \(segment.text)"
        }.joined(separator: "\n")
    }

    /// `mm:ss` position label (approximate; clamps negatives to zero).
    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
