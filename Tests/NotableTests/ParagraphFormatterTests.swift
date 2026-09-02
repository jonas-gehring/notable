import XCTest
@testable import Notable

/// Issue #1 Stufe 1. The formatter is the last thing that touches dictated text
/// before it is pasted into someone else's app, so the tests care as much about
/// what it leaves alone as about what it changes.
final class ParagraphFormatterTests: XCTestCase {
    private func format(
        _ text: String,
        paragraphs: Bool = true,
        commands: Bool = true,
        per sentences: Int = 3
    ) -> String {
        ParagraphFormatter.format(text, options: .init(
            paragraphs: paragraphs,
            sentencesPerParagraph: sentences,
            structureCommands: commands
        ))
    }

    // MARK: - Paragraphs

    func testShortTextIsUntouched() {
        let text = "Das ist ein Satz. Und noch einer."
        XCTAssertEqual(format(text), text)
    }

    func testBreaksAfterEveryThreeSentences() {
        let text = "Eins ist da. Zwei ist da. Drei ist da. Vier ist da. Fünf ist da."
        XCTAssertEqual(
            format(text),
            """
            Eins ist da. Zwei ist da. Drei ist da.

            Vier ist da. Fünf ist da.
            """
        )
    }

    func testNeverBreaksInsideASentence() {
        let text = (1...7).map { "Satz Nummer \($0) läuft hier." }.joined(separator: " ")
        for paragraph in format(text).components(separatedBy: "\n\n") {
            XCTAssertTrue(
                paragraph.hasSuffix("."),
                "Absatz endet mitten im Satz: \(paragraph)"
            )
        }
    }

    func testGermanAbbreviationDoesNotSplitASentence() {
        // The reason NLTokenizer is used instead of splitting on ". ".
        let text = "Wir nehmen z. B. das erste Modell. Danach kommt das zweite. "
            + "Dann das dritte. Und zuletzt das vierte."
        let first = format(text).components(separatedBy: "\n\n")[0]
        XCTAssertTrue(first.contains("z. B. das erste Modell"), "Abkürzung zerrissen: \(first)")
    }

    func testParagraphsOffKeepsOneLine() {
        let text = "Eins ist da. Zwei ist da. Drei ist da. Vier ist da."
        XCTAssertEqual(format(text, paragraphs: false), text)
    }

    // MARK: - Spoken commands

    func testNewLineCommandBecomesASingleLineBreak() {
        XCTAssertEqual(
            format("Ich komme später, neue Zeile, bring bitte Brot mit."),
            "Ich komme später,\nBring bitte Brot mit."
        )
    }

    func testNewParagraphCommandBecomesABlankLine() {
        XCTAssertEqual(
            format("Soweit der erste Teil. Neuer Absatz. Jetzt der zweite Teil."),
            "Soweit der erste Teil.\n\nJetzt der zweite Teil."
        )
    }

    func testBulletCommandStartsAListItem() {
        let result = format("Einkaufen. Stichpunkt, Milch. Stichpunkt, Brot.")
        XCTAssertEqual(result, "Einkaufen.\n\n- Milch.\n- Brot.")
    }

    func testOrdinalsBecomeANumberedList() {
        let result = format("Der Plan. Erstens, wir messen. Zweitens, wir bauen. Drittens, wir testen.")
        XCTAssertEqual(
            result,
            """
            Der Plan.

            1. Wir messen.
            2. Wir bauen.
            3. Wir testen.
            """
        )
    }

    /// A single "erstens" is ordinary prose — deleting it changes the sentence.
    func testSingleOrdinalStaysProse() {
        let text = "Das stimmt nicht. Erstens war die Messung falsch."
        XCTAssertEqual(format(text), text)
    }

    func testDescendingOrdinalsStayProse() {
        let text = "Er nannte es. Zweitens kam später. Erstens kam davor."
        XCTAssertEqual(format(text), text)
    }

    /// The guard that makes the whole command idea safe: "Aufzählung" and
    /// "neue Zeile" are ordinary German words mid-sentence.
    func testCommandWordsMidSentenceAreNotCommands() {
        let text = "Das ist eine Aufzählung von Dingen, die eine neue Zeile im Editor brauchen."
        XCTAssertEqual(format(text), text)
    }

    func testCommandsOffLeavesThemInTheText() {
        let text = "Ich komme später, neue Zeile, bring Brot mit."
        XCTAssertEqual(format(text, commands: false), text)
    }

    func testRepeatedCommandsDoNotProduceBlankRuns() {
        let result = format("Erster Teil. Neuer Absatz. Neuer Absatz. Zweiter Teil.")
        XCTAssertEqual(result, "Erster Teil.\n\nZweiter Teil.")
        XCTAssertFalse(result.contains("\n\n\n"))
    }

    func testTrailingCommandLeavesNoDanglingBreak() {
        let result = format("Das war alles. Neuer Absatz.")
        XCTAssertEqual(result, "Das war alles.")
    }

    // MARK: - Casing

    func testListItemGetsCapitalized() {
        XCTAssertEqual(format("Liste. Stichpunkt, milch kaufen."), "Liste.\n\n- Milch kaufen.")
    }

    /// "iPhone" must survive a bullet unharmed.
    func testMixedCaseWordIsNotCapitalized() {
        XCTAssertEqual(format("Geräte. Stichpunkt, iPhone laden."), "Geräte.\n\n- iPhone laden.")
    }

    // MARK: - Invariants

    func testIsIdempotent() {
        let text = "Der Plan. Erstens, wir messen. Zweitens, wir bauen. "
            + "Ein Satz. Noch einer. Und ein dritter. Und ein vierter."
        let once = format(text)
        XCTAssertEqual(format(once), once)
    }

    func testEmptyAndWhitespaceInput() {
        XCTAssertEqual(format(""), "")
        XCTAssertEqual(format("   "), "")
    }

    func testNoTrailingOrLeadingWhitespace() {
        let result = format("Eins. Zwei. Drei. Vier. Fünf. Sechs.")
        XCTAssertEqual(result, result.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Integration with polish()

    func testPolishProducesParagraphs() {
        var options = TextPolisher.Options()
        options.applyFuzzyDictionary = false
        let text = "Eins ist da. Zwei ist da. Drei ist da. Vier ist da."
        XCTAssertTrue(TextPolisher.polish(text, options: options).contains("\n\n"))
    }

    /// Verbatim returns before `tidy`, so the formatter is never reached — a
    /// dictation into Xcode or Terminal must arrive exactly as spoken.
    func testVerbatimIsUnformatted() {
        var options = TextPolisher.Options()
        options.verbatim = true
        options.applyFuzzyDictionary = false
        let text = "Eins ist da. Zwei ist da. Drei ist da. Vier ist da. Neue Zeile. Fünf."
        XCTAssertEqual(TextPolisher.polish(text, options: options), text)
    }

    func testChatProfileKeepsOneLineButHonoursSpokenBreak() {
        let options = PolishProfile.options(for: .chat)
        XCTAssertFalse(options.paragraphs)
        XCTAssertTrue(options.structureCommands)

        var local = options
        local.applyFuzzyDictionary = false
        local.dictionary = [:]
        let flowing = TextPolisher.polish("eins ist da. zwei ist da. drei ist da. vier ist da.", options: local)
        XCTAssertFalse(flowing.contains("\n"))
    }

    func testCodeProfileDisablesNothingBecauseVerbatimAlreadyReturnsEarly() {
        // Documents the mechanism rather than duplicating the guard: `.code` is
        // verbatim, and verbatim never reaches the formatter.
        XCTAssertTrue(PolishProfile.options(for: .code).verbatim)
    }
}
