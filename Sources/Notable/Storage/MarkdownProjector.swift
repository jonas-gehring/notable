import Foundation

/// Renders a meeting recording into the Markdown file that lands in the
/// user's notes folder. Pure function — the file is a projection of SQLite.
enum MarkdownProjector {
    struct Note {
        var title: String
        var date: Date
        var calendarEventTitle: String?
        /// Who was invited, from the calendar event. Separate from the speakers
        /// actually heard: an invitation is not attendance, and the note must
        /// not claim someone spoke because they were on the list.
        var attendees: [String] = []
        var segments: [(speaker: String?, text: String)]
        var summary: String?
        /// The user's own free-text notes, kept verbatim as a safety copy (and
        /// woven into the summary elsewhere). Default nil keeps notes-free
        /// rendering byte-for-byte identical.
        var userNotes: String? = nil
    }

    /// The distinct speaker labels the transcript actually carries, in the
    /// order they first speak. `"Ich"` is the local user and comes first
    /// wherever it appears at all.
    static func speakers(in note: Note) -> [String] {
        var seen: [String] = []
        for segment in note.segments {
            guard let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !speaker.isEmpty, !seen.contains(speaker) else { continue }
            seen.append(speaker)
        }
        return seen
    }

    static func render(_ note: Note) -> String {
        var lines: [String] = []

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        lines.append("---")
        lines.append("title: \"\(yamlEscaped(note.title))\"")
        lines.append("date: \(dateFormatter.string(from: note.date))")
        if let event = note.calendarEventTitle {
            lines.append("event: \"\(yamlEscaped(event))\"")
        }
        // A YAML list, so anything reading these files (Obsidian, a script) can
        // filter by person without parsing the body.
        if !note.attendees.isEmpty {
            lines.append("attendees:")
            for attendee in note.attendees {
                lines.append("  - \"\(yamlEscaped(attendee))\"")
            }
        }
        let speakers = Self.speakers(in: note)
        if !speakers.isEmpty {
            lines.append("speakers:")
            for speaker in speakers {
                lines.append("  - \"\(yamlEscaped(speaker))\"")
            }
        }
        lines.append("app: Notable")
        lines.append("---")
        lines.append("")
        lines.append("# \(note.title)")
        lines.append("")

        // Who was there, right under the title: the first question anyone asks
        // of a meeting note a week later, and it used to be answerable only by
        // reading the whole transcript for speaker labels.
        if !note.attendees.isEmpty || !speakers.isEmpty {
            lines.append("## Teilnehmer")
            lines.append("")
            if !note.attendees.isEmpty {
                lines.append("Eingeladen: " + note.attendees.joined(separator: ", "))
            }
            if !speakers.isEmpty {
                lines.append("Im Transkript: " + speakers.joined(separator: ", "))
            }
            lines.append("")
        }

        // The user's own notes come first and verbatim: they are the human
        // safety copy, and must survive even if summary/transcript are wrong.
        if let userNotes = note.userNotes {
            let trimmed = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append("## Eigene Notizen")
                lines.append("")
                lines.append(trimmed)
                lines.append("")
            }
        }

        // The summary is already a structured Markdown document produced by the
        // provider (## Zusammenfassung / ## Entscheidungen / ## Action Items, see
        // SummarizationPrompt). Insert it as-is — wrapping it under another
        // "## Zusammenfassung" duplicated that heading and mis-nested the rest.
        if let summary = note.summary, !summary.isEmpty {
            lines.append(summary)
            lines.append("")
        }

        if !note.segments.isEmpty {
            lines.append("## Transkript")
            lines.append("")
            for segment in note.segments {
                if let speaker = segment.speaker, !speaker.isEmpty {
                    lines.append("**\(speaker):** \(segment.text)")
                } else {
                    lines.append(segment.text)
                }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Backslashes first, then quotes; newlines cannot appear in single-line
    /// YAML scalars at all.
    private static func yamlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// Filesystem-safe file name: `2026-07-11 14.30 Weekly Sync.md`.
    /// The time keeps two same-titled meetings on one day from colliding.
    /// One local-time formatter — mixing ISO8601 (GMT) date with local time
    /// produced wrong dates near midnight.
    static func fileName(title: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let day = formatter.string(from: date)
        let safeTitle = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safeTitle.isEmpty ? "Aufnahme" : safeTitle
        return "\(day) \(base).md"
    }

    /// Like `fileName`, but collision-free within `directory`: if a *different*
    /// file already owns the name it appends " (2)", " (3)", … until free.
    /// `excluding` (the file being renamed/moved in place) never counts as a
    /// collision, so re-projecting a note onto its own path keeps the name.
    static func uniqueFileName(title: String, date: Date, in directory: URL, excluding: URL? = nil) -> String {
        let base = fileName(title: title, date: date)
        if !collides(directory.appendingPathComponent(base), excluding: excluding) { return base }

        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            if !collides(directory.appendingPathComponent(candidate), excluding: excluding) { return candidate }
            counter += 1
        }
    }

    /// A path collides only when something exists there that is not `excluding`.
    private static func collides(_ url: URL, excluding: URL?) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if let excluding, excluding.standardizedFileURL.path == url.standardizedFileURL.path { return false }
        return true
    }
}
