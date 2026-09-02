import XCTest

final class ProviderAvailabilityTests: XCTestCase {
    func testAPIProviderUnavailableWithoutKey() async throws {
        try XCTSkipIf(
            KeychainStore.read(account: KeychainStore.anthropicAPIKeyAccount) != nil,
            "API-Key vorhanden — Negativtest nicht anwendbar."
        )
        let availability = await AnthropicAPIProvider().availability()
        guard case .unavailable(let reason) = availability else {
            return XCTFail("Ohne Key muss der Provider unavailable sein")
        }
        XCTAssertTrue(reason.contains("API-Key"))
    }

    func testServiceRejectsUnknownProvider() async {
        do {
            _ = try await SummarizationService.summarize(
                transcript: "x",
                context: MeetingContext(title: nil, date: .now, durationSeconds: nil),
                providerID: "does-not-exist"
            )
            XCTFail("Unbekannter Provider muss einen Fehler werfen")
        } catch {
            XCTAssertTrue("\(error)".contains("does-not-exist"))
        }
    }
}

final class RecordingStoreMeetingTests: XCTestCase {
    func testMeetingWithSegmentsPersists() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-store-meeting-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = RecordingStore(directory: dir)
        let recording = RecordingStore.Recording(
            id: "rec-1",
            kind: .meeting,
            startedAt: Date(timeIntervalSince1970: 500),
            endedAt: Date(timeIntervalSince1970: 560),
            title: "Standup",
            calendarEventID: "event-42",
            markdownPath: "/tmp/standup.md"
        )
        try await store.insert(recording)
        try await store.insert(
            RecordingStore.Segment(speaker: "Ich", start: 0, end: 4, text: "Hallo."),
            recordingID: recording.id
        )
        try await store.insert(
            RecordingStore.Segment(speaker: "Sprecher 1", start: 5, end: 9, text: "Guten Morgen."),
            recordingID: recording.id
        )

        // Meetings must not leak into the dictation history.
        let dictations = try await store.recentDictations(limit: 10)
        XCTAssertTrue(dictations.isEmpty)
    }
}
