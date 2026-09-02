import XCTest

final class RecordingStoreTests: XCTestCase {
    func testDictationRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-store-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = RecordingStore(directory: dir)
        try await store.saveDictation(text: "Erster Test", startedAt: Date(timeIntervalSince1970: 1000), duration: 2.5)
        try await store.saveDictation(text: "Zweiter Test", startedAt: Date(timeIntervalSince1970: 2000), duration: 1.0)

        let recent = try await store.recentDictations(limit: 10)
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent[0].text, "Zweiter Test") // newest first
        XCTAssertEqual(recent[1].text, "Erster Test")
    }

    /// The note is fully re-renderable from SQLite: summary, folder, title and
    /// segments all round-trip, and rename/move/re-summarize update the record.
    func testMeetingSourceOfTruthRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-store-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecordingStore(directory: dir)

        let id = UUID().uuidString
        let rec = RecordingStore.Recording(
            id: id, kind: .meeting, startedAt: Date(timeIntervalSince1970: 1000),
            endedAt: Date(timeIntervalSince1970: 1600), title: "Meeting",
            calendarEventID: nil, markdownPath: "/tmp/Inbox/a.md",
            summary: "## Zusammenfassung\nText.", subtitle: "Ein Satz.",
            folder: "Inbox", titleIsAuto: true
        )
        try await store.insertMeeting(rec, segments: [
            RecordingStore.Segment(speaker: "Ich", start: 0, end: 1, text: "Hallo."),
            RecordingStore.Segment(speaker: "Sprecher 1", start: 2, end: 3, text: "Antwort."),
        ])

        // Read the whole note back from the DB alone.
        let loaded = try await store.meeting(id: id)
        XCTAssertEqual(loaded?.recording.summary, "## Zusammenfassung\nText.")
        XCTAssertEqual(loaded?.recording.folder, "Inbox")
        XCTAssertEqual(loaded?.recording.titleIsAuto, true)
        XCTAssertEqual(loaded?.segments.count, 2)
        XCTAssertEqual(loaded?.segments.first?.speaker, "Ich")

        // Re-render the Markdown purely from the stored record.
        let note = MarkdownProjector.Note(
            title: loaded!.recording.title ?? "", date: loaded!.recording.startedAt,
            calendarEventTitle: nil,
            segments: loaded!.segments.map { ($0.speaker, $0.text) },
            summary: loaded!.recording.summary
        )
        let md = MarkdownProjector.render(note)
        XCTAssertTrue(md.contains("## Zusammenfassung"))
        XCTAssertTrue(md.contains("**Ich:** Hallo."))

        // Rename, re-summarize, move — each persists.
        try await store.updateTitle("Quartalsplanung", titleIsAuto: false, markdownPath: "/tmp/Inbox/q.md", for: id)
        try await store.setSummary("## Zusammenfassung\nNeu.", subtitle: "Neu.", for: id)
        try await store.updateLocation(folder: "Projekt X", markdownPath: "/tmp/Projekt X/q.md", for: id)

        let after = try await store.meeting(id: id)?.recording
        XCTAssertEqual(after?.title, "Quartalsplanung")
        XCTAssertEqual(after?.titleIsAuto, false)
        XCTAssertEqual(after?.summary, "## Zusammenfassung\nNeu.")
        XCTAssertEqual(after?.folder, "Projekt X")
        XCTAssertEqual(after?.markdownPath, "/tmp/Projekt X/q.md")

        let list = try await store.recentMeetings(limit: 10)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, id)
    }

    /// LLM spend is append-only and window-queryable: a retried summarization
    /// adds a second row for the same recording instead of replacing the first,
    /// so the totals report what was really spent.
    func testLLMUsageIsAppendedNotOverwritten() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-store-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecordingStore(directory: dir)

        let recordingID = UUID().uuidString
        func usage(_ at: TimeInterval, cost: Double, billed: Bool) -> RecordingStore.LLMUsage {
            RecordingStore.LLMUsage(
                recordingID: recordingID, provider: "anthropic-api", purpose: "summary",
                createdAt: Date(timeIntervalSince1970: at),
                inputTokens: 100, outputTokens: 20,
                cacheCreationTokens: 0, cacheReadTokens: 5,
                costUSD: cost, billed: billed
            )
        }
        try await store.insertLLMUsage(usage(1_000, cost: 0.2, billed: true))
        try await store.insertLLMUsage(usage(2_000, cost: 0.3, billed: true))
        try await store.insertLLMUsage(usage(9_000, cost: 1.0, billed: false))

        let all = try await store.llmUsageRows(from: .distantPast, to: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map(\.costUSD), [0.2, 0.3, 1.0]) // oldest first
        XCTAssertEqual(all.first?.recordingID, recordingID)
        XCTAssertEqual(all.first?.totalTokens, 125)
        XCTAssertEqual(all.last?.billed, false)

        // The window is half-open, like `usageRows`.
        let window = try await store.llmUsageRows(
            from: Date(timeIntervalSince1970: 1_000), to: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(window.count, 1)
        XCTAssertEqual(window.first?.costUSD, 0.2)
    }

    /// The spend of a meeting is booked before the recording row exists (the
    /// summary has to be in hand when the record is written), so `llm_usage`
    /// must accept a recording id that no row references yet.
    func testLLMUsageAcceptsIDOfNotYetInsertedRecording() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-store-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecordingStore(directory: dir)

        let recordingID = UUID().uuidString
        try await store.insertLLMUsage(RecordingStore.LLMUsage(
            recordingID: recordingID, provider: "claude-code-cli", purpose: "summary",
            createdAt: Date(timeIntervalSince1970: 500),
            inputTokens: 10, outputTokens: 1, cacheCreationTokens: 0, cacheReadTokens: 0,
            costUSD: 0.01, billed: false
        ))
        try await store.insert(RecordingStore.Recording(
            id: recordingID, kind: .meeting,
            startedAt: Date(timeIntervalSince1970: 400),
            endedAt: Date(timeIntervalSince1970: 900)
        ))
        let rows = try await store.llmUsageRows(from: .distantPast, to: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(rows.count, 1)
    }
}

final class RecentActivityTests: XCTestCase {
    private func makeStore() -> (RecordingStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-recent-test-\(UUID().uuidString)", isDirectory: true)
        return (RecordingStore(directory: dir), dir)
    }

    func testWindowFiltersByAge() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        // Inside 24h.
        try await store.saveDictation(text: "Frisch", startedAt: now.addingTimeInterval(-3600), duration: 4)
        // Outside 24h, inside 7 days.
        try await store.saveDictation(text: "Vorgestern", startedAt: now.addingTimeInterval(-2 * 24 * 3600), duration: 2)
        // Outside 7 days.
        try await store.saveDictation(text: "Uralt", startedAt: now.addingTimeInterval(-10 * 24 * 3600), duration: 1)

        let day = try await store.recentActivity(within: 24)
        XCTAssertEqual(day.count, 1)
        XCTAssertEqual(day.first?.snippet, "Frisch")

        let week = try await store.recentActivity(within: 168)
        XCTAssertEqual(week.count, 2)

        let all = try await store.recentActivity(within: 0)
        XCTAssertEqual(all.count, 3)
    }

    func testMixesDictationsAndMeetingsNewestFirst() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        try await store.saveDictation(text: "Ein Diktat", startedAt: now.addingTimeInterval(-7200), duration: 3)

        let meeting = RecordingStore.Recording(
            id: UUID().uuidString,
            kind: .meeting,
            startedAt: now.addingTimeInterval(-1800),
            endedAt: now.addingTimeInterval(-900),
            title: "Weekly Sync",
            markdownPath: "/notes/weekly.md"
        )
        try await store.insertMeeting(meeting, segments: [
            RecordingStore.Segment(speaker: "Ich", start: 0, end: 5, text: "Hallo zusammen."),
            RecordingStore.Segment(speaker: "Sprecher 1", start: 5, end: 10, text: "Guten Morgen."),
        ])

        let items = try await store.recentActivity(within: 24)
        XCTAssertEqual(items.count, 2)

        // Newest first: the meeting (30 min ago) precedes the dictation (2 h ago).
        XCTAssertEqual(items[0].kind, .meeting)
        XCTAssertEqual(items[0].title, "Weekly Sync")
        XCTAssertEqual(items[0].markdownPath, "/notes/weekly.md")
        XCTAssertEqual(items[0].snippet, "Hallo zusammen.") // first segment, not exploded per-segment
        XCTAssertEqual(items[0].duration ?? 0, 900, accuracy: 0.5)

        XCTAssertEqual(items[1].kind, .dictation)
        XCTAssertEqual(items[1].snippet, "Ein Diktat")
        XCTAssertNil(items[1].title)
        XCTAssertNil(items[1].markdownPath)
        XCTAssertEqual(items[1].duration ?? 0, 3, accuracy: 0.5)
    }

    func testEmptyWhenNothingInWindow() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.saveDictation(text: "Alt", startedAt: Date().addingTimeInterval(-48 * 3600), duration: 1)
        let day = try await store.recentActivity(within: 24)
        XCTAssertTrue(day.isEmpty)
    }
}

final class MarkdownProjectorTests: XCTestCase {
    /// The summary a provider returns is already structured Markdown with its
    /// own headings (## Zusammenfassung / ## Entscheidungen / ## Action Items,
    /// per SummarizationPrompt). The projector inserts it verbatim.
    private static let providerSummary = """
    ## Zusammenfassung
    Kurzes Standup.

    ## Entscheidungen
    - Keine.

    ## Action Items
    - Keine.
    """

    func testRendersFrontmatterSummaryAndTranscript() {
        let note = MarkdownProjector.Note(
            title: "Weekly Sync",
            date: Date(timeIntervalSince1970: 1_780_000_000),
            calendarEventTitle: "Weekly Sync (Team)",
            segments: [
                (speaker: "Alex", text: "Hallo zusammen."),
                (speaker: "Anna", text: "Guten Morgen."),
                (speaker: nil, text: "Unbekannter Sprecher."),
            ],
            summary: Self.providerSummary
        )

        let markdown = MarkdownProjector.render(note)
        XCTAssertTrue(markdown.hasPrefix("---\ntitle: \"Weekly Sync\""))
        XCTAssertTrue(markdown.contains("event: \"Weekly Sync (Team)\""))
        XCTAssertTrue(markdown.contains("## Zusammenfassung\nKurzes Standup."))
        XCTAssertTrue(markdown.contains("## Action Items"))
        XCTAssertTrue(markdown.contains("**Alex:** Hallo zusammen."))
        XCTAssertTrue(markdown.contains("\nUnbekannter Sprecher.\n"))
    }

    /// The field bug: a provider summary that already begins with
    /// "## Zusammenfassung" must not be wrapped in a second one.
    func testSummaryHeadingIsNotDuplicated() {
        let note = MarkdownProjector.Note(
            title: "Weekly Sync", date: Date(timeIntervalSince1970: 1_780_000_000),
            calendarEventTitle: nil,
            segments: [(speaker: "Ich", text: "Test.")],
            summary: Self.providerSummary
        )
        let markdown = MarkdownProjector.render(note)
        XCTAssertEqual(
            markdown.components(separatedBy: "## Zusammenfassung").count - 1, 1,
            "Doppelte Überschrift '## Zusammenfassung':\n\(markdown)"
        )
    }

    /// The user's own notes render verbatim under "## Eigene Notizen", before
    /// the summary; absent notes change nothing.
    func testUserNotesRenderVerbatimBeforeSummary() {
        let withNotes = MarkdownProjector.Note(
            title: "Sync", date: Date(timeIntervalSince1970: 1_780_000_000),
            calendarEventTitle: nil,
            segments: [(speaker: "Ich", text: "Text.")],
            summary: Self.providerSummary,
            userNotes: "Budget bis Q3 fixieren.\nAnna übernimmt Design."
        )
        let md = MarkdownProjector.render(withNotes)
        XCTAssertTrue(md.contains("## Eigene Notizen"))
        XCTAssertTrue(md.contains("Budget bis Q3 fixieren."))
        // Notes come before the summary.
        let notesIdx = md.range(of: "## Eigene Notizen")!.lowerBound
        let summaryIdx = md.range(of: "## Zusammenfassung")!.lowerBound
        XCTAssertTrue(notesIdx < summaryIdx)

        let noNotes = MarkdownProjector.Note(
            title: "Sync", date: Date(timeIntervalSince1970: 1_780_000_000),
            calendarEventTitle: nil, segments: [(speaker: "Ich", text: "Text.")],
            summary: Self.providerSummary, userNotes: nil
        )
        XCTAssertFalse(MarkdownProjector.render(noNotes).contains("## Eigene Notizen"))
    }

    /// No summary (transcript-first write, or a failed summary): no empty
    /// Zusammenfassung heading, transcript still present.
    func testNoSummarySectionWhenSummaryIsNil() {
        let note = MarkdownProjector.Note(
            title: "Weekly Sync", date: Date(timeIntervalSince1970: 1_780_000_000),
            calendarEventTitle: nil,
            segments: [(speaker: "Ich", text: "Test.")],
            summary: nil
        )
        let markdown = MarkdownProjector.render(note)
        XCTAssertFalse(markdown.contains("## Zusammenfassung"))
        XCTAssertTrue(markdown.contains("## Transkript"))
    }

    func testFileNameIsFilesystemSafe() {
        let name = MarkdownProjector.fileName(
            title: "Budget: Q3/Q4 Review?",
            date: Date(timeIntervalSince1970: 1_780_000_000)
        )
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("?"))
        XCTAssertTrue(name.hasSuffix(".md"))
    }

    /// A free name is returned verbatim; a taken name gains " (2)", " (3)", …;
    /// and `excluding` (the file being renamed onto its own path) never counts
    /// as a collision.
    func testUniqueFileNameAvoidsCollisions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-unique-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let base = MarkdownProjector.fileName(title: "Weekly Sync", date: date)

        // Nothing on disk yet → plain name.
        XCTAssertEqual(MarkdownProjector.uniqueFileName(title: "Weekly Sync", date: date, in: dir), base)

        // Occupy the plain name → " (2)".
        let baseURL = dir.appendingPathComponent(base)
        try "x".write(to: baseURL, atomically: true, encoding: .utf8)
        let stem = (base as NSString).deletingPathExtension
        let second = MarkdownProjector.uniqueFileName(title: "Weekly Sync", date: date, in: dir)
        XCTAssertEqual(second, "\(stem) (2).md")

        // Occupy " (2)" too → " (3)".
        try "y".write(to: dir.appendingPathComponent(second), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            MarkdownProjector.uniqueFileName(title: "Weekly Sync", date: date, in: dir),
            "\(stem) (3).md"
        )

        // Renaming a file onto its own path keeps its name (excluded).
        XCTAssertEqual(
            MarkdownProjector.uniqueFileName(title: "Weekly Sync", date: date, in: dir, excluding: baseURL),
            base
        )
    }
}
