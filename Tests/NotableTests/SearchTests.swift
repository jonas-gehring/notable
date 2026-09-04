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
        // Two text hits (both segments) plus one title hit for "Budget-Review".
        XCTAssertEqual(hits.count, 3, "Ein Treffer pro passendem Segment, plus einer für den Titel")
        XCTAssertEqual(hits.first?.kind, .meeting, "Neueste zuerst")
        XCTAssertEqual(hits.first?.markdownPath, "/tmp/budget.md")
        // Prefix search: "Budgetdokument" is found by typing "budget".
        XCTAssertTrue(hits.contains { $0.kind == .dictation }, "Präfix-Treffer im Diktat fehlt")

        // LIKE wildcards in the query must be treated literally.
        let wildcard = try await store.search("%")
        XCTAssertTrue(wildcard.isEmpty)

        let none = try await store.search("existiertnicht")
        XCTAssertTrue(none.isEmpty)
    }

    /// A title match belongs to the *recording*, not to each of its segments.
    ///
    /// As one query with `OR r.title LIKE …` over the segment join, this
    /// produced one identical row per segment — a long meeting filled the whole
    /// result list with copies of itself, each carrying a snippet that did not
    /// contain the search term.
    func testTitleMatchYieldsOneHitNotOnePerSegment() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecordingStore(directory: dir)

        let meeting = RecordingStore.Recording(
            id: "m1", kind: .meeting,
            startedAt: Date(timeIntervalSince1970: 2000), endedAt: nil,
            title: "Quartalsplanung", calendarEventID: nil, markdownPath: "/tmp/q.md"
        )
        try await store.insert(meeting)
        for index in 0..<40 {
            try await store.insert(
                RecordingStore.Segment(
                    speaker: "Sprecher 1", start: Double(index), end: Double(index) + 1,
                    text: "Ein Satz ohne das gesuchte Wort."
                ),
                recordingID: meeting.id
            )
        }

        let hits = try await store.search("Quartalsplanung")
        XCTAssertEqual(hits.count, 1, "Ein Titel-Treffer, nicht einer pro Segment")
        XCTAssertEqual(hits.first?.recordingID, "m1")
    }

    /// The old `LIKE` folded ASCII only, so a capital umlaut was unreachable —
    /// while the snippet rendered next to it *was* diacritic-insensitive.
    func testSearchIsCaseAndDiacriticInsensitive() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecordingStore(directory: dir)

        try await store.saveDictation(
            text: "Übermorgen sprechen wir über die Änderung.",
            startedAt: Date(timeIntervalSince1970: 1000),
            duration: 3
        )
        let lower = try await store.search("über")
        XCTAssertFalse(lower.isEmpty, "Kleinschreibung muss Ü finden")
        let ascii = try await store.search("UBER")
        XCTAssertFalse(ascii.isEmpty, "Ohne Umlaut muss ebenfalls treffen")
    }

    /// Retention empties segment text in place; an emptied segment must leave
    /// the index with it, or search keeps returning rows with no content.
    func testClearedSegmentsDisappearFromSearch() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecordingStore(directory: dir)

        try await store.saveDictation(
            text: "Vertrauliches Stichwort Zebrastreifen.",
            startedAt: Date(timeIntervalSince1970: 1000),
            duration: 3
        )
        let before = try await store.search("Zebrastreifen")
        XCTAssertFalse(before.isEmpty)

        _ = try await store.clearSegmentText(olderThan: Date(timeIntervalSince1970: 5000), kind: .dictation)
        let after = try await store.search("Zebrastreifen")
        XCTAssertTrue(after.isEmpty, "Geleerter Text darf nicht mehr gefunden werden")
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
