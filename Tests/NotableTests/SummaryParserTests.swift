import XCTest

/// Pure header-parsing tests — no network, no CLI. Verifies that the
/// `TITLE:`/`TLDR:` header block the prompt asks for is split off cleanly and
/// that malformed / missing headers degrade gracefully to "all body".
final class SummaryParserTests: XCTestCase {

    // MARK: - Happy path

    func testParsesTitleTldrAndBody() {
        let raw = """
        TITLE: Sprint-Planung Q3
        TLDR: Backlog für Sprint 24 priorisiert; API-Migration auf August verschoben.

        ## Zusammenfassung
        - **Backlog** priorisiert
        """
        let result = SummaryParser.parse(raw)
        XCTAssertEqual(result.title, "Sprint-Planung Q3")
        XCTAssertEqual(result.subtitle, "Backlog für Sprint 24 priorisiert; API-Migration auf August verschoben.")
        XCTAssertTrue(result.markdown.hasPrefix("## Zusammenfassung"))
        XCTAssertFalse(result.markdown.contains("TITLE:"))
        XCTAssertFalse(result.markdown.contains("TLDR:"))
    }

    func testConsumesRuleFenceBetweenHeaderAndBody() {
        let raw = """
        TITLE: Kickoff Nordlicht
        TLDR: Team richtet sich auf Postgres aus.
        ---
        ## Zusammenfassung
        - Los geht's
        """
        let result = SummaryParser.parse(raw)
        XCTAssertEqual(result.title, "Kickoff Nordlicht")
        XCTAssertEqual(result.subtitle, "Team richtet sich auf Postgres aus.")
        XCTAssertEqual(result.markdown, "## Zusammenfassung\n- Los geht's")
    }

    // MARK: - Missing / partial headers

    func testMissingHeadersReturnsAllMarkdown() {
        let raw = """
        ## Zusammenfassung
        - Ohne Kopfzeilen
        """
        let result = SummaryParser.parse(raw)
        XCTAssertNil(result.title)
        XCTAssertNil(result.subtitle)
        XCTAssertEqual(result.markdown, raw)
    }

    func testOnlyTitlePresent() {
        let raw = """
        TITLE: Nur ein Titel

        ## Zusammenfassung
        - Body
        """
        let result = SummaryParser.parse(raw)
        XCTAssertEqual(result.title, "Nur ein Titel")
        XCTAssertNil(result.subtitle)
        XCTAssertTrue(result.markdown.hasPrefix("## Zusammenfassung"))
    }

    func testOnlyTldrPresent() {
        let raw = """
        TLDR: Nur ein Einzeiler
        ## Zusammenfassung
        - Body
        """
        let result = SummaryParser.parse(raw)
        XCTAssertNil(result.title)
        XCTAssertEqual(result.subtitle, "Nur ein Einzeiler")
        XCTAssertTrue(result.markdown.hasPrefix("## Zusammenfassung"))
    }

    func testEmptyHeaderValueBecomesNil() {
        let raw = """
        TITLE:
        TLDR: Etwas Sinnvolles

        ## Zusammenfassung
        - Body
        """
        let result = SummaryParser.parse(raw)
        XCTAssertNil(result.title, "Leerer Titelwert muss nil sein, nicht Leerstring")
        XCTAssertEqual(result.subtitle, "Etwas Sinnvolles")
    }

    // MARK: - Robustness against Markdown-wrapped headers

    func testTitleWrappedInBoldAndHeading() {
        let raw = """
        # **TITLE:** Redigierte Notizen
        **TLDR:** Ein knapper Satz.

        ## Zusammenfassung
        - Body
        """
        let result = SummaryParser.parse(raw)
        XCTAssertEqual(result.title, "Redigierte Notizen")
        XCTAssertEqual(result.subtitle, "Ein knapper Satz.")
    }

    func testBoldedKeyBeforeColon() {
        let raw = "**TITLE**: Fettmarkierter Schlüssel\n\n## Zusammenfassung\n- Body"
        let result = SummaryParser.parse(raw)
        XCTAssertEqual(result.title, "Fettmarkierter Schlüssel")
    }

    func testLeadingBlankLinesBeforeHeaders() {
        let raw = "\n\n  \nTITLE: Nach Leerzeilen\nTLDR: Auch nach Leerzeilen\n\n## Zusammenfassung\n- Body"
        let result = SummaryParser.parse(raw)
        XCTAssertEqual(result.title, "Nach Leerzeilen")
        XCTAssertEqual(result.subtitle, "Auch nach Leerzeilen")
        XCTAssertTrue(result.markdown.hasPrefix("## Zusammenfassung"))
    }

    // MARK: - Non-header lines that look similar must not be mistaken

    func testFrontMatterRuleFenceIsNotEatenWithoutHeader() {
        // A leading --- with no preceding TITLE/TLDR should stay in the body.
        let raw = "---\ntitle: yaml\n---\n## Zusammenfassung\n- Body"
        let result = SummaryParser.parse(raw)
        XCTAssertNil(result.title)
        XCTAssertNil(result.subtitle)
        XCTAssertEqual(result.markdown, raw)
    }

    func testBodyMentioningTitleWordIsNotTreatedAsHeader() {
        let raw = "## Zusammenfassung\n- Der TITLE: des Dokuments wurde besprochen"
        let result = SummaryParser.parse(raw)
        XCTAssertNil(result.title)
        XCTAssertEqual(result.markdown, raw)
    }

    func testEmptyInput() {
        let result = SummaryParser.parse("")
        XCTAssertNil(result.title)
        XCTAssertNil(result.subtitle)
        XCTAssertEqual(result.markdown, "")
    }
}
