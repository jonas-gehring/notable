import XCTest
@testable import Notable

/// Spec 31 §3.5. Paragraphs at pauses — and never a break the tokens cannot
/// justify.
final class SpeechPausesTests: XCTestCase {
    /// Builds SentencePiece-shaped tokens: one per word, "▁" in front, with the
    /// given gap *before* each word.
    private func tokens(_ words: [(String, gapBefore: TimeInterval)]) -> [TimedToken] {
        var time: TimeInterval = 0
        return words.map { word, gap in
            time += gap
            let token = TimedToken(text: "▁" + word, start: time, end: time + 0.3)
            time += 0.3
            return token
        }
    }

    func testPauseBetweenSentencesIsFound() {
        let t = tokens([("Hallo", 0), ("Max.", 0.1), ("Wie", 1.2), ("geht", 0.1), ("es?", 0.1), ("Gut.", 0.2)])
        XCTAssertEqual(
            SpeechPauses.sentenceBoundaryPauses(tokens: t, text: "Hallo Max. Wie geht es? Gut."),
            [true, false]
        )
    }

    func testOneSentenceHasNoBoundaries() {
        let t = tokens([("Nur", 0), ("ein", 0.1), ("Satz.", 0.1)])
        XCTAssertEqual(SpeechPauses.sentenceBoundaryPauses(tokens: t, text: "Nur ein Satz."), [])
    }

    /// Tokens split mid-word, as SentencePiece does.
    func testSubwordPiecesMapBackToWords() {
        let t = [
            TimedToken(text: "▁Ter", start: 0, end: 0.2),
            TimedToken(text: "min", start: 0.2, end: 0.4),
            TimedToken(text: ".", start: 0.4, end: 0.45),
            TimedToken(text: "▁Da", start: 1.5, end: 1.7),
            TimedToken(text: "nach.", start: 1.7, end: 2.0),
        ]
        XCTAssertEqual(SpeechPauses.sentenceBoundaryPauses(tokens: t, text: "Termin. Danach."), [true])
    }

    /// The whole safety of the feature: if the tokens do not spell the text,
    /// there are no pauses — not approximate ones.
    func testMismatchReturnsNil() {
        let t = tokens([("Hallo", 0), ("Welt.", 0.1)])
        XCTAssertNil(SpeechPauses.sentenceBoundaryPauses(tokens: t, text: "Hallo Mond."))
        XCTAssertNil(SpeechPauses.sentenceBoundaryPauses(tokens: [], text: "Hallo."))
    }

    func testWhitespaceDifferencesAreNotAMismatch() {
        let t = tokens([("Eins.", 0), ("Zwei.", 1.0)])
        XCTAssertEqual(SpeechPauses.sentenceBoundaryPauses(tokens: t, text: "  Eins.\n Zwei. "), [true])
    }

    func testGapJustBelowTheThresholdIsNoPause() {
        let t = tokens([("Eins.", 0), ("Zwei.", 0.34)])
        XCTAssertEqual(SpeechPauses.sentenceBoundaryPauses(tokens: t, text: "Eins. Zwei."), [false])
    }

    // MARK: - Formatter

    func testFormatterBreaksAtPausesInsteadOfCounting() {
        let text = "Hallo Max. Wie geht es dir? Ich wollte fragen. Ob du Zeit hast."
        let formatted = ParagraphFormatter.format(text, options: .init(sentencePauses: [true, false, false]))
        XCTAssertEqual(formatted, "Hallo Max.\n\nWie geht es dir? Ich wollte fragen. Ob du Zeit hast.")
    }

    /// Without a pause the old count still caps a paragraph.
    func testFormatterStillCapsAParagraphWithoutPauses() {
        let text = "Eins. Zwei. Drei. Vier. Fünf."
        let formatted = ParagraphFormatter.format(text, options: .init(sentencePauses: [false, false, false, false]))
        XCTAssertEqual(formatted, "Eins. Zwei. Drei.\n\nVier. Fünf.")
    }

    /// A pause list that does not match the sentences is ignored.
    func testFormatterIgnoresPausesThatDoNotFit() {
        let text = "Eins. Zwei. Drei. Vier."
        let formatted = ParagraphFormatter.format(text, options: .init(sentencePauses: [true]))
        XCTAssertEqual(formatted, ParagraphFormatter.format(text))
    }

    /// Spoken structure splits the text into blocks; sentence indices no longer
    /// line up with the raw transcript, so pauses are not used.
    func testFormatterIgnoresPausesWhenCommandsShapedTheText() {
        let text = "Einkauf. Stichpunkt Milch. Stichpunkt Brot."
        let withPauses = ParagraphFormatter.format(text, options: .init(sentencePauses: [true, true]))
        XCTAssertEqual(withPauses, ParagraphFormatter.format(text))
    }
}
