import Foundation
import NaturalLanguage

/// A recognized token with its place in time — FluidAudio's `TokenTiming`,
/// reduced to what the paragraph rule needs, so that rule stays testable without
/// the framework.
struct TimedToken: Equatable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Where the speaker paused between two sentences (Spec 31 §3.5).
///
/// `ParagraphFormatter` used to break after every three sentences because no
/// engine reported word timings — or so its comment said. Parakeet does:
/// `ASRResult.tokenTimings` comes back with every whole-clip transcription and
/// was simply dropped. A breath between two sentences is the better paragraph
/// signal than a count.
///
/// The mapping is the risky part: tokens are SentencePiece pieces with "▁"
/// marking a word start, and their concatenation has to reproduce the text.
/// When it does not — a different tokenizer, post-processing inside the
/// framework, anything — the answer is nil, and the formatter counts sentences
/// as before. **Never a wrong break**, only sometimes no better one.
enum SpeechPauses {
    /// A pause at least this long between two sentences allows a paragraph.
    /// A starting value, like Spec 24's cosine threshold: measured speech has
    /// 0.2–0.5 s between sentences said in one breath.
    static let minimumGap: TimeInterval = 0.8

    /// For each boundary between two sentences of `text` — so `sentences − 1`
    /// entries — whether the speaker paused there. Nil when the tokens do not
    /// spell the text.
    static func sentenceBoundaryPauses(
        tokens: [TimedToken],
        text: String,
        minimumGap: TimeInterval = minimumGap
    ) -> [Bool]? {
        guard !tokens.isEmpty else { return nil }

        // The normalized token text, one entry per character, each remembering
        // the token it came from.
        var characters: [Character] = []
        var owner: [Int] = []
        for (index, token) in tokens.enumerated() {
            for character in token.text {
                let normalized: Character = character == "▁" || character.isWhitespace ? " " : character
                if normalized == " " {
                    if characters.isEmpty || characters.last == " " { continue }
                }
                characters.append(normalized)
                owner.append(index)
            }
        }
        while characters.last == " " {
            characters.removeLast()
            owner.removeLast()
        }

        let target = normalizedWhitespace(text)
        guard String(characters) == target, !target.isEmpty else { return nil }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = target
        var ranges: [Range<Int>] = []
        tokenizer.enumerateTokens(in: target.startIndex ..< target.endIndex) { range, _ in
            let lower = target.distance(from: target.startIndex, to: range.lowerBound)
            let upper = target.distance(from: target.startIndex, to: range.upperBound)
            ranges.append(lower ..< upper)
            return true
        }
        guard ranges.count > 1 else { return [] }

        var pauses: [Bool] = []
        for k in 0 ..< ranges.count - 1 {
            // Last visible character of this sentence, first of the next.
            var last = ranges[k].upperBound - 1
            while last > ranges[k].lowerBound, characters[last] == " " { last -= 1 }
            var first = ranges[k + 1].lowerBound
            while first < ranges[k + 1].upperBound - 1, characters[first] == " " { first += 1 }
            let before = tokens[owner[last]]
            let after = tokens[owner[first]]
            pauses.append(owner[first] > owner[last] && after.start - before.end >= minimumGap)
        }
        return pauses
    }

    static func normalizedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
