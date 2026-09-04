import XCTest
@testable import Notable

/// Issue #2, the SQLite half. The whole point of clearing *text* instead of
/// deleting *rows* is that the statistics must read identically afterwards — so
/// that is what these tests measure, before and after.
final class RetentionStoreTests: XCTestCase {
    private func makeStore() -> (RecordingStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-retention-\(UUID().uuidString)", isDirectory: true)
        return (RecordingStore(directory: dir), dir)
    }

    private let old = Date(timeIntervalSince1970: 1_000_000)
    private let recent = Date(timeIntervalSince1970: 1_756_000_000)

    func testClearingTextKeepsTheRowAndTheWordCount() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.saveDictation(text: "Ein alter Satz mit sechs Wörtern hier", startedAt: old, duration: 4)
        try await store.saveDictation(text: "Ein neuer Satz", startedAt: recent, duration: 2)

        let before = try await store.usageRows(from: .distantPast, to: .distantFuture)
        let cleared = try await store.clearSegmentText(olderThan: recent, kind: .dictation)
        XCTAssertEqual(cleared, 1)

        let after = try await store.usageRows(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(after.count, before.count, "eine Zeile darf nicht verschwinden")
        XCTAssertEqual(after.map(\.wordCount), before.map(\.wordCount), "word_count trägt die Statistik")
        XCTAssertEqual(after.map(\.startedAt), before.map(\.startedAt))
        XCTAssertEqual(after.map(\.endedAt), before.map(\.endedAt))

        // The text itself is gone, and the emptied row no longer surfaces at
        // all: it used to become a blank line in the menu whose "Einfügen"
        // pasted an empty string. The newer dictation is untouched.
        let texts = try await store.recentDictations(limit: 10).map(\.text)
        XCTAssertEqual(texts, ["Ein neuer Satz"])
    }

    /// The enhanced-dictation path stores the rule-polished original in
    /// `recordings.raw_text` — a second copy of the text, in a second table.
    /// Clearing only `segments.text` left it behind and handed it right back.
    func testClearingAlsoDropsThePreEnhancementText() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.saveDictation(
            text: "Der verbesserte Text.",
            startedAt: old,
            duration: 4,
            rawText: "Der ursprüngliche, regelpolierte Text."
        )
        let stored = try await store.recentDictations(limit: 10)
        XCTAssertEqual(stored.first?.rawText, "Der ursprüngliche, regelpolierte Text.")

        try await store.clearSegmentText(olderThan: recent, kind: .dictation)

        let remaining = try await store.recentDictations(limit: 10)
        XCTAssertTrue(remaining.isEmpty, "geleertes Diktat taucht nicht mehr auf")

        // …and the statistics still count it.
        let rows = try await store.usageRows(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(rows.count, 1)
        XCTAssertGreaterThan(rows[0].wordCount ?? 0, 0)
    }

    func testClearingDictationsLeavesMeetingsAlone() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID().uuidString
        try await store.insertMeeting(
            RecordingStore.Recording(id: id, kind: .meeting, startedAt: old, endedAt: old.addingTimeInterval(600),
                                     title: "Alt", calendarEventID: nil, markdownPath: nil),
            segments: [RecordingStore.Segment(speaker: "Ich", start: 0, end: 1, text: "Hallo.")]
        )
        try await store.saveDictation(text: "Ein alter Satz", startedAt: old, duration: 2)

        let clearedDictations = try await store.clearSegmentText(olderThan: recent, kind: .dictation)
        XCTAssertEqual(clearedDictations, 1)
        let meetingText = try await store.meeting(id: id)?.segments.first?.text
        XCTAssertEqual(meetingText, "Hallo.")

        let clearedMeetings = try await store.clearSegmentText(olderThan: recent, kind: .meeting)
        XCTAssertEqual(clearedMeetings, 1)
        let clearedText = try await store.meeting(id: id)?.segments.first?.text
        XCTAssertEqual(clearedText, "")
    }

    /// Running twice must not report work it did not do — the second pass finds
    /// nothing left to clear.
    func testClearingIsIdempotent() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.saveDictation(text: "Alt", startedAt: old, duration: 1)
        let first = try await store.clearSegmentText(olderThan: recent, kind: .dictation)
        XCTAssertEqual(first, 1)
        let second = try await store.clearSegmentText(olderThan: recent, kind: .dictation)
        XCTAssertEqual(second, 0, "der zweite Lauf hat nichts mehr zu tun")
    }

    /// `llm_usage` is the ledger: it says what was actually spent, and that stays
    /// true after the meeting it belonged to is gone.
    func testLLMUsageSurvivesEveryCleanup() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID().uuidString
        try await store.insertMeeting(
            RecordingStore.Recording(id: id, kind: .meeting, startedAt: old, endedAt: old.addingTimeInterval(600),
                                     title: "Alt", calendarEventID: nil, markdownPath: nil),
            segments: [RecordingStore.Segment(speaker: "Ich", start: 0, end: 1, text: "Hallo.")]
        )
        try await store.insertLLMUsage(RecordingStore.LLMUsage(
            recordingID: id, provider: "anthropic-api", purpose: "summary", createdAt: old,
            inputTokens: 1000, outputTokens: 200, cacheCreationTokens: 0, cacheReadTokens: 0,
            costUSD: 0.012, billed: true
        ))
        try await store.appendChatMessage(recordingID: id, role: "user", text: "Frage?", createdAt: old)

        let before = try await store.llmUsageRows(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(before.count, 1)

        try await store.clearSegmentText(olderThan: recent, kind: .meeting)
        let deletedChats = try await store.deleteChatMessages(olderThan: recent)
        XCTAssertEqual(deletedChats, 1)

        let after = try await store.llmUsageRows(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.costUSD, before.first?.costUSD)
        XCTAssertEqual(after.first?.billed, true)
    }

    func testChatDeletionRespectsTheCutoff() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID().uuidString
        try await store.insertMeeting(
            RecordingStore.Recording(id: id, kind: .meeting, startedAt: old, endedAt: nil,
                                     title: "Alt", calendarEventID: nil, markdownPath: nil),
            segments: []
        )
        try await store.appendChatMessage(recordingID: id, role: "user", text: "alt", createdAt: old)
        try await store.appendChatMessage(recordingID: id, role: "user", text: "neu", createdAt: recent)

        let deleted = try await store.deleteChatMessages(olderThan: recent)
        XCTAssertEqual(deleted, 1)
        let remaining = try await store.chatMessages(for: id).map(\.text)
        XCTAssertEqual(remaining, ["neu"])
    }
}
