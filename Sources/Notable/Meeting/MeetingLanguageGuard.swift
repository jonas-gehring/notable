import Foundation

/// One language per meeting, instead of one guess per snippet.
///
/// Parakeet v3 decides the language of every slice on its own, and a short
/// slice of German speech often comes back as English: "Yeah, okay.", "See the
/// home.", "Mocus of the cursor and condenling." Measured on the benchmark of
/// 2026-10-20, 4 to 25 % of the segments in German meetings were such English
/// strays. They are short (the longer the slice, the surer the model), so
/// that is where this looks, and only there.
///
/// The meeting's language is counted from function words over the whole
/// transcript. In a German meeting a short segment first has its English
/// fillers turned German ("Yeah" is what Parakeet makes of "Ja" and "Jo"), and
/// whatever is then still plainly English (English function words, no German
/// one, no umlaut, no capitalised noun mid-sentence) is dropped. Measured on
/// the sixteen benchmark notes: at most 0.4 % of a meeting's words go, and
/// every dropped segment was garbage or a stray "What?".
///
/// English meetings are left alone. The strays run in one direction only: in
/// the English interviews of the benchmark the only German segment was a real
/// aside, and dropping it would have lost it.
enum MeetingLanguageGuard {
    enum Language: String, Sendable {
        case german
        case english
    }

    struct Result: Sendable {
        var segments: [MeetingTranscriptSegment]
        var language: Language?
        var dropped = 0
        var droppedWords = 0
        var rewritten = 0
    }

    /// Only segments up to this many words are judged.
    static let shortSegmentWords = 6
    /// Below this many function words in total, the meeting has no language.
    static let minimumFunctionWords = 20

    /// Words that are frequent in one language and rare in the other. "so",
    /// "was", "in", "also" and "will" are missing on purpose: they are words in
    /// both.
    static let germanWords: Set<String> = [
        "der", "die", "das", "und", "ist", "sind", "ich", "wir", "es", "nicht", "ein", "eine",
        "zu", "von", "mit", "auch", "auf", "für", "dann", "ja", "halt", "mal", "noch", "aber",
        "wie", "wenn", "dass", "sie", "du", "den", "dem", "genau", "oder", "schon", "jetzt",
        "hier", "nee", "nein",
    ]
    static let englishWords: Set<String> = [
        "the", "and", "is", "are", "you", "we", "i", "it", "this", "that", "to", "of", "on",
        "for", "with", "be", "have", "yeah", "but", "what", "about", "they", "my", "your", "our",
        "just", "like", "can", "would", "do",
    ]
    /// Fillers whose English form is Parakeet's reading of a German one.
    /// "Okay" is both and stays; "no" is left alone because "No, I deployed
    /// it" is not a German "Nö".
    static let englishFillers: [String: String] = [
        "yeah": "ja", "yep": "ja", "yup": "ja", "mm-hmm": "mhm", "uh-huh": "mhm",
    ]

    static func guarded(_ segments: [MeetingTranscriptSegment]) -> Result {
        let detected = language(of: segments)
        guard detected == .german else { return Result(segments: segments, language: detected) }

        var result = Result(segments: [], language: detected)
        for segment in segments {
            let words = EchoFilter.words(segment.text)
            guard words.count <= shortSegmentWords else {
                result.segments.append(segment)
                continue
            }
            var current = segment
            let text = rewritingFillers(segment.text)
            if text != segment.text {
                current.text = text
                result.rewritten += 1
            }
            let count = counts(text)
            if count.english > 0, count.german == 0, !hasGermanEvidence(text) {
                result.dropped += 1
                result.droppedWords += words.count
                continue
            }
            result.segments.append(current)
        }
        return result
    }

    /// German or English when one side has at least `minimumFunctionWords`
    /// and twice as many as the other; nil otherwise.
    static func language(of segments: [MeetingTranscriptSegment]) -> Language? {
        let total = segments.reduce(into: (german: 0, english: 0)) { sum, segment in
            let count = counts(segment.text)
            sum.german += count.german
            sum.english += count.english
        }
        if total.german >= minimumFunctionWords, total.german >= 2 * total.english { return .german }
        if total.english >= minimumFunctionWords, total.english >= 2 * total.german { return .english }
        return nil
    }

    static func counts(_ text: String) -> (german: Int, english: Int) {
        EchoFilter.words(text).reduce(into: (german: 0, english: 0)) { count, word in
            if germanWords.contains(word) { count.german += 1 }
            if englishWords.contains(word) { count.english += 1 }
        }
    }

    /// "Yeah, klar. Yeah." → "Ja, klar. Ja." A capital stays a capital.
    static func rewritingFillers(_ text: String) -> String {
        var result = ""
        var token = ""
        func flush() {
            if let replacement = englishFillers[token.lowercased()] {
                result += token.first?.isUppercase == true
                    ? String(replacement.prefix(1)).uppercased() + String(replacement.dropFirst())
                    : replacement
            } else {
                result += token
            }
            token = ""
        }
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character.isLetter || character.isNumber {
                token.append(character)
            } else if character == "-", !token.isEmpty, next < text.endIndex, text[next].isLetter {
                // "mm-hmm" is one word; "Ja - nein" is two.
                token.append(character)
            } else {
                flush()
                result.append(character)
            }
            index = next
        }
        flush()
        return result
    }

    /// Anything that says this short "English" segment is German after all: an
    /// umlaut or ß, or a capitalised word that does not start a sentence.
    /// German capitalises its nouns, English only its names and "I".
    static func hasGermanEvidence(_ text: String) -> Bool {
        if text.contains(where: { "äöüßÄÖÜ".contains($0) }) { return true }
        var startsSentence = true
        for token in text.split(whereSeparator: \.isWhitespace) {
            let letters = token.drop(while: { !$0.isLetter }).prefix(while: \.isLetter)
            if !startsSentence, letters.first?.isUppercase == true, letters != "I" {
                return true
            }
            startsSentence = token.last.map { ".!?…:".contains($0) } ?? false
        }
        return false
    }
}
