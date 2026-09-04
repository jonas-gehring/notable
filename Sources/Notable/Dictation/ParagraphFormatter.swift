import Foundation
import NaturalLanguage

/// Gives a dictation its shape back: paragraphs at sentence boundaries, and the
/// structure the user actually *spoke* ("neue Zeile", "Stichpunkt",
/// "erstens … zweitens").
///
/// `TextPolisher.tidy` collapses every whitespace run to a single space, so a
/// 90-second dictation arrives in the target field as one endless line. This
/// runs at the very *end* of `polish()`, after `tidy` — which is why `tidy`
/// itself stays a plain whitespace-collapsing function and needs no change.
///
/// **Deliberately not done here: breaking at speech pauses.** That is the better
/// signal, but the dictation path has no timings — `TranscriptionEngine.transcribe`
/// returns a bare `String` for all three engines. Faking a pause from sentence
/// counts alone would be a guess dressed up as a measurement, so the pause rule
/// waits for real word timings and this type ships the counting fallback.
///
/// Pure and unit-tested (`ParagraphFormatterTests`). Never reached in verbatim
/// mode: `polish()` returns before `tidy` there, and a code/terminal dictation
/// must receive exactly what was said.
enum ParagraphFormatter {
    struct Options: Sendable {
        /// Group sentences into paragraphs. Off for chat (one line stays one line).
        var paragraphs = true
        /// Sentences per paragraph when no spoken command says otherwise.
        var sentencesPerParagraph = 3
        /// Honour spoken structure commands ("neue Zeile", "Stichpunkt", …).
        var structureCommands = true
    }

    static func format(_ text: String, options: Options = Options()) -> String {
        guard !text.isEmpty else { return text }

        // Line breaks already in the text become markers first. Without this the
        // sentence grouping would join them away with a space, and formatting an
        // already-formatted text would flatten it — `format(format(x))` has to
        // equal `format(x)`, because a second polish pass is not a rewrite.
        var marked = markingExistingBreaks(in: text)
        if options.structureCommands {
            marked = applyingCommands(to: marked)
        }
        return render(marked, options: options)
    }

    /// Line breaks the text already carried become *kept* markers — a distinct kind
    /// from the ones a spoken command produces. The difference is casing: a command
    /// break leaves a lowercase word behind because the phrase was cut out of the
    /// middle of a sentence, so that word wants capitalizing. A break that was
    /// already there came from the user's own text (a smart-replace expansion is the
    /// only source) and is already exactly as they wrote it — capitalizing it would
    /// turn a mail address on its own line into "Max.mustermann@…".
    private static func markingExistingBreaks(in text: String) -> String {
        text
            .replacingOccurrences(of: "\\n[ \\t]*\\n[\\s]*", with: Break.keptParagraph.token, options: .regularExpression)
            .replacingOccurrences(of: "\\n[ \\t]*", with: Break.keptLine.token, options: .regularExpression)
    }

    // MARK: - Spoken commands

    /// Private sentinels. A dictation cannot contain a NUL, so a marker can never
    /// collide with transcribed text, and the paragraph pass can tell an explicit
    /// break (spoken) from one it is free to insert itself.
    private static let marker = "\u{0}"
    private enum Break: String {
        case line = "L"
        case paragraph = "P"
        case bullet = "B"
        /// Breaks the text already carried (lowercase kinds): same layout, but the
        /// following word is left alone.
        case keptLine = "l"
        case keptParagraph = "p"

        var token: String { marker + rawValue }
    }

    /// German and English phrases, longest first so "neuer Absatz" wins over a
    /// prefix match and "bullet point" over "bullet".
    private static let commandPhrases: [(phrases: [String], kind: Break)] = [
        (["neuer absatz", "neuen absatz", "new paragraph"], .paragraph),
        (["neue zeile", "nächste zeile", "new line", "next line"], .line),
        (["neuer stichpunkt", "bullet point", "aufzählungspunkt", "stichpunkt", "aufzählung"], .bullet),
    ]

    private static let ordinals: [String] = [
        "erstens", "zweitens", "drittens", "viertens", "fünftens",
        "sechstens", "siebtens", "achtens", "neuntens", "zehntens",
    ]

    private static func applyingCommands(to text: String) -> String {
        var result = text
        // To a fixpoint, because one regex pass is not enough: a match consumes
        // the punctuation that follows the command, which is exactly the context
        // the *next* command needs ("Neuer Absatz. Neuer Absatz." would keep the
        // second one as prose). Each pass strictly shortens the string — a marker
        // is two characters, every phrase is longer — so this terminates; the cap
        // is a belt on top of those braces.
        for _ in 0 ..< 5 {
            let before = result
            for (phrases, kind) in commandPhrases {
                for phrase in phrases {
                    result = replacingCommand(phrase, with: kind.token, in: result)
                }
            }
            if result == before { break }
        }
        return applyingOrdinalList(to: result)
    }

    /// Replaces a spoken command with its marker.
    ///
    /// The command must **start an utterance** — text start, or right after
    /// sentence punctuation. That guard is the whole reason this is safe:
    /// "Aufzählung" and "neue Zeile" are ordinary German words, and without it
    /// "das ist eine Aufzählung von Dingen" would lose a noun mid-sentence.
    /// Said as a command ("… fertig, Stichpunkt, Milch kaufen") the phrase
    /// always follows punctuation, so the useful case is kept.
    private static func replacingCommand(_ phrase: String, with token: String, in text: String) -> String {
        return text.replacingOccurrences(
            of: commandPattern(for: phrase),
            with: "$1" + NSRegularExpression.escapedTemplate(for: token),
            options: .regularExpression
        )
    }

    /// A command starts an utterance: at text start, after sentence punctuation —
    /// or after a marker already placed, so "Neuer Absatz. Neuer Absatz." does not
    /// leave the second one sitting in the text as prose.
    private static func commandPattern(for phrase: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let context = "^|[.,;:!?]|\u{0}[LPBlp]|\u{0}N[0-9]{1,2}"
        return "(?iu)(\(context))[ ]*\(escaped)[ ]*[.,;:!?]?[ ]*"
    }

    /// Turns "erstens … zweitens … drittens" into a numbered list.
    ///
    /// Requires **at least two** ordinals: a single "erstens" is ordinary prose
    /// ("Erstens war das falsch") and deleting it would change the sentence.
    /// Two in ascending order is someone enumerating out loud.
    private static func applyingOrdinalList(to text: String) -> String {
        let present = ordinals.enumerated().compactMap { rank, word -> (rank: Int, word: String, at: String.Index)? in
            guard let range = text.range(of: commandPattern(for: word), options: .regularExpression) else { return nil }
            return (rank, word, range.lowerBound)
        }
        guard present.count >= 2 else { return text }

        // Ascending **in the text** — "zweitens … erstens" is someone talking,
        // not someone enumerating. Comparing the ordinals' own order here would
        // be vacuous: `ordinals` is sorted by construction.
        let spokenOrder = present.sorted { $0.at < $1.at }
        guard spokenOrder.map(\.rank) == present.map(\.rank) else { return text }

        var result = text
        for (position, entry) in spokenOrder.enumerated() {
            result = replacingCommand(entry.word, with: marker + "N\(position + 1)", in: result)
        }
        return result
    }

    // MARK: - Rendering

    /// One block of the finished document, and how it attaches to the one before.
    private struct Block {
        enum Attachment {
            /// First block — nothing precedes it.
            case first
            /// "neue Zeile": a plain line break, no blank line.
            case line
            /// "neuer Absatz": a blank line.
            case paragraph
            /// A spoken list item. Packs tight against another item, but keeps a
            /// blank line to the prose above it.
            case listItem
        }

        var text: String
        var attachment: Attachment
        /// A list item renders with its marker and is never regrouped into
        /// paragraphs — the user already said where it starts.
        var prefix: String?
        /// False for text that arrived with its own line break: it is already
        /// written the way the user wants it.
        var capitalize: Bool = true
    }

    private static func render(_ marked: String, options: Options) -> String {
        var rendered: [(line: String, attachment: Block.Attachment)] = []

        for block in split(marked) {
            let raw = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }

            // A break the speaker asked for starts a new sentence visually, so it
            // should read like one: the ASR wrote the word lowercase only because
            // it was mid-sentence before the command was taken out.
            let body = block.attachment == .first || !block.capitalize ? raw : capitalizingFirstWord(raw)

            if let prefix = block.prefix {
                rendered.append((prefix + body, block.attachment))
            } else if options.paragraphs, !isListItem(body) {
                let parts = paragraphs(of: body, per: options.sentencesPerParagraph)
                for (index, part) in parts.enumerated() {
                    // Only the first part inherits the spoken attachment; the
                    // breaks this type inserts itself are always paragraphs.
                    rendered.append((part, index == 0 ? block.attachment : .paragraph))
                }
            } else {
                rendered.append((body, block.attachment))
            }
        }

        return join(rendered)
    }

    /// Splits at the markers, carrying each block's attachment and list prefix.
    private static func split(_ marked: String) -> [Block] {
        var blocks: [Block] = []
        var current = Block(text: "", attachment: .first, prefix: nil)
        var index = marked.startIndex

        while index < marked.endIndex {
            guard marked[index] == "\u{0}" else {
                current.text.append(marked[index])
                index = marked.index(after: index)
                continue
            }
            let kindIndex = marked.index(after: index)
            guard kindIndex < marked.endIndex else { break }

            blocks.append(current)
            var next = Block(text: "", attachment: .line, prefix: nil)
            index = marked.index(after: kindIndex)

            switch marked[kindIndex] {
            case "B":
                next.attachment = .listItem
                next.prefix = "- "
            case "N":
                // Digits follow the N (1…10).
                var digits = ""
                while index < marked.endIndex, marked[index].isNumber {
                    digits.append(marked[index])
                    index = marked.index(after: index)
                }
                next.attachment = .listItem
                next.prefix = digits.isEmpty ? "- " : "\(digits). "
            case "P":
                next.attachment = .paragraph
            case "p":
                next.attachment = .paragraph
                next.capitalize = false
            case "l":
                next.capitalize = false
            default:
                next.attachment = .line
            }
            current = next
        }
        blocks.append(current)
        return blocks
    }

    /// Groups a prose block's sentences into paragraphs of `count`.
    private static func paragraphs(of text: String, per count: Int) -> [String] {
        guard count > 0 else { return [text] }
        let sentences = self.sentences(in: text)
        guard sentences.count > count else { return [text] }

        return stride(from: 0, to: sentences.count, by: count).map { start in
            sentences[start ..< min(start + count, sentences.count)]
                .joined(separator: " ")
        }
    }

    /// Sentence split via `NLTokenizer` — it knows German abbreviations
    /// ("z. B.") that a naive split on ". " would tear apart.
    private static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            return true
        }
        return result
    }

    /// Capitalizes a list item's first word, but only when that word is entirely
    /// lowercase — "iPhone" and "macOS" must survive a bullet unharmed.
    ///
    /// The rule itself lives in `TextPolisher`, which needs exactly the same one
    /// for the start of a dictation; having it twice is how the two drifted
    /// apart in the first place.
    private static func capitalizingFirstWord(_ text: String) -> String {
        TextPolisher.capitalizingFirstWord(text)
    }

    /// Joins by attachment: blank line between paragraphs, single newline for a
    /// spoken "neue Zeile" and between consecutive list items. Empty blocks were
    /// already dropped, so a run of commands can never leave a run of blank lines.
    private static func join(_ rendered: [(line: String, attachment: Block.Attachment)]) -> String {
        var out = ""
        for (index, entry) in rendered.enumerated() {
            if index > 0 {
                switch entry.attachment {
                case .first, .paragraph:
                    out += "\n\n"
                case .line:
                    out += "\n"
                case .listItem:
                    // Tight against another item, but set off from prose above.
                    out += isListItem(rendered[index - 1].line) ? "\n" : "\n\n"
                }
            }
            out += entry.line
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isListItem(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.range(of: "^\\d+\\. ", options: .regularExpression) != nil
    }
}
