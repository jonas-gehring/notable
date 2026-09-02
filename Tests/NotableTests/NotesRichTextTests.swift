import AppKit
import XCTest
@testable import Notable

/// Coverage for the WYSIWYG layer: Markdown in, formatted text out, and back.
///
/// The pieces that actually break in editors like this are the boring ones — the
/// offset arithmetic around a marker the user cannot see. Every caret restore
/// after a format change goes through `position`/`utf16Offset`, so those are
/// pinned as exact inverses here.
@MainActor
final class NotesRichTextTests: XCTestCase {
    // MARK: - Rendering

    func testMarkdownIsNotVisibleInTheRenderedText() {
        let rendered = NotesRichText.attributed(markdown: "# Titel\n## Kapitel\n### Abschnitt").string
        XCTAssertFalse(rendered.contains("#"), "heading markup leaked into the visible text")
        XCTAssertEqual(rendered, "Titel\nKapitel\nAbschnitt")
    }

    func testListsRenderRealMarkers() {
        let rendered = NotesRichText.attributed(markdown: "- eins\n- [ ] zwei\n- [x] drei").string
        XCTAssertEqual(rendered, "•\teins\n☐\tzwei\n☑\tdrei")
    }

    func testNumberedListRendersRunningOrdinals() {
        let rendered = NotesRichText.attributed(markdown: "1. a\n1. b\n1. c").string
        XCTAssertEqual(rendered, "1.\ta\n2.\tb\n3.\tc")
    }

    func testHeadingsGetDistinctFonts() {
        let title = NotesRichText.font(for: .title).pointSize
        let heading = NotesRichText.font(for: .heading).pointSize
        let body = NotesRichText.font(for: .body).pointSize
        XCTAssertGreaterThan(title, heading)
        XCTAssertGreaterThan(heading, body)
    }

    /// Headings have no visible marker, so they are the one thing that has to
    /// survive as an attribute — otherwise reading the editor back loses them.
    func testHeadingCarriesItsAttribute() {
        let rendered = NotesRichText.attributed(markdown: "## Kapitel")
        let value = rendered.attribute(.notesBlock, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(value, 2)
    }

    func testBodyCarriesNoBlockAttribute() {
        let rendered = NotesRichText.attributed(markdown: "nur Text")
        XCTAssertNil(rendered.attribute(.notesBlock, at: 0, effectiveRange: nil))
    }

    // MARK: - Round-trip

    func testRoundTripThroughRenderedText() {
        let markdown = """
        # Kickoff
        ## Entscheidungen
        - Budget steht
        - [ ] Angebot bis Freitag
        - [x] Termin verschickt
        1. erstens
        2. zweitens

        [04:51] Preisfrage vertagt
        """
        let rendered = NotesRichText.attributed(markdown: markdown)
        XCTAssertEqual(NotesRichText.markdown(from: rendered), markdown)
    }

    func testEmptyBufferRoundTrips() {
        let rendered = NotesRichText.attributed(markdown: "")
        XCTAssertEqual(NotesRichText.markdown(from: rendered), "")
    }

    /// Text the user typed that merely looks like a marker must not gain one.
    func testPlainTextWithBulletCharacterIsNotAList() {
        let rendered = NotesRichText.attributed(markdown: "kein • Aufzählungszeichen")
        XCTAssertEqual(NotesRichText.markdown(from: rendered), "kein • Aufzählungszeichen")
    }

    // MARK: - Reading a paragraph back

    func testMarkerWinsOverHeadingHint() {
        XCTAssertEqual(NotesRichText.line(from: "•\ttext", headingHint: .heading), NotesLine(.bullet, "text"))
    }

    func testHeadingHintAppliesOnlyWithoutAMarker() {
        XCTAssertEqual(NotesRichText.line(from: "text", headingHint: .heading), NotesLine(.heading, "text"))
        XCTAssertEqual(NotesRichText.line(from: "text", headingHint: nil), NotesLine(.body, "text"))
    }

    func testDeletingTheMarkerTurnsTheLineIntoBody() {
        XCTAssertEqual(NotesRichText.line(from: "eins", headingHint: nil), NotesLine(.body, "eins"))
    }

    // MARK: - Marker length

    func testMarkerLengths() {
        XCTAssertEqual(NotesRichText.markerLength(of: "•\ta"), 2)
        XCTAssertEqual(NotesRichText.markerLength(of: "☐\ta"), 2)
        XCTAssertEqual(NotesRichText.markerLength(of: "☑\ta"), 2)
        XCTAssertEqual(NotesRichText.markerLength(of: "1.\ta"), 3)
        XCTAssertEqual(NotesRichText.markerLength(of: "12.\ta"), 4)
        XCTAssertEqual(NotesRichText.markerLength(of: "kein Marker"), 0)
    }

    // MARK: - Caret mapping

    /// `position` and `utf16Offset` must be exact inverses for every caret spot
    /// in a document that mixes markers, headings and blank lines — this is what
    /// keeps the caret still when a format button is pressed.
    func testPositionAndOffsetAreInverses() {
        let rendered = NotesRichText.attributed(markdown: "# T\n- a\n1. b\n\n- [x] c\nfließtext")
        for offset in 0...rendered.string.utf16.count {
            let position = NotesRichText.position(in: rendered, utf16Offset: offset)
            let back = NotesRichText.utf16Offset(in: rendered, paragraph: position.paragraph, column: position.column)
            let again = NotesRichText.position(in: rendered, utf16Offset: back)
            XCTAssertEqual(again.paragraph, position.paragraph, "paragraph drifted at offset \(offset)")
            XCTAssertEqual(again.column, position.column, "column drifted at offset \(offset)")
        }
    }

    /// A caret anywhere inside the invisible marker reports column 0, so typing
    /// there lands after the marker rather than inside it.
    func testCaretInsideMarkerClampsToColumnZero() {
        let rendered = NotesRichText.attributed(markdown: "- abc")
        XCTAssertEqual(NotesRichText.position(in: rendered, utf16Offset: 0).column, 0)
        XCTAssertEqual(NotesRichText.position(in: rendered, utf16Offset: 1).column, 0)
        XCTAssertEqual(NotesRichText.position(in: rendered, utf16Offset: 2).column, 0)
        XCTAssertEqual(NotesRichText.position(in: rendered, utf16Offset: 3).column, 1)
    }

    /// Offsets are UTF-16 throughout, so a note containing an emoji must not
    /// throw the mapping off — the character occupies two units.
    func testMappingSurvivesNonBMPCharacters() {
        let rendered = NotesRichText.attributed(markdown: "- ein 🎯 Ziel\n## Kapitel 🚀")
        for offset in 0...rendered.string.utf16.count {
            let position = NotesRichText.position(in: rendered, utf16Offset: offset)
            let back = NotesRichText.utf16Offset(in: rendered, paragraph: position.paragraph, column: position.column)
            let again = NotesRichText.position(in: rendered, utf16Offset: back)
            XCTAssertEqual(again.paragraph, position.paragraph, "paragraph drifted at offset \(offset)")
            XCTAssertEqual(again.column, position.column, "column drifted at offset \(offset)")
        }
        XCTAssertEqual(NotesRichText.markdown(from: rendered), "- ein 🎯 Ziel\n## Kapitel 🚀")
    }

    func testColumnIsMeasuredAfterTheMarker() {
        let rendered = NotesRichText.attributed(markdown: "- abc")
        // "•\tabc" — offset 5 is the end of the line, i.e. column 3 of "abc".
        XCTAssertEqual(NotesRichText.position(in: rendered, utf16Offset: 5).column, 3)
    }

    func testPositionFindsTheRightParagraph() {
        let rendered = NotesRichText.attributed(markdown: "a\nb\nc")
        XCTAssertEqual(NotesRichText.position(in: rendered, utf16Offset: 0).paragraph, 0)
        XCTAssertEqual(NotesRichText.position(in: rendered, utf16Offset: 2).paragraph, 1)
        XCTAssertEqual(NotesRichText.position(in: rendered, utf16Offset: 4).paragraph, 2)
    }

    func testOffsetsBeyondTheEndClamp() {
        let rendered = NotesRichText.attributed(markdown: "a")
        XCTAssertEqual(NotesRichText.position(in: rendered, utf16Offset: 99).paragraph, 0)
        XCTAssertEqual(NotesRichText.utf16Offset(in: rendered, paragraph: 99, column: 99), 1)
    }

    /// Restoring a caret onto a line that gained a marker must place it after
    /// the marker, not before it.
    func testOffsetSkipsTheMarkerWhenRestoring() {
        let rendered = NotesRichText.attributed(markdown: "- abc")
        XCTAssertEqual(NotesRichText.utf16Offset(in: rendered, paragraph: 0, column: 0), 2)
    }
}
