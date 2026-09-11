import AppKit
import XCTest
@testable import Notable

/// Spec 26: nested lists in the notes. The key is not the risk — the round-trip
/// is. The buffer is Markdown that goes verbatim to the model, so a drift here
/// silently rewrites notes the summary treats as fact.
final class NotesNestingTests: XCTestCase {
    private func levels(_ markdown: String) -> [Int] {
        NotesMarkdown.parse(markdown).map(\.indent)
    }

    // MARK: - Markdown format

    func testChildIsIndentedToTheParentsContentColumn() {
        let lines = [NotesLine(.bullet, "a"), NotesLine(.bullet, "b", indent: 1)]
        XCTAssertEqual(NotesMarkdown.serialize(lines), "- a\n  - b")
    }

    /// The example from the spec, verbatim: per-level numbering, three columns
    /// under "1. ", a bulleted sub-point that does not restart the outer count.
    func testNumberingIsPerLevel() {
        let lines = [
            NotesLine(.numbered, "Budget"),
            NotesLine(.bullet, "offen: Q4", indent: 1),
            NotesLine(.numbered, "Personal"),
            NotesLine(.numbered, "Recruiting", indent: 1),
            NotesLine(.numbered, "Onboarding", indent: 1),
            NotesLine(.numbered, "Termine"),
        ]
        XCTAssertEqual(NotesMarkdown.serialize(lines), """
        1. Budget
           - offen: Q4
        2. Personal
           1. Recruiting
           2. Onboarding
        3. Termine
        """)
    }

    /// The checkbox's list marker is "- "; the box is content, as in CommonMark.
    func testChildOfACheckboxSitsTwoColumnsIn() {
        let lines = [NotesLine(.checkbox(done: false), "a"), NotesLine(.bullet, "b", indent: 1)]
        XCTAssertEqual(NotesMarkdown.serialize(lines), "- [ ] a\n  - b")
    }

    /// A fixed width would be wrong here: under "10. " the content starts at 4.
    func testColumnFollowsATwoDigitParent() {
        var lines = (1...10).map { NotesLine(.numbered, "p\($0)") }
        lines.append(NotesLine(.bullet, "kind", indent: 1))
        let markdown = NotesMarkdown.serialize(lines)
        XCTAssertTrue(markdown.hasSuffix("10. p10\n    - kind"), markdown)
        XCTAssertEqual(NotesMarkdown.parse(markdown).last, NotesLine(.bullet, "kind", indent: 1))
    }

    func testParsesNestingFromContentColumns() {
        XCTAssertEqual(levels("- a\n  - b\n    - c\n- d"), [0, 1, 2, 0])
        XCTAssertEqual(levels("1. a\n   - b"), [0, 1])
        // One space short of the content column is a sibling, not a child.
        XCTAssertEqual(levels("1. a\n  - b"), [0, 0])
        XCTAssertEqual(levels("- a\n - b"), [0, 0])
    }

    func testATabCountsAsFourColumns() {
        XCTAssertEqual(levels("1. a\n\t- b"), [0, 1])
    }

    /// Only list items nest. An indented heading or paragraph stays body text,
    /// byte for byte — four spaces before a paragraph would be a code block.
    func testIndentedNonListLinesStayBodyUntouched() {
        XCTAssertEqual(NotesMarkdown.parse("  ## x")[0], NotesLine(.body, "  ## x"))
        XCTAssertEqual(NotesMarkdown.parse("    Absatz")[0], NotesLine(.body, "    Absatz"))
        XCTAssertEqual(NotesMarkdown.serialize(NotesMarkdown.parse("    Absatz")), "    Absatz")
    }

    // MARK: - Normalisation

    func testNormalisationRules() {
        let normalized = NotesMarkdown.normalized([
            NotesLine(.bullet, "a", indent: 3),        // first item → 0
            NotesLine(.bullet, "b", indent: 4),        // at most one deeper → 1
            NotesLine(.body, "text", indent: 2),       // body → 0
            NotesLine(.heading, "h", indent: 1),       // heading → 0
            NotesLine(.numbered, "c", indent: 2),      // first after a heading → 0
        ])
        XCTAssertEqual(normalized.map(\.indent), [0, 1, 0, 0, 0])
    }

    func testDepthIsCappedAtSixLevels() {
        let lines = (0...8).map { NotesLine(.bullet, "\($0)", indent: $0) }
        XCTAssertEqual(NotesMarkdown.normalized(lines).map(\.indent), [0, 1, 2, 3, 4, 5, 5, 5, 5])
    }

    /// Markdown cannot say "two levels deeper with nothing in between".
    func testBlankLineEndsTheList() {
        XCTAssertEqual(levels("- a\n\n  - b"), [0, 0, 0])
    }

    // MARK: - Editing

    func testIndentingTheFirstItemChangesNothing() {
        let lines = NotesMarkdown.parse("- a\n- b")
        XCTAssertEqual(NotesMarkdown.indenting(lines, in: 0...0), lines)
    }

    func testIndentingNestsUnderThePreviousItem() {
        let lines = NotesMarkdown.parse("- a\n- b\n- c")
        let once = NotesMarkdown.indenting(lines, in: 1...2)
        XCTAssertEqual(once.map(\.indent), [0, 1, 1])
        XCTAssertEqual(NotesMarkdown.indenting(once, in: 2...2).map(\.indent), [0, 1, 2])
    }

    func testBodyTextInTheSelectionIsLeftAlone() {
        let lines = NotesMarkdown.parse("- a\ntext\n- b\n- c")
        let result = NotesMarkdown.indenting(lines, in: 1...3)
        XCTAssertEqual(result.map(\.block), lines.map(\.block))
        XCTAssertEqual(result.map(\.indent), [0, 0, 0, 1])
    }

    /// Children do not move along; the normalisation pulls them up.
    func testOutdentingAParentPullsItsGrandchildrenUp() {
        let lines = NotesMarkdown.parse("- a\n  - b\n    - c")
        let result = NotesMarkdown.outdenting(lines, in: 1...1)
        XCTAssertEqual(result.map(\.indent), [0, 0, 1])
        XCTAssertEqual(NotesMarkdown.outdenting(result, in: 0...0).map(\.indent), [0, 0, 1], "Ebene 0 bleibt 0")
    }

    func testApplyingKeepsTheLevelOnlyForLists() {
        let lines = NotesMarkdown.parse("- a\n  - b")
        XCTAssertEqual(NotesMarkdown.applying(.numbered, to: lines, in: 1...1)[1], NotesLine(.numbered, "b", indent: 1))
        XCTAssertEqual(NotesMarkdown.applying(.heading, to: lines, in: 1...1)[1], NotesLine(.heading, "b"))
    }

    func testReturnOnAnEmptyNestedItemStepsOutOneLevelAtATime() {
        let lines = [NotesLine(.bullet, "a"), NotesLine(.bullet, "", indent: 1)]
        let once = NotesMarkdown.leavingEmptyItem(at: 1, in: lines)
        XCTAssertEqual(once[1], NotesLine(.bullet, ""))
        XCTAssertEqual(NotesMarkdown.leavingEmptyItem(at: 1, in: once)[1], NotesLine(.body, ""))
    }

    func testBackspaceAtLineStartOutdentsBeforeItStripsTheFormat() {
        let lines = [NotesLine(.bullet, "a"), NotesLine(.checkbox(done: true), "b", indent: 1)]
        let once = NotesMarkdown.backspacingAtLineStart(at: 1, in: lines)
        XCTAssertEqual(once[1], NotesLine(.checkbox(done: true), "b"))
        XCTAssertEqual(NotesMarkdown.backspacingAtLineStart(at: 1, in: once)[1], NotesLine(.body, "b"))
    }

    // MARK: - Round-trip properties

    /// serialize → parse gives back the normalised input, for ten thousand
    /// random documents: every block, levels 0–5, empty lines, emoji.
    ///
    /// Body text is drawn from words that do not *start* like markup. Body text
    /// that begins with "- " or "1. " cannot be written unambiguously at all —
    /// it becomes a list item on the next read, and did long before nesting;
    /// the second property covers that input.
    func testSerializeThenParseReturnsTheNormalisedInput() {
        var random = SplitMix64(seed: 26)
        let words = ["Budget", "Größe äöü", "🎯 Ziel", "", "a - b", "Preis: 5 €", "x. y", "Q4 [offen]", "#hashtag"]
        let blocks: [NotesBlock] = [.body, .title, .heading, .subheading, .bullet, .numbered,
                                    .checkbox(done: false), .checkbox(done: true)]
        for _ in 0..<10_000 {
            let lines = (0..<random.next(upTo: 12)).map { _ in
                NotesLine(blocks[random.next(upTo: blocks.count)],
                          words[random.next(upTo: words.count)],
                          indent: random.next(upTo: 6))
            }
            let expected = NotesMarkdown.normalized(lines.isEmpty ? [NotesLine()] : lines)
            let markdown = NotesMarkdown.serialize(lines)
            XCTAssertEqual(NotesMarkdown.parse(markdown), expected, markdown.debugDescription)
        }
    }

    /// Arbitrary text, markup fragments included: one pass through the model
    /// may change it, a second must not.
    func testSerializeParseIsIdempotentOnArbitraryText() {
        var random = SplitMix64(seed: 2026)
        let pieces = [" ", "  ", "\t", "- ", "-", "1. ", "12. ", "1234. ", "# ", "## ", "[ ] ", "[x] ", "a", "ä", "🎯", "\n", "\n", "."]
        for _ in 0..<10_000 {
            let input = (0..<random.next(upTo: 30)).map { _ in pieces[random.next(upTo: pieces.count)] }.joined()
            let once = NotesMarkdown.serialize(NotesMarkdown.parse(input))
            let twice = NotesMarkdown.serialize(NotesMarkdown.parse(once))
            XCTAssertEqual(once, twice, "drifted for \(input.debugDescription)")
        }
    }
}

/// The WYSIWYG side of nesting: the level is visible text (leading tabs).
@MainActor
final class NotesRichTextNestingTests: XCTestCase {
    func testLevelsRenderAsLeadingTabs() {
        let rendered = NotesRichText.attributed(markdown: "- a\n  - b\n    - [ ] c").string
        XCTAssertEqual(rendered, "•\ta\n\t•\tb\n\t\t☐\tc")
    }

    func testNumbersInTheWindowMatchTheMarkdown() {
        let rendered = NotesRichText.attributed(markdown: "1. a\n   - b\n2. c\n   1. d\n   2. e").string
        XCTAssertEqual(rendered, "1.\ta\n\t•\tb\n2.\tc\n\t1.\td\n\t2.\te")
    }

    /// The old Tab bug: a tab typed before the marker produced "\t•\tText",
    /// which read back as body text with a literal "•" in it.
    func testATabBeforeTheMarkerIsALevelNotBodyText() {
        XCTAssertEqual(NotesRichText.line(from: "\t•\tText", headingHint: nil), NotesLine(.bullet, "Text", indent: 1))
        XCTAssertEqual(NotesRichText.line(from: "\tText", headingHint: nil), NotesLine(.body, "\tText"))
    }

    func testNestedRoundTripThroughRenderedText() {
        let markdown = "# Kickoff\n1. Budget\n   - offen: Q4\n     - [x] 🎯 geklärt\n2. Personal\n\nText"
        XCTAssertEqual(NotesRichText.markdown(from: NotesRichText.attributed(markdown: markdown)), markdown)
    }

    func testMarkerLengthIncludesTheLevelTabs() {
        XCTAssertEqual(NotesRichText.markerLength(of: "\t\t•\ta"), 4)
        XCTAssertEqual(NotesRichText.markerLength(of: "\t12.\ta"), 5)
        XCTAssertEqual(NotesRichText.markerLength(of: "\tabc"), 0)
    }

    func testPositionAndOffsetStayInversesWithLevels() {
        let rendered = NotesRichText.attributed(markdown: "- ä\n  - 🎯 b\n    1. ö\n\n- [ ] c")
        for offset in 0...rendered.string.utf16.count {
            let position = NotesRichText.position(in: rendered, utf16Offset: offset)
            let back = NotesRichText.utf16Offset(in: rendered, paragraph: position.paragraph, column: position.column)
            let again = NotesRichText.position(in: rendered, utf16Offset: back)
            XCTAssertEqual(again.paragraph, position.paragraph, "paragraph drifted at offset \(offset)")
            XCTAssertEqual(again.column, position.column, "column drifted at offset \(offset)")
        }
        // Column 0 is after the marker *and* its tabs.
        XCTAssertEqual(NotesRichText.utf16Offset(in: rendered, paragraph: 1, column: 0), "•\tä\n".utf16.count + 3)
    }

    func testCheckboxHitIgnoresTheLevelTabsAndTheText() {
        let paragraph = "\t☐\tx"
        XCTAssertFalse(NotesRichText.isCheckboxHit(in: paragraph, atOffset: 0))
        XCTAssertTrue(NotesRichText.isCheckboxHit(in: paragraph, atOffset: 1))
        XCTAssertTrue(NotesRichText.isCheckboxHit(in: paragraph, atOffset: 2))
        XCTAssertFalse(NotesRichText.isCheckboxHit(in: paragraph, atOffset: 3))
        XCTAssertFalse(NotesRichText.isCheckboxHit(in: "\t•\tx", atOffset: 1))
    }

    /// Wrapped lines start under the text, not under the marker.
    func testHangingIndentGrowsWithTheLevel() {
        let style = NotesRichText.paragraphStyle(for: .bullet, indent: 2)
        XCTAssertEqual(style.headIndent, NotesRichText.indentStep * 3)
        XCTAssertEqual(style.tabStops.map(\.location), [1, 2, 3].map { NotesRichText.indentStep * $0 })
    }
}

/// Deterministic generator for the property tests — a failure must reproduce.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next(upTo bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Int(z % UInt64(bound))
    }
}
