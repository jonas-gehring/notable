import Foundation

/// Pure core of the live meeting notes — the free-text block the user types
/// *while* the call runs.
///
/// Everything here is a pure function over its arguments: no clock, no file
/// system, no UI. `LiveNotesController` owns the buffer, the crash-safe copy in
/// the spool and the elapsed-time base; this namespace only decides what text a
/// timestamp insertion produces and what survives into the note. Same split as
/// `UsageMetrics` vs. `StatsModel`, and for the same reason — the decisions are
/// unit-testable without a running meeting.
///
/// The result is fed into the existing `userNotes` path: verbatim under
/// `## Eigene Notizen` in the Markdown note (Inbox) and handed to the
/// summarizer as ground truth.
enum LiveNotes {
    /// `[04:51]` under an hour, `[1:02:33]` beyond it. Negative elapsed times
    /// (clock skew) clamp to zero rather than rendering a nonsense stamp.
    static func timestamp(elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "[%d:%02d:%02d]", hours, minutes, seconds)
        }
        return String(format: "[%02d:%02d]", minutes, seconds)
    }

    /// The exact string to splice in at the caret so a stamp always opens its own
    /// line: a leading newline only when the caret sits mid-line. At the very
    /// start of an empty buffer no newline is added, so the note never begins
    /// with a blank line.
    static func timestampInsertion(elapsed: TimeInterval, characterBeforeCaret: Character?) -> String {
        let stamp = timestamp(elapsed: elapsed) + " "
        guard let previous = characterBeforeCaret else { return stamp }
        return previous.isNewline ? stamp : "\n" + stamp
    }

    /// Character immediately before a UTF-16 offset — what `timestampInsertion`
    /// needs, in the units `NSTextView.selectedRange` reports. Offsets past the
    /// end clamp; an offset landing inside a surrogate pair yields `nil` (treated
    /// as "unknown", i.e. no leading newline is forced).
    static func character(in text: String, beforeUTF16Offset offset: Int) -> Character? {
        guard offset > 0, !text.isEmpty else { return nil }
        let utf16 = text.utf16
        let clamped = min(offset, utf16.count)
        let utf16Index = utf16.index(utf16.startIndex, offsetBy: clamped)
        guard let index = String.Index(utf16Index, within: text), index > text.startIndex else { return nil }
        return text[text.index(before: index)]
    }

    /// What is worth persisting: trimmed text, or `nil` when the user typed only
    /// whitespace. `nil` means "no user notes" everywhere downstream, which keeps
    /// the `## Eigene Notizen` section out of the Markdown entirely.
    static func storable(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
