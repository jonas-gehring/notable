import Foundation

/// Takes the far side's words back out of the microphone track.
///
/// Without headphones the laptop microphone hears the call from the speakers,
/// and Notable records that call a second time: once on the system track,
/// where it belongs, and once as "Ich". Measured on the benchmark of
/// 2026-10-20 (six meetings against Wispr Flow, ten more on their own): 27 to
/// 68 % of the words were such duplicates, and in the worst meeting only 26 %
/// of what stood under "Ich" had actually been said by the local user.
/// Voice processing (`meetingEchoCancellation`) would stop it in the signal,
/// but it is off by default since it cost whole meetings their mic track.
///
/// `EchoBleedTests` showed why a whole-segment dedup cannot work: the echo
/// fills the pauses of the mic track, so the VAD fuses it with the user's own
/// next sentence into one segment, and dropping that segment drops the user
/// too. This filter therefore works **per sentence**: a sentence on the mic
/// track goes when most of its word triples also appear in a system-track
/// segment around the same time. The user's own sentences rarely share half
/// their triples with the other side, even when they answer it.
///
/// Measured on the same transcripts (Python port, `scripts/benchmark`): the
/// duplicates fall to 0 to 1 %, and of every sentence removed, 99 % belonged
/// to the other side by Wispr's attribution. Sentences under three words are
/// never judged: at two words a third of the removals were the user's own
/// "Ja, genau", which the other side happened to say as well.
enum EchoFilter {
    struct Result: Sendable {
        var segments: [MeetingTranscriptSegment]
        var removedSentences = 0
        var removedWords = 0
    }

    /// Share of a sentence's word triples that must appear on the system track.
    static let coverageThreshold = 0.5
    /// How far apart in time the two tracks' segments may lie and still count
    /// as the same moment. The echo itself lags by milliseconds; the slack is
    /// for the two tracks being cut into groups at different points.
    static let timeTolerance: TimeInterval = 2
    /// Shorter sentences are kept, whatever they share.
    static let minimumWords = 3

    /// - Parameter microphoneLabel: the label the mic track carries at this
    ///   point. The filter runs inside the pipeline, before anything is named.
    static func filtered(
        _ segments: [MeetingTranscriptSegment],
        microphoneLabel: String = SpeakerNameResolver.micSpeakerLabel
    ) -> Result {
        let remote = segments
            .filter { $0.speaker != microphoneLabel }
            .map { (start: $0.start, end: $0.end, triples: triples(words($0.text))) }
        guard !remote.isEmpty else { return Result(segments: segments) }

        var result = Result(segments: [])
        for segment in segments {
            guard segment.speaker == microphoneLabel else {
                result.segments.append(segment)
                continue
            }
            let heard = remote
                .filter { $0.start <= segment.end + timeTolerance && $0.end >= segment.start - timeTolerance }
                .reduce(into: Set<String>()) { $0.formUnion($1.triples) }
            guard !heard.isEmpty else {
                result.segments.append(segment)
                continue
            }

            var kept = ""
            var removed = false
            for sentence in sentences(segment.text) {
                let sentenceWords = words(sentence)
                if sentenceWords.count >= minimumWords, coverage(of: sentenceWords, in: heard) >= coverageThreshold {
                    result.removedSentences += 1
                    result.removedWords += sentenceWords.count
                    removed = true
                } else {
                    kept += sentence
                }
            }
            guard removed else {
                result.segments.append(segment)
                continue
            }
            let text = kept.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var trimmed = segment
            trimmed.text = text
            result.segments.append(trimmed)
        }
        return result
    }

    // MARK: - Pure helpers, shared with `MeetingLanguageGuard`

    /// Lowercased runs of letters and digits. "11 %" is "11", "it's" is "it"
    /// and "s". Crude, and the same on both tracks, which is all it needs.
    static func words(_ text: some StringProtocol) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    static func triples(_ words: [String]) -> Set<String> {
        guard words.count >= 3 else { return [] }
        return Set((0...(words.count - 3)).map { words[$0..<($0 + 3)].joined(separator: " ") })
    }

    static func coverage(of words: [String], in heard: Set<String>) -> Double {
        let own = triples(words)
        guard !own.isEmpty else { return 0 }
        return Double(own.intersection(heard).count) / Double(own.count)
    }

    private static let terminators: Set<Character> = [".", "!", "?", "…"]

    /// The text cut after `.`, `!`, `?` or `…` followed by whitespace, and at
    /// every line break. Each piece keeps its punctuation and the whitespace
    /// after it, so joining the pieces gives the text back unchanged. "3.5"
    /// stays whole; "z. B." is cut, which costs nothing here.
    static func sentences(_ text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let ends = character.isNewline
                || (terminators.contains(character) && (next == text.endIndex || text[next].isWhitespace))
            guard ends else {
                index = next
                continue
            }
            var end = next
            while end < text.endIndex, text[end].isWhitespace {
                end = text.index(after: end)
            }
            result.append(text[start..<end])
            start = end
            index = end
        }
        if start < text.endIndex {
            result.append(text[start...])
        }
        return result
    }
}
