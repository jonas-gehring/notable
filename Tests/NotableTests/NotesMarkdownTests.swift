import XCTest
@testable import Notable

/// Pure coverage for the Markdown ⇄ block conversion behind the WYSIWYG notes
/// editor. The editor shows formatted text, but the buffer stays Markdown — so
/// every keystroke round-trips through here. A bug in this file silently
/// rewrites notes that the summarizer later treats as ground truth, which is why
/// the round-trip and idempotence properties are pinned this hard.
final class NotesMarkdownTests: XCTestCase {
    // MARK: - Parsing each block

    func testParsesEveryBlockKind() {
        let markdown = """
        # Titel
        ## Überschrift
        ### Unterüberschrift
        Fließtext
        - Aufzählung
        1. Nummeriert
        - [ ] Offen
        - [x] Erledigt
        """
        XCTAssertEqual(NotesMarkdown.parse(markdown), [
            NotesLine(.title, "Titel"),
            NotesLine(.heading, "Überschrift"),
            NotesLine(.subheading, "Unterüberschrift"),
            NotesLine(.body, "Fließtext"),
            NotesLine(.bullet, "Aufzählung"),
            NotesLine(.numbered, "Nummeriert"),
            NotesLine(.checkbox(done: false), "Offen"),
            NotesLine(.checkbox(done: true), "Erledigt"),
        ])
    }

    /// The checkbox prefix begins with the bullet prefix; if the order in
    /// `parseLine` ever flips, every checkbox silently becomes a bullet whose
    /// text starts with "[ ] ". This is that guard.
    func testCheckboxIsNotMistakenForBullet() {
        XCTAssertEqual(NotesMarkdown.parse("- [ ] Angebot")[0], NotesLine(.checkbox(done: false), "Angebot"))
        XCTAssertEqual(NotesMarkdown.parse("- [x] Angebot")[0], NotesLine(.checkbox(done: true), "Angebot"))
    }

    func testUppercaseTickIsAcceptedAndNormalised() {
        let parsed = NotesMarkdown.parse("- [X] Erledigt")
        XCTAssertEqual(parsed[0], NotesLine(.checkbox(done: true), "Erledigt"))
        XCTAssertEqual(NotesMarkdown.serialize(parsed), "- [x] Erledigt")
    }

    // MARK: - Round-trip and idempotence

    func testRoundTripPreservesCanonicalMarkdown() {
        let markdown = """
        # Kickoff
        ## Entscheidungen
        - Budget steht
        - [ ] Angebot bis Freitag
        - [x] Termin verschickt

        [04:51] Preisfrage vertagt
        """
        XCTAssertEqual(NotesMarkdown.serialize(NotesMarkdown.parse(markdown)), markdown)
    }

    /// Serialising twice must not drift. Anything that changes on a second pass
    /// would keep changing on every keystroke.
    func testSerializeIsIdempotent() {
        let inputs = [
            "# A\n## B\n- c\n1. d\n- [ ] e",
            "",
            "\n\n",
            "nur Fließtext",
            "- [x] fertig\n- [ ] offen",
        ]
        for input in inputs {
            let once = NotesMarkdown.serialize(NotesMarkdown.parse(input))
            let twice = NotesMarkdown.serialize(NotesMarkdown.parse(once))
            XCTAssertEqual(once, twice, "drifted for \(input.debugDescription)")
        }
    }

    func testEmptyLinesSurvive() {
        XCTAssertEqual(NotesMarkdown.parse("a\n\nb").count, 3)
        XCTAssertEqual(NotesMarkdown.serialize(NotesMarkdown.parse("a\n\nb")), "a\n\nb")
    }

    /// A trailing newline means a real empty last line the caret can sit on.
    func testTrailingNewlineIsPreserved() {
        XCTAssertEqual(NotesMarkdown.serialize(NotesMarkdown.parse("a\n")), "a\n")
    }

    // MARK: - Text that only looks like markup

    /// A year at the start of a sentence must not become a numbered list item,
    /// or "2026. Ein gutes Jahr" would silently renumber to "1. Ein gutes Jahr".
    func testLongNumberIsNotANumberedListItem() {
        XCTAssertEqual(NotesMarkdown.parse("2026. Ein gutes Jahr")[0], NotesLine(.body, "2026. Ein gutes Jahr"))
    }

    func testShortNumberIsANumberedListItem() {
        XCTAssertEqual(NotesMarkdown.parse("3. Punkt")[0], NotesLine(.numbered, "Punkt"))
    }

    /// A stamped line is ordinary body text and must stay byte-identical —
    /// ⌘T output flowing through the formatter unchanged is the contract.
    func testTimestampLineIsUntouchedBody() {
        let line = "[1:02:33] Kunde will Rabatt"
        XCTAssertEqual(NotesMarkdown.parse(line)[0], NotesLine(.body, line))
        XCTAssertEqual(NotesMarkdown.serialize(NotesMarkdown.parse(line)), line)
    }

    /// A hyphen without the trailing space is a dash, not a bullet.
    func testBareHyphenIsNotABullet() {
        XCTAssertEqual(NotesMarkdown.parse("-Wert")[0], NotesLine(.body, "-Wert"))
        XCTAssertEqual(NotesMarkdown.parse("a - b")[0], NotesLine(.body, "a - b"))
    }

    // MARK: - Renumbering

    func testNumberedRunIsRenumberedFromOne() {
        let lines = [NotesLine(.numbered, "a"), NotesLine(.numbered, "b"), NotesLine(.numbered, "c")]
        XCTAssertEqual(NotesMarkdown.serialize(lines), "1. a\n2. b\n3. c")
    }

    /// Two runs separated by anything else each restart at 1.
    func testSeparateRunsRestartNumbering() {
        let lines = [
            NotesLine(.numbered, "a"),
            NotesLine(.body, ""),
            NotesLine(.numbered, "b"),
        ]
        XCTAssertEqual(NotesMarkdown.serialize(lines), "1. a\n\n1. b")
    }

    func testInsertingIntoARunRenumbersTheRest() {
        var lines = NotesMarkdown.parse("1. a\n2. c")
        lines.insert(NotesLine(.numbered, "b"), at: 1)
        XCTAssertEqual(NotesMarkdown.serialize(lines), "1. a\n2. b\n3. c")
    }

    // MARK: - Applying blocks

    func testApplyingBlockSetsEveryTouchedLine() {
        let lines = NotesMarkdown.parse("a\nb\nc")
        let result = NotesMarkdown.applying(.bullet, to: lines, in: 0...1)
        XCTAssertEqual(result.map(\.block), [.bullet, .bullet, .body])
    }

    /// Applying the kind a line already has clears it — the only keyboard way
    /// out of a list, and what Apple Notes' list buttons do.
    func testApplyingSameBlockTogglesBackToBody() {
        let lines = NotesMarkdown.parse("- a\n- b")
        let result = NotesMarkdown.applying(.bullet, to: lines, in: 0...1)
        XCTAssertEqual(result.map(\.block), [.body, .body])
    }

    /// A half-formatted selection adopts the kind rather than clearing it,
    /// so one press makes a mixed block uniform.
    func testMixedSelectionAdoptsTheBlock() {
        let lines = NotesMarkdown.parse("- a\nb")
        let result = NotesMarkdown.applying(.bullet, to: lines, in: 0...1)
        XCTAssertEqual(result.map(\.block), [.bullet, .bullet])
    }

    /// Re-applying "checkbox" to a checked box clears the block; it must not
    /// flip the tick, which is what clicking the box is for.
    func testReapplyingCheckboxClearsRatherThanUnticks() {
        let lines = NotesMarkdown.parse("- [x] a")
        let result = NotesMarkdown.applying(.checkbox(done: false), to: lines, in: 0...0)
        XCTAssertEqual(result.map(\.block), [.body])
    }

    func testApplyingToEmptyDocumentProducesOneLine() {
        XCTAssertEqual(NotesMarkdown.applying(.bullet, to: [], in: 0...0), [NotesLine(.bullet, "")])
    }

    func testApplyingClampsOutOfRangeSelection() {
        let lines = NotesMarkdown.parse("a")
        XCTAssertEqual(NotesMarkdown.applying(.title, to: lines, in: 0...9).map(\.block), [.title])
    }

    // MARK: - Checkbox ticking

    func testTogglingCheckboxFlipsOnlyThatLine() {
        let lines = NotesMarkdown.parse("- [ ] a\n- [ ] b")
        let result = NotesMarkdown.togglingCheckbox(at: 1, in: lines)
        XCTAssertEqual(result.map(\.block), [.checkbox(done: false), .checkbox(done: true)])
    }

    func testTogglingNonCheckboxIsANoOp() {
        let lines = NotesMarkdown.parse("- a")
        XCTAssertEqual(NotesMarkdown.togglingCheckbox(at: 0, in: lines), lines)
    }

    func testTogglingOutOfRangeIsANoOp() {
        let lines = NotesMarkdown.parse("- [ ] a")
        XCTAssertEqual(NotesMarkdown.togglingCheckbox(at: 5, in: lines), lines)
    }

    // MARK: - Return continuation

    func testListsContinueAndHeadingsDoNot() {
        XCTAssertEqual(NotesBlock.bullet.continuation, .bullet)
        XCTAssertEqual(NotesBlock.numbered.continuation, .numbered)
        XCTAssertEqual(NotesBlock.heading.continuation, .body)
        XCTAssertEqual(NotesBlock.title.continuation, .body)
        XCTAssertEqual(NotesBlock.body.continuation, .body)
    }

    /// Return after a ticked item starts an *unticked* one — carrying the tick
    /// over would mark work done that nobody did.
    func testCheckboxContinuesUnticked() {
        XCTAssertEqual(NotesBlock.checkbox(done: true).continuation, .checkbox(done: false))
    }
}
