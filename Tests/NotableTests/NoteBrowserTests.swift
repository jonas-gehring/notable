import XCTest
@testable import Notable

/// The notes window: which notes a folder and a search show, and how a
/// summary and a transcript are laid out.
final class NoteBrowserTests: XCTestCase {
    private func note(_ id: String, title: String?, folder: String?, subtitle: String? = nil) -> RecordingStore.Recording {
        var recording = RecordingStore.Recording(
            id: id, kind: .meeting,
            startedAt: Date(timeIntervalSince1970: 1000), endedAt: nil,
            title: title, calendarEventID: nil, markdownPath: nil
        )
        recording.folder = folder
        recording.subtitle = subtitle
        return recording
    }

    private lazy var notes = [
        note("a", title: "Budget-Review", folder: "Inbox"),
        note("b", title: "Kunde A Kickoff", folder: "Kunde A", subtitle: "Zeitplan steht"),
        note("c", title: "Alt", folder: nil),
        note("d", title: "Retro", folder: "inbox"),
    ]

    func testAllShowsEveryNoteIncludingThoseWithoutAFolder() {
        XCTAssertEqual(NoteBrowser.visible(notes, scope: .all, query: "").map(\.id), ["a", "b", "c", "d"])
    }

    func testAFolderShowsOnlyItsNotesAndInboxIgnoresCase() {
        XCTAssertEqual(NoteBrowser.visible(notes, scope: .folder("Inbox"), query: "").map(\.id), ["a", "d"])
        XCTAssertEqual(NoteBrowser.visible(notes, scope: .folder("Kunde A"), query: "").map(\.id), ["b"])
    }

    func testTheDictationsScopeListsNoNotes() {
        XCTAssertEqual(NoteBrowser.visible(notes, scope: .dictations, query: "").map(\.id), [])
    }

    func testSearchMatchesTitleSubtitleFolderAndTranscriptHits() {
        XCTAssertEqual(NoteBrowser.visible(notes, scope: .all, query: "budget").map(\.id), ["a"])
        XCTAssertEqual(NoteBrowser.visible(notes, scope: .all, query: "zeitplan").map(\.id), ["b"])
        XCTAssertEqual(NoteBrowser.visible(notes, scope: .all, query: "kunde a").map(\.id), ["b"])
        XCTAssertEqual(
            NoteBrowser.visible(notes, scope: .all, query: "angebot", transcriptHits: ["c"]).map(\.id), ["c"],
            "ein Treffer im Transkript zählt, auch wenn der Titel nicht passt"
        )
        XCTAssertEqual(
            NoteBrowser.visible(notes, scope: .folder("Kunde A"), query: "angebot", transcriptHits: ["c"]).map(\.id), [],
            "die Suche bleibt im gewählten Ordner"
        )
    }

    func testSummaryMarkdownBecomesBlocks() {
        let blocks = NoteBrowser.blocks(fromMarkdown: """
        ## Entscheidungen

        - Budget **freigegeben**
          - bis Q3
        - [ ] Angebot schicken
        Weiter im November.
        """)
        XCTAssertEqual(blocks, [
            .heading("Entscheidungen"),
            .bullet("Budget **freigegeben**", level: 0),
            .bullet("bis Q3", level: 1),
            .bullet("☐ Angebot schicken", level: 0),
            .paragraph("Weiter im November."),
        ])
    }

    func testConsecutiveSegmentsOfOneSpeakerAreOneTurn() {
        let turns = NoteBrowser.turns([
            RecordingStore.Segment(speaker: "Ich", start: 0, end: 2, text: "Hallo."),
            RecordingStore.Segment(speaker: "Ich", start: 2, end: 4, text: "Kurz zum Budget."),
            RecordingStore.Segment(speaker: "Sprecher 1", start: 5, end: 7, text: "Passt."),
            RecordingStore.Segment(speaker: "Sprecher 1", start: 7, end: 8, text: "  "),
        ])
        XCTAssertEqual(turns, [
            NoteBrowser.Turn(speaker: "Ich", start: 0, text: "Hallo. Kurz zum Budget."),
            NoteBrowser.Turn(speaker: "Sprecher 1", start: 5, text: "Passt."),
        ])
    }

    func testTimestamps() {
        XCTAssertEqual(NoteBrowser.timestamp(291), "04:51")
        XCTAssertEqual(NoteBrowser.timestamp(3753), "1:02:33")
    }
}
