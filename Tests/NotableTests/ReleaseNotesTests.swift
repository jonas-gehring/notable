import XCTest
@testable import Notable

/// The release notes are the one piece of text in Notable written by someone
/// else — GitHub hands them over as whatever Markdown was typed into the release
/// form. The rendering therefore has to survive input nobody here controls.
final class ReleaseNotesTests: XCTestCase {
    func testHeadingsLoseTheirHashesAndBecomeBold() {
        XCTAssertEqual(ReleaseNotes.prepare("### Requirements"), "**Requirements**")
        XCTAssertEqual(ReleaseNotes.prepare("# Notable 1.0.0"), "**Notable 1.0.0**")
    }

    /// "###" on its own would otherwise become "****" — four literal asterisks,
    /// because the inline parser has nothing to emphasise.
    func testEmptyHeadingDoesNotBecomeAsterisks() {
        XCTAssertEqual(ReleaseNotes.prepare("###"), "")
    }

    func testAllThreeListMarkersBecomeBullets() {
        XCTAssertEqual(ReleaseNotes.prepare("- one\n* two\n+ three"), "• one\n• two\n• three")
    }

    func testHorizontalRulesAreDroppedRatherThanPrinted() {
        XCTAssertEqual(ReleaseNotes.prepare("a\n\n---\n\nb"), "a\n\nb")
    }

    func testBlankRunsCollapseAndEdgesAreTrimmed() {
        XCTAssertEqual(ReleaseNotes.prepare("\n\n\na\n\n\n\nb\n\n\n"), "a\n\nb")
    }

    /// Inline syntax is deliberately *not* touched here — it is the parser's job,
    /// and mangling it by hand is how bold text turns into stray asterisks.
    func testInlineMarkupSurvivesPreparation() {
        XCTAssertEqual(ReleaseNotes.prepare("a **bold** and a [link](https://example.com)"),
                       "a **bold** and a [link](https://example.com)")
    }

    func testLongNotesAreTruncatedRatherThanPushingTheButtonOffScreen() {
        let long = String(repeating: "x", count: ReleaseNotes.characterLimit + 500)
        let prepared = ReleaseNotes.prepare(long)
        XCTAssertLessThanOrEqual(prepared.count, ReleaseNotes.characterLimit + 1)
        XCTAssertTrue(prepared.hasSuffix("…"))
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertEqual(ReleaseNotes.prepare(""), "")
        XCTAssertEqual(String(ReleaseNotes.attributed("").characters), "")
    }

    /// The whole point: what reaches the label carries no Markdown syntax.
    func testRenderedTextHasNoLeftoverSyntax() {
        let notes = """
        ### What's new

        - **Dictation** — faster
        - A [link](https://example.com)

        ---

        Plain paragraph.
        """
        let rendered = String(ReleaseNotes.attributed(notes).characters)
        XCTAssertFalse(rendered.contains("#"))
        XCTAssertFalse(rendered.contains("**"))
        XCTAssertFalse(rendered.contains("---"))
        XCTAssertTrue(rendered.contains("• Dictation — faster"))
        XCTAssertTrue(rendered.contains("What's new"))
    }
}
