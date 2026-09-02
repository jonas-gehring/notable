import XCTest

/// Pure core of the notes typed during a call: timestamp rendering, where a
/// stamp may be spliced in, and what survives into the note.
final class LiveNotesTests: XCTestCase {
    // MARK: - timestamp

    func testTimestampIsZeroPaddedMinutesAndSeconds() {
        XCTAssertEqual(LiveNotes.timestamp(elapsed: 0), "[00:00]")
        XCTAssertEqual(LiveNotes.timestamp(elapsed: 9), "[00:09]")
        XCTAssertEqual(LiveNotes.timestamp(elapsed: 291), "[04:51]")
        XCTAssertEqual(LiveNotes.timestamp(elapsed: 3599), "[59:59]")
    }

    func testTimestampGrowsAnHoursFieldPastOneHour() {
        XCTAssertEqual(LiveNotes.timestamp(elapsed: 3600), "[1:00:00]")
        XCTAssertEqual(LiveNotes.timestamp(elapsed: 3753), "[1:02:33]")
    }

    /// A clock jumping backwards mid-call must not render "[-1:-30]".
    func testNegativeElapsedClampsToZero() {
        XCTAssertEqual(LiveNotes.timestamp(elapsed: -90), "[00:00]")
    }

    func testTimestampRoundsToTheNearestSecond() {
        XCTAssertEqual(LiveNotes.timestamp(elapsed: 61.6), "[01:02]")
    }

    // MARK: - timestampInsertion

    func testStampAtTheStartOfAnEmptyBufferHasNoLeadingNewline() {
        XCTAssertEqual(
            LiveNotes.timestampInsertion(elapsed: 12, characterBeforeCaret: nil),
            "[00:12] ")
    }

    func testStampAfterAFreshNewlineDoesNotAddASecondOne() {
        XCTAssertEqual(
            LiveNotes.timestampInsertion(elapsed: 12, characterBeforeCaret: "\n"),
            "[00:12] ")
    }

    func testStampMidLineOpensItsOwnLine() {
        XCTAssertEqual(
            LiveNotes.timestampInsertion(elapsed: 12, characterBeforeCaret: "t"),
            "\n[00:12] ")
    }

    // MARK: - character(in:beforeUTF16Offset:)

    func testCharacterBeforeCaretReadsTheUTF16Offset() {
        let text = "Budget\nAnna"
        XCTAssertNil(LiveNotes.character(in: text, beforeUTF16Offset: 0))
        XCTAssertEqual(LiveNotes.character(in: text, beforeUTF16Offset: 6), "t")
        XCTAssertEqual(LiveNotes.character(in: text, beforeUTF16Offset: 7), "\n")
        XCTAssertEqual(LiveNotes.character(in: text, beforeUTF16Offset: 11), "a")
    }

    /// AppKit reports UTF-16 offsets, so a caret past an emoji must not trap.
    func testCharacterBeforeCaretHandlesNonBMPTextAndOutOfRangeOffsets() {
        let text = "ok 👍"
        XCTAssertEqual(LiveNotes.character(in: text, beforeUTF16Offset: text.utf16.count), "👍")
        XCTAssertEqual(LiveNotes.character(in: text, beforeUTF16Offset: 999), "👍")
        XCTAssertNil(LiveNotes.character(in: "", beforeUTF16Offset: 3))
    }

    // MARK: - storable

    func testWhitespaceOnlyNotesAreNotStored() {
        XCTAssertNil(LiveNotes.storable(""))
        XCTAssertNil(LiveNotes.storable("   \n\n\t "))
    }

    func testStorableTrimsButKeepsInnerStructure() {
        XCTAssertEqual(
            LiveNotes.storable("\n  [00:12] Budget\n\n[04:51] Anna  \n"),
            "[00:12] Budget\n\n[04:51] Anna")
    }

}

/// The controller's one concurrency contract: the buffer lives on the main actor,
/// the debounced mirror into the spool must not. It used to hand a main-actor
/// closure to `DispatchQueue.global()`, which trips Swift 6's executor check and
/// **traps the process** on the first keystroke of every meeting — so this test
/// crashes outright on a regression rather than merely failing.
@MainActor
final class LiveNotesAutosaveTests: XCTestCase {

    private func makeSpool() throws -> (SpoolStore.Session, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-livenotes-\(UUID().uuidString)", isDirectory: true)
        let session = try SpoolStore.create(
            meta: SpoolStore.Meta(startedAt: Date(), eventTitle: nil, eventID: nil), base: base)
        return (session, base)
    }

    /// The debounce is 0.8 s — 2 s of slack keeps this off a loaded CI machine's edge.
    private func waitForAutosave() async throws {
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    func testTypedNotesReachTheSpool() async throws {
        let (session, base) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: base) }

        let controller = LiveNotesController()
        controller.begin(startedAt: Date(), title: "Standup", spool: session)
        controller.text = "[00:12] Budget klären"

        try await waitForAutosave()
        XCTAssertEqual(SpoolStore.readNotes(session), "[00:12] Budget klären")
    }

    /// Only the last keystroke survives the debounce — an intermediate buffer must
    /// never win a race against the final one.
    func testOnlyTheLastEditIsWritten() async throws {
        let (session, base) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: base) }

        let controller = LiveNotesController()
        controller.begin(startedAt: Date(), title: "Standup", spool: session)
        controller.text = "Erst"
        controller.text = "Erst und dann"

        try await waitForAutosave()
        XCTAssertEqual(SpoolStore.readNotes(session), "Erst und dann")
    }

    /// `finish()` flushes synchronously and detaches the spool; a pending autosave
    /// from before must not resurrect the notes afterwards.
    func testFinishFlushesAndStopsFurtherWrites() async throws {
        let (session, base) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: base) }

        let controller = LiveNotesController()
        controller.begin(startedAt: Date(), title: "Standup", spool: session)
        controller.text = "Ergebnis: ja"
        XCTAssertEqual(controller.finish(), "Ergebnis: ja")
        XCTAssertEqual(SpoolStore.readNotes(session), "Ergebnis: ja", "flushed synchronously")

        controller.text = "danach getippt"
        try await waitForAutosave()
        XCTAssertEqual(SpoolStore.readNotes(session), "Ergebnis: ja", "no spool ⇒ no further writes")
    }
}
