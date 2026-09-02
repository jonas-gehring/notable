import XCTest

final class SearchTests: XCTestCase {
    func testSearchFindsDictationsAndMeetings() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecordingStore(directory: dir)

        try await store.saveDictation(
            text: "Bitte das Budgetdokument für Quartal drei aktualisieren.",
            startedAt: Date(timeIntervalSince1970: 1000),
            duration: 3
        )
        let meeting = RecordingStore.Recording(
            id: "m1", kind: .meeting,
            startedAt: Date(timeIntervalSince1970: 2000), endedAt: nil,
            title: "Budget-Review", calendarEventID: nil, markdownPath: "/tmp/budget.md"
        )
        try await store.insert(meeting)
        try await store.insert(
            RecordingStore.Segment(speaker: "Ich", start: 0, end: 5, text: "Wir sprechen über das Budget."),
            recordingID: meeting.id
        )

        let hits = try await store.search("budget")
        XCTAssertEqual(hits.count, 2, "Ein Treffer pro passendem Segment erwartet")
        XCTAssertEqual(hits.first?.kind, .meeting, "Neueste zuerst")
        XCTAssertEqual(hits.first?.markdownPath, "/tmp/budget.md")

        // LIKE wildcards in the query must be treated literally.
        let wildcard = try await store.search("%")
        XCTAssertTrue(wildcard.isEmpty)

        let none = try await store.search("existiertnicht")
        XCTAssertTrue(none.isEmpty)
    }

    func testSnippetCentersOnMatch() {
        let text = String(repeating: "a", count: 200) + " Zieltreffer " + String(repeating: "b", count: 200)
        let snippet = RecordingStore.snippet(around: "zieltreffer", in: text)
        XCTAssertTrue(snippet.contains("Zieltreffer"))
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertLessThan(snippet.count, 160)
    }
}

final class ValidateKeyTests: XCTestCase {
    func testValidateKeyWithoutStoredKey() async throws {
        try XCTSkipIf(
            KeychainStore.read(account: KeychainStore.anthropicAPIKeyAccount) != nil,
            "API-Key vorhanden — Negativtest nicht anwendbar."
        )
        let result = await AnthropicAPIProvider.validateKey()
        XCTAssertEqual(result, "Kein Key hinterlegt.")
    }
}
