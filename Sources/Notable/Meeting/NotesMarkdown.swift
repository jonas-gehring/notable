import Foundation

/// Block kind of a single line of live meeting notes.
///
/// Deliberately small: these are the structures Apple Notes offers in its
/// format menu minus the ones that make no sense here (no monospaced). Every
/// case maps to exactly one Markdown prefix and back, which is what keeps the
/// round-trip in `NotesMarkdown` total. Nesting is not a block kind but a level
/// on the line (`NotesLine.indent`), and only list items have one.
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

/// One line of notes: its block kind, its nesting level, and the text with the
/// marker stripped off.
struct NotesLine: Equatable {
    var block: NotesBlock
    var text: String
    /// Nesting level, `0...NotesMarkdown.maxIndent` (Spec 26). Only list items
    /// carry one: four spaces before a paragraph are a code block in Markdown,
    /// which would change what the line *means* to the model and to Obsidian.
    /// `NotesMarkdown.normalized` enforces that, and the one-step rule.
    var indent: Int

    init(_ block: NotesBlock = .body, _ text: String = "", indent: Int = 0) {
        self.block = block
        self.text = text
        self.indent = indent
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
    /// Six levels, 0…5 — as deep as anyone nests notes typed during a call.
    static let maxIndent = 5

    // MARK: - Parsing

    /// Splits Markdown into lines and recognises the prefixes above. Anything
    /// unrecognised is `.body` with its text untouched — there is no such thing
    /// as invalid input here.
    ///
    /// Nesting is read the CommonMark way: a list item is the child of the open
    /// item above it when its marker starts at or past that item's **content
    /// column** (two spaces under "- ", three under "1. ", four under "10. ").
    /// A stack of open items and their content columns decides the level; the
    /// result is normalised, so what comes out is always expressible again.
    static func parse(_ markdown: String) -> [NotesLine] {
        // `components(separatedBy:)` keeps trailing empties, which we want: a
        // buffer ending in "\n" has a real empty last line the caret can sit on.
        var open: [Int] = []  // content column of each open list item, outermost first
        let lines = markdown.components(separatedBy: "\n").map { raw -> NotesLine in
            let (column, rest) = leadingColumns(of: raw)
            if let item = listItem(rest) {
                while let top = open.last, column < top { open.removeLast() }
                let level = open.count
                open.append(column + item.markerWidth)
                return NotesLine(item.block, item.text, indent: level)
            }
            open.removeAll()
            return parseUnindented(raw)
        }
        return normalized(lines)
    }

    /// Order matters: the checkbox prefix starts with the bullet prefix, so it
    /// has to be tested first or every checkbox would read as a bullet.
    /// Headings count only at the very start of a line; an indented "## " is
    /// body text, exactly as before nesting existed.
    private static func parseUnindented(_ line: String) -> NotesLine {
        if let rest = line.dropPrefix("### ") { return NotesLine(.subheading, rest) }
        if let rest = line.dropPrefix("## ") { return NotesLine(.heading, rest) }
        if let rest = line.dropPrefix("# ") { return NotesLine(.title, rest) }
        return NotesLine(.body, line)
    }

    /// A list marker at the start of `line` (leading whitespace already
    /// removed): the block, the width the marker adds to the content column,
    /// and the text after it. For a checkbox the list marker is "- " — the box
    /// is part of the content in CommonMark, so children sit two columns in.
    private static func listItem(_ line: Substring) -> (block: NotesBlock, markerWidth: Int, text: String)? {
        // A tick may be lower- or uppercase; both are common in the wild and we
        // normalise to "x" on the way out.
        if let rest = line.dropPrefix("- [ ] ") { return (.checkbox(done: false), 2, rest) }
        if let rest = line.dropPrefix("- [x] ") { return (.checkbox(done: true), 2, rest) }
        if let rest = line.dropPrefix("- [X] ") { return (.checkbox(done: true), 2, rest) }
        if let rest = line.dropPrefix("- ") { return (.bullet, 2, rest) }
        if let numbered = numberedContent(of: line) { return (.numbered, numbered.digits + 2, numbered.text) }
        return nil
    }

    /// Leading whitespace as a column count — a tab advances to the next
    /// multiple of four, as in CommonMark — and what follows it.
    private static func leadingColumns(of line: String) -> (Int, Substring) {
        var column = 0
        var index = line.startIndex
        while index < line.endIndex {
            switch line[index] {
            case " ": column += 1
            case "\t": column += 4 - column % 4
            default: return (column, line[index...])
            }
            index = line.index(after: index)
        }
        return (column, line[index...])
    }

    // MARK: - Normalising

    /// The one place the nesting rules live; `parse` and every editing
    /// operation end here.
    ///
    /// - body text and headings are always level 0;
    /// - the first list item after anything else (or at the start) is level 0;
    /// - a list item is at most one level deeper than the list item before it.
    ///
    /// Markdown cannot express a jump of two levels with nothing in between, so
    /// this makes the model exactly as expressive as the format — which is what
    /// makes the round-trip total.
    static func normalized(_ lines: [NotesLine]) -> [NotesLine] {
        var previous: Int?  // level of the list item directly above, if any
        return lines.map { line in
            var line = line
            if line.block.isListItem {
                let ceiling = previous.map { $0 + 1 } ?? 0
                line.indent = min(max(0, line.indent), ceiling, maxIndent)
                previous = line.indent
            } else {
                line.indent = 0
                previous = nil
            }
            return line
        }
    }

    /// "1. text" / "12. text" → (digit count, "text"). The digits themselves are
    /// discarded: serialize renumbers each run from 1, so the stored number
    /// never drifts out of step with what the list actually shows.
    private static func numberedContent(of line: Substring) -> (digits: Int, text: String)? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard afterDigits.hasPrefix(". ") else { return nil }
        return (digits.count, String(afterDigits.dropFirst(2)))
    }

    // MARK: - Serialising

    /// Renders lines back to Markdown. Numbered runs are renumbered from 1, so
    /// inserting an item in the middle does not leave "1. 1. 2." behind. A
    /// child is indented to its parent's content column, computed from the
    /// parent's **actual** prefix — a fixed width would be wrong under "10. ".
    static func serialize(_ lines: [NotesLine]) -> String {
        let lines = normalized(lines)
        let numbers = ordinals(lines)
        var contentColumns: [Int] = []  // per open level
        return lines.indices.map { index -> String in
            let line = lines[index]
            guard line.block.isListItem else {
                contentColumns.removeAll()
                return prefix(for: line.block) + line.text
            }
            let indentColumn = line.indent == 0 ? 0 : contentColumns[line.indent - 1]
            let marker = prefix(for: line.block, ordinal: numbers[index])
            contentColumns.removeSubrange(min(line.indent, contentColumns.count)...)
            contentColumns.append(indentColumn + listMarkerWidth(line.block, marker: marker))
            return String(repeating: " ", count: indentColumn) + marker + line.text
        }
        .joined(separator: "\n")
    }

    /// How far a marker moves the content column. The checkbox's list marker is
    /// "- "; the "[ ] " after it belongs to the content, as in CommonMark.
    private static func listMarkerWidth(_ block: NotesBlock, marker: String) -> Int {
        if case .checkbox = block { return 2 }
        return marker.count
    }

    /// The number each line shows — 0 for anything that is not a numbered item.
    ///
    /// Counted per level: a shallower item ends every deeper run, a deeper one
    /// leaves the shallower count standing, and a sibling that is not numbered
    /// restarts the count. So a bulleted sub-point between "1." and "2." no
    /// longer restarts the outer list. `NotesRichText` renders with this too, so
    /// the window and the Markdown never disagree about a number.
    static func ordinals(_ lines: [NotesLine]) -> [Int] {
        var counters: [Int] = []  // per level: the last number shown there, 0 = not numbered
        return lines.map { line in
            guard line.block.isListItem else {
                counters.removeAll()
                return 0
            }
            let level = min(line.indent, counters.count)
            counters.removeSubrange(min(level + 1, counters.count)...)
            let previous = level < counters.count ? counters[level] : 0
            let number: Int
            if case .numbered = line.block { number = previous + 1 } else { number = 0 }
            if level < counters.count { counters[level] = number } else { counters.append(number) }
            return number
        }
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
        // List → list keeps its level; anything else goes back to 0.
        return normalized(result)
    }

    /// Tab / ⌘]: every **list item** the selection touches goes one level
    /// deeper; body text in the selection is left alone. Children do not move
    /// along (as in Apple Notes and Google Docs) — only the selection does.
    static func indenting(_ lines: [NotesLine], in range: ClosedRange<Int>) -> [NotesLine] {
        shifting(lines, in: range, by: 1)
    }

    /// ⇧Tab / ⌘[: the mirror image. Children of an outdented item that end up
    /// two levels below it are pulled up by the normalisation — deterministic,
    /// and pinned in the tests.
    static func outdenting(_ lines: [NotesLine], in range: ClosedRange<Int>) -> [NotesLine] {
        shifting(lines, in: range, by: -1)
    }

    /// Return on an **empty** list item: a nested one moves up a level, a
    /// top-level one leaves the list. So a second Return always gets you out.
    static func leavingEmptyItem(at index: Int, in lines: [NotesLine]) -> [NotesLine] {
        stepOut(at: index, in: lines)
    }

    /// Backspace at the start of a formatted line: a nested list item moves up
    /// a level first; anything else loses its format (the Apple Notes rule).
    static func backspacingAtLineStart(at index: Int, in lines: [NotesLine]) -> [NotesLine] {
        stepOut(at: index, in: lines)
    }

    private static func stepOut(at index: Int, in lines: [NotesLine]) -> [NotesLine] {
        var result = normalized(lines)
        guard result.indices.contains(index) else { return result }
        if result[index].block.isListItem, result[index].indent > 0 {
            result[index].indent -= 1
        } else {
            result[index].block = .body
        }
        return normalized(result)
    }

    private static func shifting(_ lines: [NotesLine], in range: ClosedRange<Int>, by delta: Int) -> [NotesLine] {
        guard !lines.isEmpty else { return lines }
        var result = lines
        for index in range.clamped(to: 0...(lines.count - 1)) where result[index].block.isListItem {
            result[index].indent += delta
        }
        return normalized(result)
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

private extension StringProtocol {
    /// `dropFirst` guarded by a prefix test, as an optional — reads better than
    /// `hasPrefix` + `dropFirst(n)` repeated seven times above.
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
