import Foundation

/// What the notes window shows: all notes, one folder, or the dictations,
/// which have their own list and need no note column.
enum NoteScope: Hashable, Sendable {
    case all
    case folder(String)
    case dictations
}

/// The decisions behind the notes window (folders, list, note in one window),
/// kept pure so they are tested rather than looked at.
enum NoteBrowser {
    /// The notes in `scope` that match `query`, in the order given.
    ///
    /// A note matches on its title, its one-line summary or its folder, or
    /// because the full-text search found the query in its transcript:
    /// `transcriptHits` holds the recording ids `RecordingStore.search`
    /// returned for the same query. Notes written before folders existed
    /// carry no folder and live in the notes root, so they appear under
    /// "Alle Notizen" only.
    static func visible(
        _ notes: [RecordingStore.Recording],
        scope: NoteScope,
        query: String,
        transcriptHits: Set<String> = []
    ) -> [RecordingStore.Recording] {
        let inScope = notes.filter { note in
            switch scope {
            case .all:
                return true
            case .dictations:
                return false
            case let .folder(key):
                guard let folder = note.folder, !folder.isEmpty else { return false }
                if ProjectFolderName.isInbox(key) { return ProjectFolderName.isInbox(folder) }
                return folder == key
            }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return inScope }
        return inScope.filter { note in
            transcriptHits.contains(note.id)
                || [note.title, note.subtitle, note.folder]
                    .compactMap { $0?.lowercased() }
                    .contains { $0.contains(needle) }
        }
    }

    /// One block of a summary or of the user's own notes, as the detail view
    /// lays it out. The Markdown stays the truth; this only decides what is a
    /// heading, what a bullet and what plain text, because SwiftUI's own
    /// Markdown support renders inline styles and nothing else.
    enum Block: Equatable, Sendable {
        case heading(String)
        case bullet(String, level: Int)
        case paragraph(String)
    }

    static func blocks(fromMarkdown markdown: String) -> [Block] {
        markdown.components(separatedBy: .newlines).compactMap { (raw: String) -> Block? in
            let indent = raw.prefix { $0 == " " || $0 == "\t" }
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            let hashes = line.prefix { $0 == "#" }.count
            if (1 ... 6).contains(hashes), line.dropFirst(hashes).first == " " {
                let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : .heading(text)
            }
            for marker in ["- [ ] ", "- [x] ", "- ", "* ", "• "] where line.hasPrefix(marker) {
                let text = String(line.dropFirst(marker.count))
                let level = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
                let box = marker == "- [ ] " ? "☐ " : marker == "- [x] " ? "☑ " : ""
                return .bullet(box + text, level: level)
            }
            return .paragraph(line)
        }
    }

    /// Consecutive segments of one speaker, read as one turn.
    struct Turn: Equatable, Sendable {
        var speaker: String?
        var start: TimeInterval
        var text: String
    }

    static func turns(_ segments: [RecordingStore.Segment]) -> [Turn] {
        var turns: [Turn] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = turns.last, last.speaker == segment.speaker {
                turns[turns.count - 1].text += " " + text
            } else {
                turns.append(Turn(speaker: segment.speaker, start: segment.start, text: text))
            }
        }
        return turns
    }

    /// `04:51` under an hour, `1:02:33` beyond it.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = total % 3600 / 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%02d:%02d", minutes, rest)
    }
}
