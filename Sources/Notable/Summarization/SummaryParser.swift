import Foundation

/// Splits the machine-readable `TITLE:` / `TLDR:` header lines that the
/// summarization prompt asks the model to emit off the Markdown body.
///
/// Pure and provider-independent: both `AnthropicAPIProvider` and
/// `ClaudeCodeCLIProvider` feed their raw model output through here so the
/// `Summary.markdown` they return is always the clean body, while the parsed
/// title/subtitle populate the corresponding `Summary` fields.
///
/// Deliberately tolerant — the model may omit either header, wrap them in
/// Markdown emphasis (`**TITLE:** …`), prefix a heading marker (`# TITLE: …`),
/// or drop the `---` separator. A missing header yields `nil`; if neither
/// header is present the whole (trimmed) input is returned as `markdown`.
enum SummaryParser {

    /// - Returns: the parsed `title` and `subtitle` (nil when absent or empty)
    ///   and the `markdown` body with the recognised header lines removed.
    static func parse(_ raw: String) -> (title: String?, subtitle: String?, markdown: String) {
        var title: String?
        var subtitle: String?

        let lines = raw.components(separatedBy: "\n")
        var index = 0

        // Consume a leading run of blank lines, TITLE:/TLDR: headers, and an
        // optional horizontal-rule separator that the model may place between
        // the header block and the body. Stop at the first line of real body.
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }
            if title == nil, let value = headerValue(trimmed, key: "TITLE") {
                // Consume the header line even when its value is empty (an empty
                // TITLE: stays nil but must not be mistaken for body).
                title = value.isEmpty ? nil : value
                index += 1
                continue
            }
            if subtitle == nil, let value = headerValue(trimmed, key: "TLDR") {
                subtitle = value.isEmpty ? nil : value
                index += 1
                continue
            }
            // A rule fence only counts as part of the header block once we have
            // actually seen a header — otherwise it might be real body or YAML.
            if (title != nil || subtitle != nil), isRuleFence(trimmed) {
                index += 1
                break
            }
            break
        }

        let body = lines[index...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (title, subtitle, body)
    }

    /// Returns the value of a `KEY: value` header line — an empty string when
    /// the line *is* that header but carries no value — or nil when `line` is
    /// not that header at all. Tolerates leading heading/emphasis markers and a
    /// bolded key.
    private static func headerValue(_ line: String, key: String) -> String? {
        // Drop leading Markdown noise: heading hashes, blockquote/list markers,
        // emphasis and backticks.
        var s = Substring(line)
        while let first = s.first, "#>*-_`".contains(first) || first == " " {
            s = s.dropFirst()
        }

        guard s.uppercased().hasPrefix(key) else { return nil }
        var rest = s.dropFirst(key.count)

        // Allow a bolded key like `**TITLE**:` — strip trailing emphasis/space
        // that sits between the key and the colon.
        while let first = rest.first, "*_ ".contains(first) {
            rest = rest.dropFirst()
        }
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst()

        return rest
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_`"))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isRuleFence(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, "-*_".contains(first) else { return false }
        return trimmed.count >= 3 && trimmed.allSatisfy { $0 == first }
    }
}
