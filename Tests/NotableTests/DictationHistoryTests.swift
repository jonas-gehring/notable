import XCTest

final class DictationHistoryTests: XCTestCase {
    // MARK: - menuTitle (pure)

    func testShortTextIsUnchanged() {
        XCTAssertEqual(DictationHistory.menuTitle(for: "Kurzes Diktat"), "Kurzes Diktat")
    }

    func testWhitespaceAndNewlinesCollapseToSingleSpaces() {
        let messy = "Erste  Zeile\n\nZweite\tZeile"
        XCTAssertEqual(DictationHistory.menuTitle(for: messy), "Erste Zeile Zweite Zeile")
    }

    func testLeadingAndTrailingWhitespaceIsTrimmed() {
        XCTAssertEqual(DictationHistory.menuTitle(for: "  hallo  "), "hallo")
    }

    func testLongTextIsClippedWithEllipsis() {
        let long = String(repeating: "a", count: 100)
        let title = DictationHistory.menuTitle(for: long, limit: 10)
        XCTAssertEqual(title, String(repeating: "a", count: 10) + "…")
        // The ellipsis is one character on top of the cap.
        XCTAssertEqual(title.count, 11)
    }

    func testClipDoesNotLeaveTrailingSpaceBeforeEllipsis() {
        // Cap falls on a space → the space is trimmed, not shown before "…".
        let title = DictationHistory.menuTitle(for: "hallo welt zusammen", limit: 6)
        XCTAssertEqual(title, "hallo…")
    }

    func testExactlyAtLimitIsNotClipped() {
        let text = String(repeating: "x", count: 10)
        XCTAssertEqual(DictationHistory.menuTitle(for: text, limit: 10), text)
    }

    // MARK: - refresh / last (integration against a temp store)

    @MainActor
    func testRefreshLoadsNewestFirst() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-history-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = RecordingStore(directory: dir)
        try await store.saveDictation(text: "Erstes", startedAt: Date(timeIntervalSince1970: 1000), duration: 1)
        try await store.saveDictation(text: "Zweites", startedAt: Date(timeIntervalSince1970: 2000), duration: 1)

        let history = DictationHistory(store: store, limit: 8)
        XCTAssertNil(history.last) // nothing loaded yet
        await history.refresh()

        XCTAssertEqual(history.recent.map(\.text), ["Zweites", "Erstes"])
        XCTAssertEqual(history.last?.text, "Zweites")
        XCTAssertEqual(history.recent.map(\.id), [0, 1]) // newest = 0
    }

    @MainActor
    func testCopyLastReturnsFalseOnEmptyHistory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-history-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let history = DictationHistory(store: RecordingStore(directory: dir))
        let copied = await history.copyLast()
        XCTAssertFalse(copied)
    }
}
