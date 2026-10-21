import XCTest

/// The far side heard a second time through the microphone, taken out again
/// sentence by sentence. `EchoBleedTests` runs the same idea through the real
/// models; these pin the rules.
final class EchoFilterTests: XCTestCase {
    private func segment(_ speaker: String, _ start: TimeInterval, _ end: TimeInterval, _ text: String) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(speaker: speaker, start: start, end: end, text: text, cluster: speaker)
    }

    private let remote = "Sure, the northern region grew by eleven percent last month."

    /// The shape `EchoBleedTests` found: the VAD fused the echo with the
    /// user's own next sentence into one segment. The echo goes, the user stays.
    func testAFusedSegmentLosesTheEchoAndKeepsMySentence() {
        let result = EchoFilter.filtered([
            segment("Sprecher 1", 0, 6, remote),
            segment("Ich", 0.1, 9, remote + " That is encouraging to hear."),
        ])
        XCTAssertEqual(result.segments.map(\.text), [remote, "That is encouraging to hear."])
        XCTAssertEqual(result.removedSentences, 1)
        XCTAssertEqual(result.removedWords, 10)
    }

    /// The echo is recognised from a muffled copy, so it never matches word
    /// for word: "eleven" on one track is "11" on the other.
    func testAnEchoWithRecognitionErrorsStillGoes() {
        let result = EchoFilter.filtered([
            segment("Sprecher 1", 0, 6, remote),
            segment("Ich", 0.2, 6, "Sure the northern region grew by 11 percent last month"),
        ])
        XCTAssertEqual(result.segments.map(\.speaker), ["Sprecher 1"])
    }

    /// An answer picks up a few of the other side's words. That is not echo.
    func testMyAnswerThatRepeatsAFewWordsStays() {
        let answer = "Okay, so the budget is frozen, then we wait for Hamburg."
        let result = EchoFilter.filtered([
            segment("Sprecher 1", 0, 5, "The budget is still frozen until the workshop in Hamburg."),
            segment("Ich", 5.5, 9, answer),
        ])
        XCTAssertEqual(result.segments.last?.text, answer)
        XCTAssertEqual(result.removedSentences, 0)
    }

    /// The same sentence half a minute later is a quote, not an echo.
    func testTheSameWordsAtAnotherTimeAreNotEcho() {
        let result = EchoFilter.filtered([
            segment("Sprecher 1", 30, 36, remote),
            segment("Ich", 0, 5, remote),
        ])
        XCTAssertEqual(result.segments.count, 2)
    }

    /// "Ja, genau." on both tracks is far more often two people agreeing than
    /// an echo, so sentences under three words are never judged.
    func testShortSentencesAreNeverJudged() {
        let result = EchoFilter.filtered([
            segment("Sprecher 1", 0, 1, "Ja, genau."),
            segment("Ich", 0.5, 1.5, "Ja, genau."),
        ])
        XCTAssertEqual(result.segments.count, 2)
    }

    /// Without a system track there is nothing to compare with.
    func testWithoutTheOtherTrackNothingChanges() {
        let segments = [segment("Ich", 0, 5, remote), segment("Ich", 5, 9, remote)]
        let result = EchoFilter.filtered(segments)
        XCTAssertEqual(result.segments.map(\.text), segments.map(\.text))
        XCTAssertEqual(result.removedWords, 0)
    }

    /// Text that is kept is kept as it was, whitespace included.
    func testAnUntouchedSegmentIsByteForByteTheSame() {
        let text = "Das   sehe ich anders.\nAber gut."
        let result = EchoFilter.filtered([
            segment("Sprecher 1", 0, 5, remote),
            segment("Ich", 1, 4, text),
        ])
        XCTAssertEqual(result.segments.last?.text, text)
    }

    /// The pieces join back into the text unchanged, and a decimal stays whole.
    func testSentencesSplitAndJoinWithoutLoss() {
        let text = "Hallo. Wie geht's?\nGut… danke! 3.5 Prozent"
        let pieces = EchoFilter.sentences(text)
        XCTAssertEqual(pieces.count, 5)
        XCTAssertEqual(pieces.joined(), text)
        XCTAssertEqual(pieces.last, "3.5 Prozent")
    }

    func testWordsAndTriples() {
        XCTAssertEqual(EchoFilter.words("Okay, 11 % – it's fine."), ["okay", "11", "it", "s", "fine"])
        XCTAssertEqual(EchoFilter.triples(["a", "b", "c", "d"]), ["a b c", "b c d"])
        XCTAssertTrue(EchoFilter.triples(["a", "b"]).isEmpty)
    }
}
