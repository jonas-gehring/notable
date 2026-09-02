import Foundation

/// Block kind of a single line of live meeting notes.
///
/// Deliberately flat and small: these are the structures Apple Notes offers in
/// its format menu minus the ones that make no sense here (no monospaced, no
/// nesting). Every case maps to exactly one Markdown prefix and back, which is
/// what keeps the round-trip in `NotesMarkdown` total.
enum NotesBlock: Equatable, Hashable {
    case body
    case title        // "# "
    case heading      // "## "
    case subheading   // "### "
    case bullet       // "- "
    case numbered     // "1. ", renumbered on serialize
    case checkbox(done: Bool)  // "- [ ] " / "- [x] "

    /// Whether the block carries a list marker, i.e. Return continues it.
    var isListItem: Bool {
        switch self {
        case .bullet, .numbered, .checkbox: return true
        case .body, .title, .heading, .subheading: return false
        }
    }

    /// What Return produces on the next line: the same marker for lists (an
    /// unchecked box for checkboxes — carrying the tick over would be wrong),
    /// plain body after a heading, mirroring Apple Notes.
    var continuation: NotesBlock {
        switch self {
        case .checkbox: return .checkbox(done: false)
        case .bullet, .numbered: return self
        case .body, .title, .heading, .subheading: return .body
        }
    }
}

/// One line of notes: its block kind plus the text with the marker stripped off.
struct NotesLine: Equatable {
    var block: NotesBlock
    var text: String

    init(_ block: NotesBlock = .body, _ text: String = "") {
        self.block = block
        self.text = text
    }
}

/// Markdown ⇄ block model for the live notes buffer.
///
/// The notes window renders WYSIWYG (no visible `##` or `-`), but the buffer
/// `LiveNotesController` owns stays **Markdown text** — it is mirrored into the
/// spool as `notes.md`, recovered verbatim after a crash, written verbatim into
/// `## Eigene Notizen`, and handed to the summarizer as ground truth. So the
/// conversion lives here, at the view boundary, and the storage contract is
/// unchanged. Everything in this namespace is pure and unit-tested.
///
/// The one rule that matters: **the round-trip must be total.** Any string can
/// be parsed, and `serialize(parse(x))` must be stable (idempotent) — otherwise
/// ordinary typing could corrupt notes that a model later reads as fact. The
/// tests in `NotesMarkdownTests` pin exactly that, including the awkward cases
/// (a literal "- " a user typed as a dash, numbers at line start, empty lines).
enum NotesMarkdown {
    // MARK: - Parsing

    /// Splits Markdown into lines and recognises the prefixes above. Anything
    /// unrecognised is `.body` with its text untouched — there is no such thing
    /// as invalid input here.
    static func parse(_ markdown: String) -> [NotesLine] {
        // `components(separatedBy:)` keeps trailing empties, which we want: a
        // buffer ending in "\n" has a real empty last line the caret can sit on.
        markdown.components(separatedBy: "\n").map(parseLine)
    }

    /// Order matters: the checkbox prefix starts with the bullet prefix, so it
    /// has to be tested first or every checkbox would read as a bullet.
    private static func parseLine(_ line: String) -> NotesLine {
        if let rest = line.dropPrefix("### ") { return NotesLine(.subheading, rest) }
        if let rest = line.dropPrefix("## ") { return NotesLine(.heading, rest) }
        if let rest = line.dropPrefix("# ") { return NotesLine(.title, rest) }
        if let rest = line.dropPrefix("- [ ] ") { return NotesLine(.checkbox(done: false), rest) }
        // A tick may be lower- or uppercase; both are common in the wild and we
        // normalise to "x" on the way out.
        if let rest = line.dropPrefix("- [x] ") { return NotesLine(.checkbox(done: true), rest) }
        if let rest = line.dropPrefix("- [X] ") { return NotesLine(.checkbox(done: true), rest) }
        if let rest = line.dropPrefix("- ") { return NotesLine(.bullet, rest) }
        if let rest = numberedContent(of: line) { return NotesLine(.numbered, rest) }
        return NotesLine(.body, line)
    }

    /// "1. text" / "12. text" → "text". The digits themselves are discarded:
    /// serialize renumbers each run from 1, so the stored number never drifts
    /// out of step with what the list actually shows.
    private static func numberedContent(of line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard afterDigits.hasPrefix(". ") else { return nil }
        return String(afterDigits.dropFirst(2))
    }

    // MARK: - Serialising

    /// Renders lines back to Markdown. Numbered runs are renumbered from 1, so
    /// inserting an item in the middle does not leave "1. 1. 2." behind.
    static func serialize(_ lines: [NotesLine]) -> String {
        var ordinal = 0
        return lines.map { line -> String in
            if case .numbered = line.block {
                ordinal += 1
            } else {
                ordinal = 0
            }
            return prefix(for: line.block, ordinal: ordinal) + line.text
        }
        .joined(separator: "\n")
    }

    /// The Markdown prefix for a block. `ordinal` is only read for `.numbered`.
    static func prefix(for block: NotesBlock, ordinal: Int = 1) -> String {
        switch block {
        case .body: return ""
        case .title: return "# "
        case .heading: return "## "
        case .subheading: return "### "
        case .bullet: return "- "
        case .numbered: return "\(max(1, ordinal)). "
        case .checkbox(let done): return done ? "- [x] " : "- [ ] "
        }
    }

    // MARK: - Editing operations (pure)

    /// Applies a block kind to every line the selection touches, the way a format
    /// menu does. Re-applying the kind a line already has clears it back to
    /// `.body` — the toggle behaviour Apple Notes has on its list buttons, and
    /// the only way to get out of a list with the keyboard shortcut alone.
    static func applying(_ block: NotesBlock, to lines: [NotesLine], in range: ClosedRange<Int>) -> [NotesLine] {
        let touched = range.clamped(to: 0...max(0, lines.count - 1))
        guard !lines.isEmpty else { return [NotesLine(block)] }
        // A checkbox toggled onto a line that is already a checkbox should clear
        // the block, not flip the tick — the tick is what clicking the box is for.
        let allMatch = touched.allSatisfy { index in
            switch (lines[index].block, block) {
            case (.checkbox, .checkbox): return true
            default: return lines[index].block == block
            }
        }
        var result = lines
        for index in touched {
            result[index].block = allMatch ? .body : block
        }
        return result
    }

    /// Flips the tick of a checkbox line; any other block is returned unchanged.
    static func togglingCheckbox(at index: Int, in lines: [NotesLine]) -> [NotesLine] {
        guard lines.indices.contains(index),
              case .checkbox(let done) = lines[index].block else { return lines }
        var result = lines
        result[index].block = .checkbox(done: !done)
        return result
    }
}

private extension String {
    /// `dropFirst` guarded by a prefix test, as an optional — reads better than
    /// `hasPrefix` + `dropFirst(n)` repeated seven times above.
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
