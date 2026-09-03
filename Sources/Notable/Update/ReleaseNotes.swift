import Foundation

/// Turns a GitHub release body into something readable in a SwiftUI `Text`.
///
/// The notes arrive as Markdown. Handing them to `Text(_: String)` prints the
/// syntax itself — `### Requirements`, `- item`, `**bold**` — which reads as a
/// rendering bug rather than a release note. Neither of AppKit's two obvious
/// escapes is right either: `AttributedString(markdown:)` with
/// `.inlineOnlyPreservingWhitespace` keeps the line breaks but leaves every
/// heading and bullet marker standing, while `.full` parses the blocks and then
/// throws their structure away, running the whole document into one paragraph.
///
/// So the block level is handled here, by hand, and only the inline level is left
/// to the parser: headings lose their hashes and become bold, list markers become
/// real bullets, and everything else — emphasis, links, code — still renders.
/// Pure, so `ReleaseNotesTests` can pin it.
enum ReleaseNotes {
    /// Longest note we will render. A release body has no size limit, and an
    /// unbounded one would push the install button off the settings pane.
    static let characterLimit = 4_000

    static func attributed(_ markdown: String) -> AttributedString {
        let prepared = prepare(markdown)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        // A malformed body must not cost the user the update: fall back to the
        // plain text rather than throwing.
        return (try? AttributedString(markdown: prepared, options: options))
            ?? AttributedString(prepared)
    }

    /// Block-level cleanup, line by line. Kept separate from the parser call so
    /// the transformation is inspectable in a test without reaching into
    /// `AttributedString`.
    static func prepare(_ markdown: String) -> String {
        let truncated = markdown.count > characterLimit
            ? String(markdown.prefix(characterLimit)) + "…"
            : markdown

        var out: [String] = []
        for line in truncated.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#") {
                let text = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                // An empty heading ("###" alone) would become "****", which the
                // inline parser renders as four literal asterisks.
                out.append(text.isEmpty ? "" : "**\(text)**")
                continue
            }

            // Unordered list markers: -, * and + all mean the same thing, and a
            // bullet the user can see beats a character the parser will ignore.
            if let marker = ["- ", "* ", "+ "].first(where: { trimmed.hasPrefix($0) }) {
                out.append("• " + trimmed.dropFirst(marker.count))
                continue
            }

            // A horizontal rule has no inline equivalent; drop it rather than
            // print three dashes.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                out.append("")
                continue
            }

            out.append(trimmed)
        }

        // Collapse the runs of blank lines that dropping rules and headings leaves
        // behind, so the notes do not open with a gap.
        var collapsed: [String] = []
        for line in out {
            if line.isEmpty, collapsed.last?.isEmpty == true { continue }
            collapsed.append(line)
        }
        while collapsed.first?.isEmpty == true { collapsed.removeFirst() }
        while collapsed.last?.isEmpty == true { collapsed.removeLast() }

        return collapsed.joined(separator: "\n")
    }
}
