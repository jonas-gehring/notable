import AppKit

/// Renders the notes buffer as formatted text and reads it back out.
///
/// The notes window shows no Markdown: a heading is simply bigger, a bullet is a
/// real "•", a checkbox a tickable "☐". The buffer behind it stays Markdown —
/// see `NotesMarkdown` for why that matters — so this is the translation layer
/// between the two, and the only place that knows what the formatting *looks*
/// like.
///
/// **Where the block kind lives.** For lists the visible marker *is* the truth:
/// a paragraph beginning "•\t" is a bullet, full stop. That makes the mapping
/// robust against the user editing the line, and it means deleting the marker
/// genuinely turns the line back into body text, which is what anyone would
/// expect. Only headings have nothing visible to key off, so they carry the
/// `.notesBlock` attribute. Keeping that attribute the *sole* piece of hidden
/// state is deliberate — hidden state that can drift out of sync with the text
/// is exactly how WYSIWYG editors start mangling documents.
@MainActor
enum NotesRichText {
    // MARK: - Fonts and spacing

    static let bodySize: CGFloat = 13

    /// Visible marker for a list block, including the tab the hanging indent
    /// aligns to. Empty for everything that has no marker.
    static func marker(for block: NotesBlock, ordinal: Int = 1) -> String {
        switch block {
        case .bullet: return "•\t"
        case .numbered: return "\(max(1, ordinal)).\t"
        case .checkbox(let done): return done ? "☑\t" : "☐\t"
        case .body, .title, .heading, .subheading: return ""
        }
    }

    static func font(for block: NotesBlock) -> NSFont {
        switch block {
        case .title: return .systemFont(ofSize: bodySize + 7, weight: .bold)
        case .heading: return .systemFont(ofSize: bodySize + 3, weight: .semibold)
        case .subheading: return .systemFont(ofSize: bodySize + 1, weight: .semibold)
        case .body, .bullet, .numbered, .checkbox: return .systemFont(ofSize: bodySize)
        }
    }

    /// Hanging indent for list items so wrapped lines line up under the text and
    /// not under the marker; a little air above headings so sections breathe.
    static func paragraphStyle(for block: NotesBlock) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        if block.isListItem {
            let indent: CGFloat = 18
            style.headIndent = indent
            style.firstLineHeadIndent = 0
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            style.paragraphSpacing = 2
        }
        switch block {
        case .title, .heading, .subheading:
            style.paragraphSpacingBefore = 8
            style.paragraphSpacing = 3
        default:
            break
        }
        style.lineSpacing = 1.5
        return style
    }

    static func attributes(for block: NotesBlock) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: block),
            .paragraphStyle: paragraphStyle(for: block),
            .foregroundColor: NSColor.labelColor,
        ]
        // Only headings need the hidden marker; see the type comment.
        if let code = block.headingCode {
            attributes[.notesBlock] = code
        }
        return attributes
    }

    // MARK: - Markdown → formatted text

    static func attributed(markdown: String) -> NSAttributedString {
        let lines = NotesMarkdown.parse(markdown)
        let result = NSMutableAttributedString()
        var ordinal = 0
        for (index, line) in lines.enumerated() {
            if case .numbered = line.block { ordinal += 1 } else { ordinal = 0 }
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let rendered = marker(for: line.block, ordinal: ordinal) + line.text
            result.append(NSAttributedString(string: rendered, attributes: attributes(for: line.block)))
        }
        return result
    }

    // MARK: - Formatted text → Markdown

    /// Reads the editor back out as Markdown. Total by construction: anything
    /// that does not carry a recognised marker or heading attribute is body text.
    static func markdown(from attributed: NSAttributedString) -> String {
        NotesMarkdown.serialize(lines(from: attributed))
    }

    static func lines(from attributed: NSAttributedString) -> [NotesLine] {
        let text = attributed.string
        let paragraphs = text.components(separatedBy: "\n")
        var location = 0
        return paragraphs.map { paragraph in
            defer { location += paragraph.utf16.count + 1 }
            let heading = headingBlock(in: attributed, at: location)
            return line(from: paragraph, headingHint: heading)
        }
    }

    /// The heading attribute of the paragraph starting at `location`, if any.
    private static func headingBlock(in attributed: NSAttributedString, at location: Int) -> NotesBlock? {
        guard location < attributed.length else { return nil }
        let raw = attributed.attribute(.notesBlock, at: location, effectiveRange: nil) as? Int
        return raw.flatMap(NotesBlock.init(headingCode:))
    }

    /// Splits one rendered paragraph into its block kind and its text. The marker
    /// wins; the heading hint only applies to a paragraph that carries no marker.
    static func line(from paragraph: String, headingHint: NotesBlock?) -> NotesLine {
        if paragraph.hasPrefix("☐\t") { return NotesLine(.checkbox(done: false), String(paragraph.dropFirst(2))) }
        if paragraph.hasPrefix("☑\t") { return NotesLine(.checkbox(done: true), String(paragraph.dropFirst(2))) }
        if paragraph.hasPrefix("•\t") { return NotesLine(.bullet, String(paragraph.dropFirst(2))) }
        if let rest = numberedContent(of: paragraph) { return NotesLine(.numbered, rest) }
        return NotesLine(headingHint ?? .body, paragraph)
    }

    /// "3.\ttext" → "text". Mirrors `NotesMarkdown`'s digit limit so a year at
    /// the start of a line is not mistaken for a list marker.
    private static func numberedContent(of paragraph: String) -> String? {
        let digits = paragraph.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = paragraph.dropFirst(digits.count)
        guard afterDigits.hasPrefix(".\t") else { return nil }
        return String(afterDigits.dropFirst(2))
    }

    // MARK: - Caret mapping

    /// Which paragraph a UTF-16 offset in the *rendered* text falls in, and how
    /// far into that paragraph's **content** (i.e. past the marker) it sits.
    /// Re-rendering after a format change moves every offset, so the caret has to
    /// be expressed in terms that survive it.
    static func position(in attributed: NSAttributedString, utf16Offset offset: Int) -> (paragraph: Int, column: Int) {
        let paragraphs = attributed.string.components(separatedBy: "\n")
        var remaining = max(0, min(offset, attributed.string.utf16.count))
        for (index, paragraph) in paragraphs.enumerated() {
            let length = paragraph.utf16.count
            if remaining <= length {
                let markerLength = markerLength(of: paragraph)
                return (index, max(0, remaining - markerLength))
            }
            remaining -= length + 1
        }
        return (max(0, paragraphs.count - 1), 0)
    }

    /// Inverse of `position`: where that paragraph/column lands after rendering.
    static func utf16Offset(in attributed: NSAttributedString, paragraph: Int, column: Int) -> Int {
        let paragraphs = attributed.string.components(separatedBy: "\n")
        guard !paragraphs.isEmpty else { return 0 }
        let target = min(max(0, paragraph), paragraphs.count - 1)
        var offset = 0
        for index in 0..<target {
            offset += paragraphs[index].utf16.count + 1
        }
        let markerLength = markerLength(of: paragraphs[target])
        let contentLength = paragraphs[target].utf16.count - markerLength
        return offset + markerLength + min(max(0, column), max(0, contentLength))
    }

    /// UTF-16 offset at which a paragraph begins in the rendered text. The click
    /// handler needs this exactly: `position(_:).column` is clamped to 0 for any
    /// caret inside the marker, so it cannot be used to recover the start.
    static func paragraphStartOffset(in attributed: NSAttributedString, paragraph: Int) -> Int {
        let paragraphs = attributed.string.components(separatedBy: "\n")
        guard !paragraphs.isEmpty else { return 0 }
        let target = min(max(0, paragraph), paragraphs.count - 1)
        var offset = 0
        for index in 0..<target {
            offset += paragraphs[index].utf16.count + 1
        }
        return offset
    }

    /// UTF-16 length of the visible marker at the start of a rendered paragraph.
    static func markerLength(of paragraph: String) -> Int {
        if paragraph.hasPrefix("☐\t") || paragraph.hasPrefix("☑\t") || paragraph.hasPrefix("•\t") { return 2 }
        if numberedContent(of: paragraph) != nil {
            return paragraph.prefix(while: \.isNumber).count + 2
        }
        return 0
    }
}

// MARK: - The one hidden attribute

extension NSAttributedString.Key {
    /// Heading level of a paragraph. Lists key off their visible marker instead;
    /// see `NotesRichText`'s type comment for why this is the only hidden state.
    static let notesBlock = NSAttributedString.Key("de.jonasgehring.notable.notesBlock")
}

private extension NotesBlock {
    /// Stable code for the three heading levels; `nil` for everything that is
    /// recognisable from its visible marker.
    var headingCode: Int? {
        switch self {
        case .title: return 1
        case .heading: return 2
        case .subheading: return 3
        case .body, .bullet, .numbered, .checkbox: return nil
        }
    }

    init?(headingCode code: Int) {
        switch code {
        case 1: self = .title
        case 2: self = .heading
        case 3: self = .subheading
        default: return nil
        }
    }
}
