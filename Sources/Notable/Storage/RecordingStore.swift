import Foundation

/// SQLite (WAL) is the source of truth for recordings and transcript
/// segments; Markdown files in the user's notes folder are a projection.
/// Actor-confined — SQLite handles are not thread-safe.
///
/// Everything below the SQL lives in ``SQLiteConnection``: opening, the
/// numbered migrations, prepare/bind/step/finalize, and the transaction
/// helper. This file used to carry nine hand-written copies of that
/// boilerplate, and each copy repeated the same two mistakes — a read loop
/// that read `SQLITE_BUSY` as "no more rows", and a write pair with no
/// transaction around it.
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
        /// The calendar event's title as it stood when the meeting was recorded.
        ///
        /// In SQLite because "SQLite is the truth" was not true for it: the
        /// title lived only in the Markdown front matter, so every rename, move
        /// or re-render read it back as `nil` and silently dropped the `event:`
        /// line from the file.
        var calendarEventTitle: String? = nil
        /// The calendar event's invitees, as they stood when the meeting was
        /// recorded. Stored for the same reason as `calendarEventTitle`: the
        /// Markdown file is a projection, so anything only in the file is lost
        /// on the next rename.
        var attendees: [String] = []
        /// Who the call window showed (Spec 24) — separate from `attendees`,
        /// because "invited" and "was there" are different statements.
        var participants: [String] = []
    }

    struct Segment: Sendable {
        var speaker: String?
        var start: TimeInterval
        var end: TimeInterval?
        var text: String
        /// The label the diarizer minted (Spec 24); `speaker` is what is shown.
        /// nil on segments written before it existed — nothing is estimated.
        var cluster: String? = nil
    }

    /// A name for one cluster, and where it came from (Spec 24).
    struct SpeakerLabelRecord: Sendable, Equatable {
        var cluster: String
        /// nil: anonymous on purpose.
        var name: String?
        var source: SpeakerLabel.Source
    }

    /// One speaker of a meeting, as the correction dialog lists it.
    struct SpeakerLabel: Sendable, Equatable, Identifiable {
        enum Source: String, Sendable {
            case llm
            case screen
            case user
        }

        /// The minted label — or, for a meeting from before Spec 24, the name it shows.
        var cluster: String
        var name: String
        /// nil: never named.
        var source: Source?
        var segmentCount: Int
        var seconds: TimeInterval

        var id: String { cluster }
        var isLocalUser: Bool { cluster == SpeakerNameResolver.micSpeakerLabel }
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

    private let databaseURL: URL
    private var connection: SQLiteConnection?

    /// Where the shared database lives. `nonisolated` and static because the
    /// storage pane needs to *size* the file, which is a question about the
    /// filesystem and not about the actor's state.
    nonisolated static var sharedDatabaseURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notable", isDirectory: true)
            .appendingPathComponent("notable.sqlite")
    }

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notable", isDirectory: true)
        databaseURL = base.appendingPathComponent("notable.sqlite")
    }

    /// The open, migrated database.
    ///
    /// The instance is only stored once `open` has fully succeeded. The previous
    /// version assigned the handle first and ran the schema afterwards, so a
    /// failure in the schema left a connection behind that every later call
    /// reused — without a schema, and without ever trying again.
    private func db() throws -> SQLiteConnection {
        if let connection { return connection }
        let opened = try SQLiteConnection.open(at: databaseURL)
        connection = opened
        return opened
    }

    // MARK: - Public API

    /// The measurement parameters default to nil so every existing caller and test
    /// stays valid — and so a row that genuinely does not know its engine says so
    /// rather than claiming one.
    ///
    /// One transaction: the recording and its segment are two INSERTs, and an
    /// error between them left a recording with no text — counted by `usageRows`,
    /// listed by `recentActivity` with an empty snippet, invisible to
    /// `recentDictations`.
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
        try db().transaction {
            try insert(recording)
            try insert(Segment(speaker: nil, start: 0, end: duration, text: text), recordingID: recording.id)
        }
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
             engine, latency_ms, source_app, enhanced, raw_text, calendar_event_title, attendees,
             participants)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)
        """
        try db().run(sql) { s in
            s.bind(1, recording.id)
            s.bind(2, recording.kind.rawValue)
            s.bind(3, recording.startedAt)
            s.bind(4, recording.endedAt)
            s.bind(5, recording.title)
            s.bind(6, recording.calendarEventID)
            s.bind(7, recording.markdownPath)
            s.bind(8, recording.summary)
            s.bind(9, recording.subtitle)
            s.bind(10, recording.folder)
            s.bind(11, recording.titleIsAuto)
            s.bind(12, recording.userNotes)
            s.bind(13, recording.wordCount)
            s.bind(14, recording.engine)
            s.bind(15, recording.latencyMs)
            s.bind(16, recording.sourceApp)
            s.bind(17, recording.enhanced)
            s.bind(18, recording.rawText)
            s.bind(19, recording.calendarEventTitle)
            s.bind(20, recording.attendees.isEmpty ? nil : recording.attendees.joined(separator: "\n"))
            s.bind(21, recording.participants.isEmpty ? nil : recording.participants.joined(separator: "\n"))
        }
    }

    func insert(_ segment: Segment, recordingID: String) throws {
        let sql = """
        INSERT INTO segments (recording_id, speaker, start_seconds, end_seconds, text, cluster)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        """
        try db().run(sql) { s in
            s.bind(1, recordingID)
            s.bind(2, segment.speaker)
            s.bind(3, segment.start)
            s.bind(4, segment.end)
            s.bind(5, segment.text)
            s.bind(6, segment.cluster)
        }
    }

    /// Atomic insert of a meeting with all its segments and speaker names — a
    /// partial write must not leave orphaned rows.
    func insertMeeting(_ recording: Recording, segments: [Segment], labels: [SpeakerLabelRecord] = []) throws {
        try db().transaction {
            try insert(recording)
            for segment in segments {
                try insert(segment, recordingID: recording.id)
            }
            try recordSpeakerLabels(labels, recordingID: recording.id)
        }
    }

    // MARK: - Speakers (Spec 24, Stufe 4)

    /// Where each name came from. **`user` outranks everything**: an automatic
    /// source never overwrites a name the user gave — that is what makes a
    /// correction hold.
    func recordSpeakerLabels(_ labels: [SpeakerLabelRecord], recordingID: String) throws {
        let connection = try db()
        try connection.transaction {
            for label in labels {
                try connection.run("""
                INSERT INTO speaker_labels (recording_id, cluster, name, source) VALUES (?1, ?2, ?3, ?4)
                ON CONFLICT(recording_id, cluster) DO UPDATE SET name = excluded.name, source = excluded.source
                WHERE speaker_labels.source <> 'user' OR excluded.source = 'user'
                """) { s in
                    s.bind(1, recordingID)
                    s.bind(2, label.cluster)
                    s.bind(3, label.name)
                    s.bind(4, label.source.rawValue)
                }
            }
        }
    }

    /// The speakers of a meeting, first appearance first. A meeting from before
    /// Spec 24 has no clusters; it lists the names it shows.
    func speakerLabels(for recordingID: String) throws -> [SpeakerLabel] {
        let connection = try db()
        let sources = try connection.query(
            "SELECT cluster, source FROM speaker_labels WHERE recording_id = ?1",
            bind: { $0.bind(1, recordingID) },
            row: { (cluster: $0.text(0), source: $0.text(1)) }
        ).reduce(into: [String: SpeakerLabel.Source]()) { $0[$1.cluster] = SpeakerLabel.Source(rawValue: $1.source) }
        return try connection.query(
            """
            SELECT COALESCE(cluster, speaker) AS label, MAX(speaker), COUNT(*),
                   SUM(MAX(COALESCE(end_seconds, start_seconds) - start_seconds, 0)), MIN(start_seconds)
            FROM segments
            WHERE recording_id = ?1 AND COALESCE(cluster, speaker) IS NOT NULL
            GROUP BY label ORDER BY MIN(start_seconds)
            """,
            bind: { $0.bind(1, recordingID) },
            row: { s in
                let cluster = s.text(0)
                return SpeakerLabel(cluster: cluster, name: s.string(1) ?? cluster, source: sources[cluster],
                                    segmentCount: s.int(2) ?? 0, seconds: s.double(3) ?? 0)
            }
        )
    }

    /// Names a speaker; an empty name makes them anonymous again (their minted
    /// label). One transaction; `"Ich"` stays fixed.
    func renameSpeaker(recordingID: String, cluster: String, to name: String) throws {
        guard cluster != SpeakerNameResolver.micSpeakerLabel else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = try db()
        try connection.transaction {
            try adoptLegacyCluster(cluster, recordingID: recordingID, connection: connection)
            try connection.run("UPDATE segments SET speaker = ?3 WHERE recording_id = ?1 AND cluster = ?2") { s in
                s.bind(1, recordingID)
                s.bind(2, cluster)
                s.bind(3, trimmed.isEmpty ? cluster : trimmed)
            }
            try recordSpeakerLabels([SpeakerLabelRecord(cluster: cluster, name: trimmed.isEmpty ? nil : trimmed, source: .user)],
                                    recordingID: recordingID)
        }
    }

    /// Two labels, one person: `cluster`'s segments join `target` under its name.
    func mergeSpeaker(recordingID: String, cluster: String, into target: String) throws {
        let mic = SpeakerNameResolver.micSpeakerLabel
        guard cluster != target, cluster != mic, target != mic else { return }
        let connection = try db()
        try connection.transaction {
            try adoptLegacyCluster(cluster, recordingID: recordingID, connection: connection)
            try adoptLegacyCluster(target, recordingID: recordingID, connection: connection)
            let targetName = try connection.queryOne(
                "SELECT speaker FROM segments WHERE recording_id = ?1 AND cluster = ?2 LIMIT 1",
                bind: { $0.bind(1, recordingID); $0.bind(2, target) },
                row: { $0.string(0) }
            ) ?? target
            try connection.run("UPDATE segments SET cluster = ?3, speaker = ?4 WHERE recording_id = ?1 AND cluster = ?2") { s in
                s.bind(1, recordingID)
                s.bind(2, cluster)
                s.bind(3, target)
                s.bind(4, targetName)
            }
            try connection.run("DELETE FROM speaker_labels WHERE recording_id = ?1 AND cluster = ?2") { s in
                s.bind(1, recordingID)
                s.bind(2, cluster)
            }
            try recordSpeakerLabels([SpeakerLabelRecord(cluster: target, name: targetName == target ? nil : targetName, source: .user)],
                                    recordingID: recordingID)
        }
    }

    /// A meeting from before Spec 24 has no cluster column filled in: the label
    /// it shows becomes its cluster the moment the user edits it. Not an
    /// estimate — it is exactly what the note displayed.
    private func adoptLegacyCluster(_ label: String, recordingID: String, connection: SQLiteConnection) throws {
        try connection.run("UPDATE segments SET cluster = speaker WHERE recording_id = ?1 AND cluster IS NULL AND speaker = ?2") { s in
            s.bind(1, recordingID)
            s.bind(2, label)
        }
    }

    // MARK: - Reads & edits (SQLite is the source of truth)

    /// Every column of `recordings`, in the order ``readRecording`` expects.
    ///
    /// All of them: the short list this used to be meant `meeting(id:)` always
    /// reported `enhanced == false` and `rawText == nil` no matter what stood in
    /// the row, because those columns were simply not selected.
    private static let recordingColumns = """
    id, kind, started_at, ended_at, title, calendar_event_id, markdown_path, summary, \
    subtitle, folder, title_is_auto, user_notes, word_count, engine, latency_ms, \
    source_app, enhanced, raw_text, calendar_event_title, attendees, participants
    """

    private static func readRecording(_ s: SQLiteConnection.Statement) -> Recording {
        Recording(
            id: s.text(0),
            kind: Kind(rawValue: s.text(1)) ?? .meeting,
            startedAt: s.date(2) ?? Date(timeIntervalSince1970: 0),
            endedAt: s.date(3),
            title: s.string(4),
            calendarEventID: s.string(5),
            markdownPath: s.string(6),
            summary: s.string(7),
            subtitle: s.string(8),
            folder: s.string(9),
            titleIsAuto: s.bool(10),
            userNotes: s.string(11),
            wordCount: s.int(12),
            engine: s.string(13),
            latencyMs: s.int(14),
            sourceApp: s.string(15),
            enhanced: s.bool(16),
            rawText: s.string(17),
            calendarEventTitle: s.string(18),
            attendees: s.string(19)?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? [],
            participants: s.string(20)?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        )
    }

    /// Recent meetings for the note list, newest first.
    func recentMeetings(limit: Int = 100) throws -> [Recording] {
        try db().query(
            "SELECT \(Self.recordingColumns) FROM recordings WHERE kind = 'meeting' ORDER BY started_at DESC LIMIT ?1",
            bind: { $0.bind(1, limit) },
            row: Self.readRecording
        )
    }

    /// A recording plus its segments — enough to re-render the whole note from
    /// SQLite (rename/move/regenerate all round-trip through this).
    func meeting(id: String) throws -> (recording: Recording, segments: [Segment])? {
        let recording = try db().queryOne(
            "SELECT \(Self.recordingColumns) FROM recordings WHERE id = ?1",
            bind: { $0.bind(1, id) },
            row: Self.readRecording
        )
        guard let recording else { return nil }
        return (recording, try segments(for: id))
    }

    /// Transcript segments for a recording, in chronological order.
    func segments(for recordingID: String) throws -> [Segment] {
        try db().query(
            """
            SELECT speaker, start_seconds, end_seconds, text, cluster FROM segments
            WHERE recording_id = ?1 ORDER BY start_seconds ASC
            """,
            bind: { $0.bind(1, recordingID) },
            row: { (s: SQLiteConnection.Statement) -> Segment in
                Segment(
                    speaker: s.string(0),
                    start: s.double(1) ?? 0,
                    end: s.double(2),
                    text: s.text(3),
                    cluster: s.string(4)
                )
            }
        )
    }

    /// Stores the user's own notes for a recording (edited from the note window).
    func setUserNotes(_ notes: String?, for id: String) throws {
        try db().run("UPDATE recordings SET user_notes = ?1 WHERE id = ?2") { s in
            s.bind(1, notes)
            s.bind(2, id)
        }
    }

    /// Stores the summary (and optional subtitle) once summarization succeeds.
    func setSummary(_ summary: String?, subtitle: String? = nil, for id: String) throws {
        try db().run("UPDATE recordings SET summary = ?1, subtitle = ?2 WHERE id = ?3") { s in
            s.bind(1, summary)
            s.bind(2, subtitle)
            s.bind(3, id)
        }
    }

    /// Renames a note: the title, its file path, and whether it is still
    /// auto-generated all move together. Caller writes the .md file itself.
    func updateTitle(_ title: String, titleIsAuto: Bool, markdownPath: String?, for id: String) throws {
        try db().run("UPDATE recordings SET title = ?1, title_is_auto = ?2, markdown_path = ?3 WHERE id = ?4") { s in
            s.bind(1, title)
            s.bind(2, titleIsAuto)
            s.bind(3, markdownPath)
            s.bind(4, id)
        }
    }

    /// The whole notes folder moved (Spec 27, Stufe 2): every stored path under
    /// `oldRoot` follows it to `newRoot`, in **one** transaction — half a
    /// rewrite would leave some notes pointing at the old place and some at the
    /// new. Paths outside the folder are left alone. Returns how many moved.
    @discardableResult
    func relocateMarkdownPaths(from oldRoot: String, to newRoot: String) throws -> Int {
        let connection = try db()
        return try connection.transaction {
            let rows = try connection.query(
                "SELECT id, markdown_path FROM recordings WHERE markdown_path IS NOT NULL"
            ) { s in (id: s.string(0) ?? "", path: s.string(1) ?? "") }
            var moved = 0
            for row in rows {
                guard let rewritten = NotesRelocation.rewrite(row.path, from: oldRoot, to: newRoot) else { continue }
                try connection.run("UPDATE recordings SET markdown_path = ?1 WHERE id = ?2") { s in
                    s.bind(1, rewritten)
                    s.bind(2, row.id)
                }
                moved += 1
            }
            return moved
        }
    }

    /// Moves a note between folders (Inbox → project). Caller moves the file.
    func updateLocation(folder: String?, markdownPath: String?, for id: String) throws {
        try db().run("UPDATE recordings SET folder = ?1, markdown_path = ?2 WHERE id = ?3") { s in
            s.bind(1, folder)
            s.bind(2, markdownPath)
            s.bind(3, id)
        }
    }

    /// Most recent dictations, newest first.
    ///
    /// `s.text != ''` because retention *empties* the text and keeps the row
    /// (the statistics read `recordings`, so the row has to survive). Without
    /// the filter a cleaned-up dictation became a blank line in the menu whose
    /// "Einfügen" pasted an empty string.
    func recentDictations(limit: Int = 20) throws -> [(date: Date, text: String, rawText: String?)] {
        try db().query(
            """
            SELECT r.started_at, s.text, r.raw_text
            FROM recordings r JOIN segments s ON s.recording_id = r.id
            WHERE r.kind = 'dictation' AND s.text != ''
            ORDER BY r.started_at DESC
            LIMIT ?1
            """,
            bind: { $0.bind(1, limit) },
            row: { s in
                (
                    date: s.date(0) ?? Date(timeIntervalSince1970: 0),
                    text: s.text(1),
                    // Non-nil only where an enhancement actually replaced
                    // something — that is what makes the change visible after
                    // the fact.
                    rawText: s.string(2)
                )
            }
        )
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
        /// The rule-polished text before an LLM improvement replaced it —
        /// non-nil only where one actually did. Without it nobody can tell
        /// after the fact what the model changed.
        var rawText: String?

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
    ///
    /// `kind` filters in SQL rather than in the view. Filtering afterwards meant
    /// meetings ate slots out of the same `LIMIT`, so "only dictations" was
    /// quietly capped at however many of the last 200 rows happened to be
    /// dictations.
    func recentActivity(kind: Kind? = nil, within hours: Int = 24, limit: Int = 200) throws -> [ActivityItem] {
        let cutoff = hours <= 0
            ? 0
            : Date().timeIntervalSince1970 - Double(hours) * 3600

        let sql = """
        SELECT r.id, r.kind, r.started_at, r.ended_at, r.title, r.markdown_path,
               (SELECT s.text FROM segments s
                WHERE s.recording_id = r.id AND s.text != ''
                ORDER BY s.start_seconds ASC LIMIT 1) AS snippet,
               r.raw_text
        FROM recordings r
        WHERE r.started_at >= ?1 AND (?2 IS NULL OR r.kind = ?2)
        ORDER BY r.started_at DESC
        LIMIT ?3
        """
        return try db().query(
            sql,
            bind: { s in
                s.bind(1, cutoff)
                s.bind(2, kind?.rawValue)
                s.bind(3, limit)
            },
            row: { (s: SQLiteConnection.Statement) -> ActivityItem in
                ActivityItem(
                    id: s.text(0),
                    kind: Kind(rawValue: s.text(1)) ?? .dictation,
                    startedAt: s.date(2) ?? Date(timeIntervalSince1970: 0),
                    endedAt: s.date(3),
                    title: s.string(4),
                    snippet: s.string(6),
                    markdownPath: s.string(5),
                    rawText: s.string(7)
                )
            }
        )
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

    /// Full-text search over transcript segments plus the note titles, newest
    /// first.
    ///
    /// **Two statements, merged in Swift, and that is the point.** As one query
    /// with `OR r.title LIKE …` over the `segments ⋈ recordings` join, a title
    /// match produced one row *per segment*: a 300-segment meeting filled the
    /// entire result list with identical entries whose snippets did not contain
    /// the search term at all. A title matches a recording, so it yields one hit.
    ///
    /// The text half goes through FTS5 (`unicode61 remove_diacritics 2`) when the
    /// index exists. The old `LIKE` folded ASCII only — "über" never found
    /// "Über", while the snippet rendered for the same search *was* diacritic-
    /// insensitive, so a hit could be displayed with a snippet that did not
    /// contain what was searched for. Without FTS5 in this build of SQLite the
    /// `LIKE` path stands in: worse, but never broken.
    func search(_ query: String, limit: Int = 30) throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let connection = try db()

        var hits = connection.hasFullTextIndex
            ? try fullTextHits(trimmed, limit: limit, on: connection)
            : try likeHits(trimmed, limit: limit, on: connection)
        hits += try titleHits(trimmed, limit: limit, on: connection)

        var seen = Set<String>()
        return hits
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.startedAt, $0.segmentRowID) > ($1.startedAt, $1.segmentRowID) }
            .prefix(limit)
            .map { $0 }
    }

    /// The FTS5 query string. Every token is quoted (so `%`, `-`, `"` and the
    /// operator words are literal) and given a `*`, which is what makes typing
    /// "budg" find "Budget" — a prefix search, not a substring one.
    static func matchExpression(for query: String) -> String {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
    }

    private func fullTextHits(_ query: String, limit: Int, on connection: SQLiteConnection) throws -> [SearchHit] {
        let sql = """
        SELECT r.id, s.id, r.kind, r.title, r.started_at, r.markdown_path, s.text
        FROM segments_fts f
        JOIN segments s ON s.id = f.rowid
        JOIN recordings r ON r.id = s.recording_id
        WHERE segments_fts MATCH ?1 AND s.text != ''
        ORDER BY r.started_at DESC, s.start_seconds ASC
        LIMIT ?2
        """
        do {
            return try connection.query(
                sql,
                bind: { s in
                    s.bind(1, Self.matchExpression(for: query))
                    s.bind(2, limit)
                },
                row: { (s: SQLiteConnection.Statement) -> SearchHit in Self.searchHit(s, query: query) }
            )
        } catch {
            // A MATCH expression SQLite refuses is a bad *query*, not a broken
            // database — fall back rather than show the user a SQLite error.
            return try likeHits(query, limit: limit, on: connection)
        }
    }

    private func likeHits(_ query: String, limit: Int, on connection: SQLiteConnection) throws -> [SearchHit] {
        let sql = """
        SELECT r.id, s.id, r.kind, r.title, r.started_at, r.markdown_path, s.text
        FROM segments s JOIN recordings r ON r.id = s.recording_id
        WHERE s.text != '' AND s.text LIKE '%' || ?1 || '%' ESCAPE '\\'
        ORDER BY r.started_at DESC, s.start_seconds ASC
        LIMIT ?2
        """
        return try connection.query(
            sql,
            bind: { s in
                s.bind(1, Self.escapedForLike(query))
                s.bind(2, limit)
            },
            row: { (s: SQLiteConnection.Statement) -> SearchHit in Self.searchHit(s, query: query) }
        )
    }

    /// One hit per recording whose title matches — `segmentRowID` 0, so it can
    /// never collide with a text hit on the same recording.
    private func titleHits(_ query: String, limit: Int, on connection: SQLiteConnection) throws -> [SearchHit] {
        let sql = """
        SELECT r.id, r.kind, r.title, r.started_at, r.markdown_path,
               (SELECT s.text FROM segments s
                WHERE s.recording_id = r.id AND s.text != ''
                ORDER BY s.start_seconds ASC LIMIT 1)
        FROM recordings r
        WHERE r.title LIKE '%' || ?1 || '%' ESCAPE '\\'
        ORDER BY r.started_at DESC
        LIMIT ?2
        """
        return try connection.query(
            sql,
            bind: { s in
                s.bind(1, Self.escapedForLike(query))
                s.bind(2, limit)
            },
            row: { (s: SQLiteConnection.Statement) -> SearchHit in
                SearchHit(
                    recordingID: s.text(0),
                    segmentRowID: 0,
                    kind: Kind(rawValue: s.text(1)) ?? .dictation,
                    title: s.string(2),
                    startedAt: s.date(3) ?? Date(timeIntervalSince1970: 0),
                    markdownPath: s.string(4),
                    snippet: Self.snippet(around: query, in: s.text(5))
                )
            }
        )
    }

    private static func searchHit(_ s: SQLiteConnection.Statement, query: String) -> SearchHit {
        SearchHit(
            recordingID: s.text(0),
            segmentRowID: s.int64(1),
            kind: Kind(rawValue: s.text(2)) ?? .dictation,
            title: s.string(3),
            startedAt: s.date(4) ?? Date(timeIntervalSince1970: 0),
            markdownPath: s.string(5),
            snippet: snippet(around: query, in: s.text(6))
        )
    }

    private static func escapedForLike(_ query: String) -> String {
        query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
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
        try db().query(
            """
            SELECT kind, started_at, ended_at, word_count, engine, latency_ms, source_app, enhanced
            FROM recordings
            WHERE started_at >= ?1 AND started_at < ?2
            ORDER BY started_at ASC
            """,
            bind: { s in
                s.bind(1, from)
                s.bind(2, to)
            },
            // Explicit types: an inferred closure with eight optional-returning
            // accessors takes the type checker past its own budget.
            row: { (s: SQLiteConnection.Statement) -> UsageRecord in
                UsageRecord(
                    kind: Kind(rawValue: s.text(0)) ?? .dictation,
                    startedAt: s.date(1) ?? Date(timeIntervalSince1970: 0),
                    endedAt: s.date(2),
                    wordCount: s.int(3),
                    engine: s.string(4),
                    latencyMs: s.int(5),
                    sourceApp: s.string(6),
                    enhanced: s.bool(7)
                )
            }
        )
    }

    /// Appends one LLM round-trip's spend. Never overwrites: see ``LLMUsage``.
    func insertLLMUsage(_ usage: LLMUsage) throws {
        let sql = """
        INSERT INTO llm_usage
            (recording_id, provider, purpose, created_at, input_tokens, output_tokens,
             cache_creation_tokens, cache_read_tokens, cost_usd, billed)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        """
        try db().run(sql) { s in
            s.bind(1, usage.recordingID)
            s.bind(2, usage.provider)
            s.bind(3, usage.purpose)
            s.bind(4, usage.createdAt)
            s.bind(5, usage.inputTokens)
            s.bind(6, usage.outputTokens)
            s.bind(7, usage.cacheCreationTokens)
            s.bind(8, usage.cacheReadTokens)
            s.bind(9, usage.costUSD)
            s.bind(10, usage.billed)
        }
    }

    /// Every LLM round-trip in the window, oldest first — the raw input the
    /// stats layer buckets. Same shape as ``usageRows``: no aggregation here.
    func llmUsageRows(from: Date, to: Date) throws -> [LLMUsage] {
        try db().query(
            """
            SELECT recording_id, provider, purpose, created_at, input_tokens, output_tokens,
                   cache_creation_tokens, cache_read_tokens, cost_usd, billed
            FROM llm_usage
            WHERE created_at >= ?1 AND created_at < ?2
            ORDER BY created_at ASC
            """,
            bind: { s in
                s.bind(1, from)
                s.bind(2, to)
            },
            row: { (s: SQLiteConnection.Statement) -> LLMUsage in
                LLMUsage(
                    recordingID: s.string(0),
                    provider: s.text(1),
                    purpose: s.text(2),
                    createdAt: s.date(3) ?? Date(timeIntervalSince1970: 0),
                    inputTokens: s.int(4) ?? 0,
                    outputTokens: s.int(5) ?? 0,
                    cacheCreationTokens: s.int(6) ?? 0,
                    cacheReadTokens: s.int(7) ?? 0,
                    costUSD: s.double(8) ?? 0,
                    billed: s.bool(9)
                )
            }
        )
    }

    /// One-time backfill of `word_count` for dictation rows written before the
    /// column existed. Cheap for a personal-tool-sized DB; the caller guards it
    /// with a UserDefaults flag so it runs at most once. Meetings stay null —
    /// their word count is not a usage metric.
    func backfillWordCounts() throws {
        let connection = try db()
        let updates = try connection.query(
            """
            SELECT r.id, COALESCE(
                (SELECT GROUP_CONCAT(s.text, ' ') FROM segments s WHERE s.recording_id = r.id), '')
            FROM recordings r
            WHERE r.word_count IS NULL AND r.kind = 'dictation'
            """,
            row: { s in (id: s.text(0), count: Self.wordCount(s.text(1))) }
        )
        guard !updates.isEmpty else { return }

        try connection.transaction {
            for update in updates {
                try connection.run("UPDATE recordings SET word_count = ?1 WHERE id = ?2") { s in
                    s.bind(1, update.count)
                    s.bind(2, update.id)
                }
            }
        }
    }

    // MARK: - Meeting chat (Spec 02)

    /// Chat turns for a meeting, oldest first. Stored as primitives — the chat
    /// layer maps role strings to its own type.
    func chatMessages(for recordingID: String) throws -> [(role: String, text: String, createdAt: Date)] {
        try db().query(
            """
            SELECT role, text, created_at FROM chat_messages
            WHERE recording_id = ?1 ORDER BY created_at ASC, id ASC
            """,
            bind: { $0.bind(1, recordingID) },
            row: { s in
                (
                    role: s.text(0),
                    text: s.text(1),
                    createdAt: s.date(2) ?? Date(timeIntervalSince1970: 0)
                )
            }
        )
    }

    func appendChatMessage(recordingID: String, role: String, text: String, createdAt: Date) throws {
        try db().run("INSERT INTO chat_messages (recording_id, role, text, created_at) VALUES (?1, ?2, ?3, ?4)") { s in
            s.bind(1, recordingID)
            s.bind(2, role)
            s.bind(3, text)
            s.bind(4, createdAt)
        }
    }

    func clearChat(for recordingID: String) throws {
        try db().run("DELETE FROM chat_messages WHERE recording_id = ?1") { $0.bind(1, recordingID) }
    }

    // MARK: - Retention (issue #2)

    /// Empties the text of recordings started before `date` — and **only** the
    /// text.
    ///
    /// The `recordings` row stays, `word_count` stays, and therefore the
    /// statistics stay: `usageRows` reads nothing but `recordings`. Deleting a
    /// row would retroactively rewrite how much was ever dictated, which
    /// is a different and much worse thing than freeing disk space.
    /// `llm_usage` is never touched at all — it is the ledger.
    ///
    /// Both copies of the text go in one transaction: `recordings.raw_text`
    /// holds the full rule-polished dictation of every *enhanced* run, so
    /// emptying `segments.text` alone left the text sitting in another table —
    /// where `recentDictations` handed it straight back out.
    @discardableResult
    func clearSegmentText(olderThan date: Date, kind: Kind) throws -> Int {
        let connection = try db()
        return try connection.transaction {
            let cleared = try connection.runCounting("""
            UPDATE segments SET text = ''
            WHERE text != '' AND recording_id IN (
                SELECT id FROM recordings WHERE kind = ?1 AND started_at < ?2
            )
            """) { s in
                s.bind(1, kind.rawValue)
                s.bind(2, date)
            }
            try connection.run("""
            UPDATE recordings SET raw_text = NULL
            WHERE raw_text IS NOT NULL AND kind = ?1 AND started_at < ?2
            """) { s in
                s.bind(1, kind.rawValue)
                s.bind(2, date)
            }
            return cleared
        }
    }

    @discardableResult
    func deleteChatMessages(olderThan date: Date) throws -> Int {
        try db().runCounting("DELETE FROM chat_messages WHERE created_at < ?1") { $0.bind(1, date) }
    }

    /// Forgets every recorded target app. The counterpart to the "record app
    /// statistics" switch: turning it off stops new rows, this clears the old.
    @discardableResult
    func clearSourceApps() throws -> Int {
        try db().runCounting("UPDATE recordings SET source_app = NULL WHERE source_app IS NOT NULL")
    }

    /// Reclaims the pages a large delete freed. Only ever called from the manual
    /// "clean up now" path — it rewrites the whole file and has no business in
    /// the launch sequence.
    func vacuum() throws {
        try db().execute("VACUUM")
    }
}
