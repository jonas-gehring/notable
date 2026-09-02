import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite (WAL) is the source of truth for recordings and transcript
/// segments; Markdown files in the user's notes folder are a projection.
/// Actor-confined — SQLite handles are not thread-safe.
actor RecordingStore {
    enum Kind: String, Sendable {
        case dictation
        case meeting
    }

    struct Recording: Sendable, Identifiable {
        let id: String
        let kind: Kind
        let startedAt: Date
        var endedAt: Date?
        var title: String?
        var calendarEventID: String?
        var markdownPath: String?
        /// The provider's structured summary Markdown. Stored here (not only in
        /// the .md file) so a note is fully re-renderable from SQLite — the
        /// source of truth — after a rename/move or a schema change.
        var summary: String? = nil
        /// One-line TL;DR for list views (auto-generated).
        var subtitle: String? = nil
        /// Project-folder key ("Inbox" by default) for the Inbox→project move.
        var folder: String? = nil
        /// True when the title was auto-generated (no calendar event), so it may
        /// be regenerated; a user edit sets this false.
        var titleIsAuto: Bool = false
        /// The user's own free-text notes — kept verbatim in the .md (safety) and
        /// woven into the summary. Default nil keeps notes-free behavior identical.
        var userNotes: String? = nil
        /// Word count of the recording's text, stored at insert time so usage
        /// statistics never have to re-scan segment text. nil on rows written
        /// before this column existed (backfilled once on launch).
        var wordCount: Int? = nil
        /// Which transcriber produced the text ("parakeet-v3", "unified-en",
        /// "whisper-<size>"). nil on rows written before issue #5.
        var engine: String? = nil
        /// Whole-clip transcription latency in milliseconds.
        var latencyMs: Int? = nil
        /// Bundle ID of the app the text was pasted into. Stays in SQLite: it is
        /// never put in a prompt or sent anywhere.
        var sourceApp: String? = nil
        /// True once an explicit LLM enhancement pass ran over the text.
        var enhanced: Bool = false
        /// The rule-polished text as it was before the enhancement. nil when
        /// nothing was enhanced — otherwise it would be impossible to see what
        /// the model did.
        var rawText: String? = nil
    }

    struct Segment: Sendable {
        var speaker: String?
        var start: TimeInterval
        var end: TimeInterval?
        var text: String
    }

    /// One recording, reduced to what the statistics layer reads. A struct rather
    /// than a tuple since issue #5 added four more fields — the stats layer maps
    /// it into its own pure `UsageRow`.
    struct UsageRecord: Sendable {
        let kind: Kind
        let startedAt: Date
        let endedAt: Date?
        let wordCount: Int?
        let engine: String?
        let latencyMs: Int?
        let sourceApp: String?
        let enhanced: Bool
    }

    /// One provider round-trip's token spend, as stored.
    ///
    /// Append-only by design: a retried or re-run summarization adds a row
    /// instead of overwriting one, so the totals say what was actually spent
    /// rather than what the last attempt cost. Deliberately scalar — the store
    /// must not depend upward on the Summarization layer's `SummarizationUsage`
    /// (`UsageRecorder` maps between the two).
    struct LLMUsage: Sendable, Equatable {
        var recordingID: String?
        var provider: String
        var purpose: String
        var createdAt: Date
        var inputTokens: Int
        var outputTokens: Int
        var cacheCreationTokens: Int
        var cacheReadTokens: Int
        /// USD for this one call. Real money only when `billed` is true.
        var costUSD: Double
        /// True for the metered API, false for a flat-rate subscription via the
        /// CLI, whose reported cost is what the call *would* have cost.
        var billed: Bool

        var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
    }

    enum StoreError: Error, LocalizedError {
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case .sqlite(let message): "SQLite: \(message)"
            }
        }
    }

    static let shared = RecordingStore()

    /// Owns the SQLite handle; its plain deinit closes the connection
    /// (an actor's deinit cannot touch non-Sendable state on macOS < 15.4).
    private final class Connection: @unchecked Sendable {
        let handle: OpaquePointer
        init(handle: OpaquePointer) { self.handle = handle }
        deinit { sqlite3_close_v2(handle) }
    }

    private let databaseURL: URL
    private var connection: Connection?

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notable", isDirectory: true)
        databaseURL = base.appendingPathComponent("notable.sqlite")
    }

    // MARK: - Public API

    /// The measurement parameters default to nil so every existing caller and test
    /// stays valid — and so a row that genuinely does not know its engine says so
    /// rather than claiming one.
    func saveDictation(
        text: String,
        startedAt: Date,
        duration: TimeInterval,
        engine: String? = nil,
        latencyMs: Int? = nil,
        sourceApp: String? = nil,
        enhanced: Bool = false,
        rawText: String? = nil
    ) throws {
        let recording = Recording(
            id: UUID().uuidString,
            kind: .dictation,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            wordCount: Self.wordCount(text),
            engine: engine,
            latencyMs: latencyMs,
            sourceApp: sourceApp,
            enhanced: enhanced,
            rawText: rawText
        )
        try insert(recording)
        try insert(Segment(speaker: nil, start: 0, end: duration, text: text), recordingID: recording.id)
    }

    /// Whitespace-separated token count. Kept local to the store (rather than
    /// depending on the stats layer) so persistence has no upward dependency.
    static func wordCount(_ text: String) -> Int {
        text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }

    func insert(_ recording: Recording) throws {
        let sql = """
        INSERT INTO recordings
            (id, kind, started_at, ended_at, title, calendar_event_id, markdown_path,
             summary, subtitle, folder, title_is_auto, user_notes, word_count,
             engine, latency_ms, source_app, enhanced, raw_text)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
        """
        try run(sql) { statement in
            bind(statement, 1, recording.id)
            bind(statement, 2, recording.kind.rawValue)
            sqlite3_bind_double(statement, 3, recording.startedAt.timeIntervalSince1970)
            bind(statement, 4, recording.endedAt?.timeIntervalSince1970)
            bind(statement, 5, recording.title)
            bind(statement, 6, recording.calendarEventID)
            bind(statement, 7, recording.markdownPath)
            bind(statement, 8, recording.summary)
            bind(statement, 9, recording.subtitle)
            bind(statement, 10, recording.folder)
            sqlite3_bind_int(statement, 11, recording.titleIsAuto ? 1 : 0)
            bind(statement, 12, recording.userNotes)
            if let wordCount = recording.wordCount {
                sqlite3_bind_int(statement, 13, Int32(wordCount))
            } else {
                sqlite3_bind_null(statement, 13)
            }
            bind(statement, 14, recording.engine)
            if let latencyMs = recording.latencyMs {
                sqlite3_bind_int(statement, 15, Int32(latencyMs))
            } else {
                sqlite3_bind_null(statement, 15)
            }
            bind(statement, 16, recording.sourceApp)
            sqlite3_bind_int(statement, 17, recording.enhanced ? 1 : 0)
            bind(statement, 18, recording.rawText)
        }
    }

    func insert(_ segment: Segment, recordingID: String) throws {
        let sql = """
        INSERT INTO segments (recording_id, speaker, start_seconds, end_seconds, text)
        VALUES (?1, ?2, ?3, ?4, ?5)
        """
        try run(sql) { statement in
            bind(statement, 1, recordingID)
            bind(statement, 2, segment.speaker)
            sqlite3_bind_double(statement, 3, segment.start)
            bind(statement, 4, segment.end)
            bind(statement, 5, segment.text)
        }
    }

    /// Atomic insert of a meeting with all its segments — a partial write
    /// must not leave orphaned rows.
    func insertMeeting(_ recording: Recording, segments: [Segment]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try insert(recording)
            for segment in segments {
                try insert(segment, recordingID: recording.id)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Reads & edits (SQLite is the source of truth)

    private static let recordingColumns =
        "id, kind, started_at, ended_at, title, calendar_event_id, markdown_path, summary, subtitle, folder, title_is_auto, user_notes, word_count"

    /// Reads a full Recording from a prepared statement whose columns are
    /// `recordingColumns` in order.
    private func readRecording(_ s: OpaquePointer?) -> Recording {
        func text(_ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
        func date(_ i: Int32) -> Date? {
            sqlite3_column_type(s, i) == SQLITE_NULL ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(s, i))
        }
        return Recording(
            id: text(0) ?? "",
            kind: Kind(rawValue: text(1) ?? "") ?? .meeting,
            startedAt: date(2) ?? Date(timeIntervalSince1970: 0),
            endedAt: date(3),
            title: text(4),
            calendarEventID: text(5),
            markdownPath: text(6),
            summary: text(7),
            subtitle: text(8),
            folder: text(9),
            titleIsAuto: sqlite3_column_int(s, 10) != 0,
            userNotes: text(11),
            wordCount: sqlite3_column_type(s, 12) == SQLITE_NULL ? nil : Int(sqlite3_column_int(s, 12))
        )
    }

    /// Recent meetings for the note list, newest first.
    func recentMeetings(limit: Int = 100) throws -> [Recording] {
        let sql = "SELECT \(Self.recordingColumns) FROM recordings WHERE kind = 'meeting' ORDER BY started_at DESC LIMIT ?1"
        let handle = try ensureOpen()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(lastMessage(handle))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var rows: [Recording] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(readRecording(statement)) }
        return rows
    }

    /// A recording plus its segments — enough to re-render the whole note from
    /// SQLite (rename/move/regenerate all round-trip through this).
    func meeting(id: String) throws -> (recording: Recording, segments: [Segment])? {
        let sql = "SELECT \(Self.recordingColumns) FROM recordings WHERE id = ?1"
        let handle = try ensureOpen()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(lastMessage(handle))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let recording = readRecording(statement)
        return (recording, try segments(for: id))
    }

    /// Transcript segments for a recording, in chronological order.
    func segments(for recordingID: String) throws -> [Segment] {
        let sql = "SELECT speaker, start_seconds, end_seconds, text FROM segments WHERE recording_id = ?1 ORDER BY start_seconds ASC"
        let handle = try ensureOpen()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(lastMessage(handle))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, recordingID, -1, sqliteTransient)
        var rows: [Segment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(Segment(
                speaker: sqlite3_column_text(statement, 0).map { String(cString: $0) },
                start: sqlite3_column_double(statement, 1),
                end: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2),
                text: sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            ))
        }
        return rows
    }

    /// Stores the user's own notes for a recording (edited from the note window).
    func setUserNotes(_ notes: String?, for id: String) throws {
        try run("UPDATE recordings SET user_notes = ?1 WHERE id = ?2") { s in
            bind(s, 1, notes)
            bind(s, 2, id)
        }
    }

    /// Stores the summary (and optional subtitle) once summarization succeeds.
    func setSummary(_ summary: String?, subtitle: String? = nil, for id: String) throws {
        try run("UPDATE recordings SET summary = ?1, subtitle = ?2 WHERE id = ?3") { s in
            bind(s, 1, summary)
            bind(s, 2, subtitle)
            bind(s, 3, id)
        }
    }

    /// Renames a note: the title, its file path, and whether it is still
    /// auto-generated all move together. Caller writes the .md file itself.
    func updateTitle(_ title: String, titleIsAuto: Bool, markdownPath: String?, for id: String) throws {
        try run("UPDATE recordings SET title = ?1, title_is_auto = ?2, markdown_path = ?3 WHERE id = ?4") { s in
            bind(s, 1, title)
            sqlite3_bind_int(s, 2, titleIsAuto ? 1 : 0)
            bind(s, 3, markdownPath)
            bind(s, 4, id)
        }
    }

    /// Moves a note between folders (Inbox → project). Caller moves the file.
    func updateLocation(folder: String?, markdownPath: String?, for id: String) throws {
        try run("UPDATE recordings SET folder = ?1, markdown_path = ?2 WHERE id = ?3") { s in
            bind(s, 1, folder)
            bind(s, 2, markdownPath)
            bind(s, 3, id)
        }
    }

    /// Most recent dictations, newest first.
    func recentDictations(limit: Int = 20) throws -> [(date: Date, text: String, rawText: String?)] {
        let sql = """
        SELECT r.started_at, s.text, r.raw_text
        FROM recordings r JOIN segments s ON s.recording_id = r.id
        WHERE r.kind = 'dictation'
        ORDER BY r.started_at DESC
        LIMIT ?1
        """
        let handle = try ensureOpen()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(lastMessage(handle))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var rows: [(date: Date, text: String, rawText: String?)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let text = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            // Non-nil only where an enhancement actually replaced something —
            // that is what makes the change visible after the fact.
            let rawText = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            rows.append((date, text, rawText))
        }
        return rows
    }

    /// One row in the "recent transcripts" overview — a recording collapsed to
    /// a single display line (meetings keep their title, dictations carry a
    /// snippet of their transcribed text), so the view never fans out to one
    /// row per segment.
    struct ActivityItem: Sendable, Identifiable {
        let id: String
        let kind: Kind
        let startedAt: Date
        let endedAt: Date?
        let title: String?
        let snippet: String?
        let markdownPath: String?

        /// Recording length when both ends are known.
        var duration: TimeInterval? {
            guard let endedAt else { return nil }
            return max(0, endedAt.timeIntervalSince(startedAt))
        }
    }

    /// Recent dictations and meetings in one newest-first list, restricted to a
    /// trailing time window. `hours <= 0` means no time limit (everything).
    /// Meetings surface their title, dictations a snippet of the spoken text —
    /// both taken without exploding into per-segment rows.
    func recentActivity(within hours: Int = 24, limit: Int = 200) throws -> [ActivityItem] {
        let cutoff = hours <= 0
            ? 0
            : Date().timeIntervalSince1970 - Double(hours) * 3600

        let sql = """
        SELECT r.id, r.kind, r.started_at, r.ended_at, r.title, r.markdown_path,
               (SELECT s.text FROM segments s
                WHERE s.recording_id = r.id
                ORDER BY s.start_seconds ASC LIMIT 1) AS snippet
        FROM recordings r
        WHERE r.started_at >= ?1
        ORDER BY r.started_at DESC
        LIMIT ?2
        """
        let handle = try ensureOpen()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(lastMessage(handle))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var items: [ActivityItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let endedRaw = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            items.append(ActivityItem(
                id: sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "",
                kind: Kind(rawValue: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "") ?? .dictation,
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                endedAt: endedRaw,
                title: sqlite3_column_text(statement, 4).map { String(cString: $0) },
                snippet: sqlite3_column_text(statement, 6).map { String(cString: $0) },
                markdownPath: sqlite3_column_text(statement, 5).map { String(cString: $0) }
            ))
        }
        return items
    }

    struct SearchHit: Sendable, Identifiable {
        var id: String { recordingID + "-" + String(segmentRowID) }
        let recordingID: String
        let segmentRowID: Int64
        let kind: Kind
        let title: String?
        let startedAt: Date
        let markdownPath: String?
        let snippet: String
    }

    /// Case-insensitive substring search over all transcript segments,
    /// newest first. (SQLite LIKE folds ASCII only — good enough for v1.)
    func search(_ query: String, limit: Int = 30) throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")

        let sql = """
        SELECT r.id, s.id, r.kind, r.title, r.started_at, r.markdown_path, s.text
        FROM segments s JOIN recordings r ON r.id = s.recording_id
        WHERE s.text LIKE '%' || ?1 || '%' ESCAPE '\\'
           OR r.title LIKE '%' || ?1 || '%' ESCAPE '\\'
        ORDER BY r.started_at DESC, s.start_seconds ASC
        LIMIT ?2
        """
        let handle = try ensureOpen()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(lastMessage(handle))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, escaped, -1, sqliteTransient)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var hits: [SearchHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let text = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? ""
            hits.append(SearchHit(
                recordingID: sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "",
                segmentRowID: sqlite3_column_int64(statement, 1),
                kind: Kind(rawValue: sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "") ?? .dictation,
                title: sqlite3_column_text(statement, 3).map { String(cString: $0) },
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                markdownPath: sqlite3_column_text(statement, 5).map { String(cString: $0) },
                snippet: Self.snippet(around: trimmed, in: text)
            ))
        }
        return hits
    }

    /// ±60 characters around the first case-insensitive match.
    static func snippet(around query: String, in text: String, radius: Int = 60) -> String {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(text.prefix(radius * 2))
        }
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var result = String(text[start..<end])
        if start > text.startIndex { result = "…" + result }
        if end < text.endIndex { result += "…" }
        return result
    }

    // MARK: - Usage statistics

    /// Raw rows for statistics over [from, to): kind + timestamps + word count.
    /// The stats layer (`UsageMetrics`) aggregates these into durations, saved
    /// time and per-period buckets — the store stays free of stats logic.
    func usageRows(from: Date, to: Date) throws -> [UsageRecord] {
        let sql = """
        SELECT kind, started_at, ended_at, word_count, engine, latency_ms, source_app, enhanced
        FROM recordings
        WHERE started_at >= ?1 AND started_at < ?2
        ORDER BY started_at ASC
        """
        let handle = try ensureOpen()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(lastMessage(handle))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, to.timeIntervalSince1970)
        var rows: [UsageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let kind = Kind(rawValue: sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "") ?? .dictation
            let started = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let ended = sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let wordCount = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(statement, 3))
            let engine = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let latency = sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(statement, 5))
            let sourceApp = sqlite3_column_text(statement, 6).map { String(cString: $0) }
            let enhanced = sqlite3_column_int(statement, 7) == 1
            rows.append(UsageRecord(
                kind: kind, startedAt: started, endedAt: ended, wordCount: wordCount,
                engine: engine, latencyMs: latency, sourceApp: sourceApp, enhanced: enhanced))
        }
        return rows
    }

    /// Appends one LLM round-trip's spend. Never overwrites: see ``LLMUsage``.
    func insertLLMUsage(_ usage: LLMUsage) throws {
        let sql = """
        INSERT INTO llm_usage
            (recording_id, provider, purpose, created_at, input_tokens, output_tokens,
             cache_creation_tokens, cache_read_tokens, cost_usd, billed)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        """
        try run(sql) { s in
            bind(s, 1, usage.recordingID)
            bind(s, 2, usage.provider)
            bind(s, 3, usage.purpose)
            sqlite3_bind_double(s, 4, usage.createdAt.timeIntervalSince1970)
            sqlite3_bind_int(s, 5, Int32(clamping: usage.inputTokens))
            sqlite3_bind_int(s, 6, Int32(clamping: usage.outputTokens))
            sqlite3_bind_int(s, 7, Int32(clamping: usage.cacheCreationTokens))
            sqlite3_bind_int(s, 8, Int32(clamping: usage.cacheReadTokens))
            sqlite3_bind_double(s, 9, usage.costUSD)
            sqlite3_bind_int(s, 10, usage.billed ? 1 : 0)
        }
    }

    /// Every LLM round-trip in the window, oldest first — the raw input the
    /// stats layer buckets. Same shape as ``usageRows``: no aggregation here.
    func llmUsageRows(from: Date, to: Date) throws -> [LLMUsage] {
        let sql = """
        SELECT recording_id, provider, purpose, created_at, input_tokens, output_tokens,
               cache_creation_tokens, cache_read_tokens, cost_usd, billed
        FROM llm_usage
        WHERE created_at >= ?1 AND created_at < ?2
        ORDER BY created_at ASC
        """
        let handle = try ensureOpen()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(lastMessage(handle))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, to.timeIntervalSince1970)
        var rows: [LLMUsage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) } }
            rows.append(LLMUsage(
                recordingID: text(0),
                provider: text(1) ?? "",
                purpose: text(2) ?? "",
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                inputTokens: Int(sqlite3_column_int(statement, 4)),
                outputTokens: Int(sqlite3_column_int(statement, 5)),
                cacheCreationTokens: Int(sqlite3_column_int(statement, 6)),
                cacheReadTokens: Int(sqlite3_column_int(statement, 7)),
                costUSD: sqlite3_column_double(statement, 8),
                billed: sqlite3_column_int(statement, 9) != 0
            ))
        }
        return rows
    }

    /// One-time backfill of `word_count` for dictation rows written before the
    /// column existed. Cheap for a personal-tool-sized DB; the caller guards it
    /// with a UserDefaults flag so it runs at most once. Meetings stay null —
    /// their word count is not a usage metric.
    func backfillWordCounts() throws {
        let selectSQL = """
        SELECT r.id, COALESCE(
            (SELECT GROUP_CONCAT(s.text, ' ') FROM segments s WHERE s.recording_id = r.id), '')
        FROM recordings r
        WHERE r.word_count IS NULL AND r.kind = 'dictation'
        """
        let handle = try ensureOpen()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, selectSQL, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(lastMessage(handle))
        }
        var updates: [(id: String, count: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let text = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            updates.append((id, Self.wordCount(text)))
        }
        sqlite3_finalize(statement)
        guard !updates.isEmpty else { return }

        try execute("BEGIN IMMEDIATE")
        do {
            for update in updates {
                try run("UPDATE recordings SET word_count = ?1 WHERE id = ?2") { s in
                    sqlite3_bind_int(s, 1, Int32(update.count))
                    bind(s, 2, update.id)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Meeting chat (Spec 02)

    /// Chat turns for a meeting, oldest first. Stored as primitives — the chat
    /// layer maps role strings to its own type.
    func chatMessages(for recordingID: String) throws -> [(role: String, text: String, createdAt: Date)] {
        let sql = "SELECT role, text, created_at FROM chat_messages WHERE recording_id = ?1 ORDER BY created_at ASC, id ASC"
        let handle = try ensureOpen()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(lastMessage(handle))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, recordingID, -1, sqliteTransient)
        var rows: [(role: String, text: String, createdAt: Date)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((
                role: sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "",
                text: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            ))
        }
        return rows
    }

    func appendChatMessage(recordingID: String, role: String, text: String, createdAt: Date) throws {
        try run("INSERT INTO chat_messages (recording_id, role, text, created_at) VALUES (?1, ?2, ?3, ?4)") { s in
            bind(s, 1, recordingID)
            bind(s, 2, role)
            bind(s, 3, text)
            sqlite3_bind_double(s, 4, createdAt.timeIntervalSince1970)
        }
    }

    func clearChat(for recordingID: String) throws {
        try run("DELETE FROM chat_messages WHERE recording_id = ?1") { s in bind(s, 1, recordingID) }
    }

    // MARK: - Retention (issue #2)

    /// Empties the text of segments belonging to recordings started before
    /// `date` — and **only** the text.
    ///
    /// The `recordings` row stays, `word_count` stays, and therefore the
    /// statistics stay: `usageRows` reads nothing but `recordings`. Deleting a
    /// row would retroactively rewrite how much was ever dictated, which
    /// is a different and much worse thing than freeing disk space.
    /// `llm_usage` is never touched at all — it is the ledger.
    @discardableResult
    func clearSegmentText(olderThan date: Date, kind: Kind) throws -> Int {
        let sql = """
        UPDATE segments SET text = ''
        WHERE text != '' AND recording_id IN (
            SELECT id FROM recordings WHERE kind = ?1 AND started_at < ?2
        )
        """
        return try runCounting(sql) { s in
            bind(s, 1, kind.rawValue)
            sqlite3_bind_double(s, 2, date.timeIntervalSince1970)
        }
    }

    @discardableResult
    func deleteChatMessages(olderThan date: Date) throws -> Int {
        try runCounting("DELETE FROM chat_messages WHERE created_at < ?1") { s in
            sqlite3_bind_double(s, 1, date.timeIntervalSince1970)
        }
    }

    /// Forgets every recorded target app. The counterpart to the "record app
    /// statistics" switch: turning it off stops new rows, this clears the old.
    @discardableResult
    func clearSourceApps() throws -> Int {
        try runCounting("UPDATE recordings SET source_app = NULL WHERE source_app IS NOT NULL") { _ in }
    }

    /// Reclaims the pages a large delete freed. Only ever called from the manual
    /// "clean up now" path — it rewrites the whole file and has no business in
    /// the launch sequence.
    func vacuum() throws {
        try execute("VACUUM")
    }

    private func runCounting(_ sql: String, bindings: (OpaquePointer?) -> Void) throws -> Int {
        let handle = try ensureOpen()
        try run(sql, bindings: bindings)
        return Int(sqlite3_changes(handle))
    }

    // MARK: - Connection & schema

    private func ensureOpen() throws -> OpaquePointer {
        if let connection { return connection.handle }

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { lastMessage($0) } ?? "open failed"
            sqlite3_close_v2(handle)
            throw StoreError.sqlite(message)
        }
        connection = Connection(handle: handle)

        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("""
        CREATE TABLE IF NOT EXISTS recordings (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            title TEXT,
            calendar_event_id TEXT,
            markdown_path TEXT,
            summary TEXT,
            subtitle TEXT,
            folder TEXT,
            title_is_auto INTEGER NOT NULL DEFAULT 0,
            user_notes TEXT,
            word_count INTEGER
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS segments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            recording_id TEXT NOT NULL REFERENCES recordings(id),
            speaker TEXT,
            start_seconds REAL NOT NULL,
            end_seconds REAL,
            text TEXT NOT NULL
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_segments_recording ON segments(recording_id)")
        try execute("""
        CREATE TABLE IF NOT EXISTS chat_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            recording_id TEXT NOT NULL REFERENCES recordings(id),
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_chat_recording ON chat_messages(recording_id)")
        // What each summarization round-trip spent. `recording_id` is a plain
        // column, **not** a foreign key: the meeting flow summarizes before it
        // inserts the recording (the summary and its auto-title have to land in
        // the same row), so an FK with `foreign_keys=ON` would reject the write.
        try execute("""
        CREATE TABLE IF NOT EXISTS llm_usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            recording_id TEXT,
            provider TEXT NOT NULL,
            purpose TEXT NOT NULL,
            created_at REAL NOT NULL,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL DEFAULT 0,
            billed INTEGER NOT NULL DEFAULT 0
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_llm_usage_created ON llm_usage(created_at)")

        // Migrate DBs created before these columns existed. ADD COLUMN is a
        // cheap metadata-only op in SQLite; each is skipped if already present.
        migrateAddColumn(handle, table: "recordings", column: "summary", type: "TEXT")
        migrateAddColumn(handle, table: "recordings", column: "subtitle", type: "TEXT")
        migrateAddColumn(handle, table: "recordings", column: "folder", type: "TEXT")
        migrateAddColumn(handle, table: "recordings", column: "title_is_auto", type: "INTEGER NOT NULL DEFAULT 0")
        migrateAddColumn(handle, table: "recordings", column: "user_notes", type: "TEXT")
        migrateAddColumn(handle, table: "recordings", column: "word_count", type: "INTEGER")
        // Issue #5. All nullable and never backfilled: six weeks of existing rows
        // never had these values, and a guessed engine or latency would be a
        // fabricated measurement sitting in a statistics window.
        migrateAddColumn(handle, table: "recordings", column: "engine", type: "TEXT")
        migrateAddColumn(handle, table: "recordings", column: "latency_ms", type: "INTEGER")
        migrateAddColumn(handle, table: "recordings", column: "source_app", type: "TEXT")
        migrateAddColumn(handle, table: "recordings", column: "enhanced", type: "INTEGER")
        // The pre-enhancement text, so what the model changed stays visible.
        // Only set when an enhancement actually replaced something.
        migrateAddColumn(handle, table: "recordings", column: "raw_text", type: "TEXT")
        return handle
    }

    /// Idempotent ADD COLUMN: swallows the "duplicate column name" error so the
    /// migration is safe to run on every open. Any other failure is surfaced by
    /// the next real query rather than crashing startup.
    private func migrateAddColumn(_ handle: OpaquePointer, table: String, column: String, type: String) {
        _ = sqlite3_exec(handle, "ALTER TABLE \(table) ADD COLUMN \(column) \(type)", nil, nil, nil)
    }

    private func execute(_ sql: String) throws {
        let handle = try ensureOpen()
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.sqlite(lastMessage(handle))
        }
    }

    private func run(_ sql: String, bindings: (OpaquePointer?) -> Void) throws {
        let handle = try ensureOpen()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(lastMessage(handle))
        }
        defer { sqlite3_finalize(statement) }
        bindings(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.sqlite(lastMessage(handle))
        }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func lastMessage(_ handle: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(handle))
    }
}
