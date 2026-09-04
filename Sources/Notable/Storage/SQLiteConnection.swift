import Foundation
import SQLite3

/// SQLITE_TRANSIENT: tells SQLite to copy the bound bytes rather than hold the
/// pointer. Private to this file — nothing outside it binds a statement.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One open SQLite database: the handle, the schema it is migrated to, and the
/// four ways anything talks to it (`execute`, `run`, `query`, `transaction`).
///
/// Extracted from `RecordingStore`, where the same prepare/bind/step/finalize
/// boilerplate stood written out nine times and each copy carried the same two
/// mistakes: `while sqlite3_step(...) == SQLITE_ROW` treats *any* non-row
/// result as the end of the data, so `SQLITE_BUSY` or a corrupt page read back
/// as "no dictations today"; and a write pair with no transaction around it
/// could leave a recording without its segment. Both are fixed once here
/// rather than nine times there.
///
/// Not an actor: `RecordingStore` is one, and it owns the only instance.
final class SQLiteConnection: @unchecked Sendable {
    private let handle: OpaquePointer

    /// False when this build's SQLite has no FTS5. Search then falls back to
    /// `LIKE`, which is worse but not broken — a missing full-text index must
    /// not make the database unopenable.
    private(set) var hasFullTextIndex = false

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit { sqlite3_close_v2(handle) }

    enum Failure: Error, LocalizedError {
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case .sqlite(let message): "SQLite: \(message)"
            }
        }
    }

    /// Opens (creating if needed), configures and migrates the database.
    ///
    /// The instance is only produced once every step has succeeded. The
    /// previous version assigned the connection *before* running the pragmas
    /// and schema, so a failure there left a handle with no schema behind that
    /// every later call happily reused and never retried.
    static func open(at url: URL) throws -> SQLiteConnection {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var raw: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &raw, flags, nil) == SQLITE_OK, let raw else {
            let message = raw.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(raw)
            throw Failure.sqlite(message)
        }

        let connection = SQLiteConnection(handle: raw)
        do {
            try connection.execute("PRAGMA journal_mode=WAL")
            try connection.execute("PRAGMA foreign_keys=ON")
            try connection.migrate()
        } catch {
            // The instance is dropped here, so `deinit` closes the handle: a
            // failed open leaves nothing behind to be reused.
            throw error
        }
        return connection
    }

    // MARK: - Statements

    /// A prepared statement, typed. Nothing outside this file touches a raw
    /// `sqlite3_stmt` any more.
    struct Statement {
        let raw: OpaquePointer?

        func bind(_ index: Int32, _ value: String?) {
            if let value { sqlite3_bind_text(raw, index, value, -1, sqliteTransient) }
            else { sqlite3_bind_null(raw, index) }
        }

        func bind(_ index: Int32, _ value: Double?) {
            if let value { sqlite3_bind_double(raw, index, value) }
            else { sqlite3_bind_null(raw, index) }
        }

        /// `bind_int64`, never `Int32(...)`. The trapping conversions on the
        /// save path could only be hit by absurd values, but the failure mode
        /// — a crash inside the store, mid-`saveDictation` — is the wrong one.
        func bind(_ index: Int32, _ value: Int?) {
            if let value { sqlite3_bind_int64(raw, index, Int64(value)) }
            else { sqlite3_bind_null(raw, index) }
        }

        func bind(_ index: Int32, _ value: Bool) {
            sqlite3_bind_int(raw, index, value ? 1 : 0)
        }

        func bind(_ index: Int32, _ value: Date) {
            sqlite3_bind_double(raw, index, value.timeIntervalSince1970)
        }

        func bind(_ index: Int32, _ value: Date?) {
            bind(index, value?.timeIntervalSince1970)
        }

        func string(_ index: Int32) -> String? {
            sqlite3_column_text(raw, index).map { String(cString: $0) }
        }

        func text(_ index: Int32) -> String { string(index) ?? "" }

        func int(_ index: Int32) -> Int? {
            isNull(index) ? nil : Int(sqlite3_column_int64(raw, index))
        }

        func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(raw, index) }

        func double(_ index: Int32) -> Double? {
            isNull(index) ? nil : sqlite3_column_double(raw, index)
        }

        func date(_ index: Int32) -> Date? {
            double(index).map(Date.init(timeIntervalSince1970:))
        }

        func bool(_ index: Int32) -> Bool { sqlite3_column_int(raw, index) != 0 }

        func isNull(_ index: Int32) -> Bool {
            sqlite3_column_type(raw, index) == SQLITE_NULL
        }
    }

    // MARK: - Running

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure.sqlite(lastMessage())
        }
    }

    /// One statement that returns no rows.
    func run(_ sql: String, _ bind: (Statement) -> Void = { _ in }) throws {
        try prepared(sql) { statement in
            bind(statement)
            guard sqlite3_step(statement.raw) == SQLITE_DONE else {
                throw Failure.sqlite(lastMessage())
            }
        }
    }

    /// `run`, plus how many rows it changed.
    @discardableResult
    func runCounting(_ sql: String, _ bind: (Statement) -> Void = { _ in }) throws -> Int {
        try run(sql, bind)
        return Int(sqlite3_changes(handle))
    }

    /// Reads every row, mapping each through `row`.
    ///
    /// The loop ends on `SQLITE_DONE` and **throws** on anything else. The old
    /// `while step() == SQLITE_ROW` shape silently turned a locked or corrupt
    /// database into a short list — the statistics would simply have shown
    /// less, with nothing anywhere saying why.
    func query<T>(
        _ sql: String,
        bind: (Statement) -> Void = { _ in },
        row: (Statement) throws -> T
    ) throws -> [T] {
        try prepared(sql) { statement in
            bind(statement)
            var results: [T] = []
            while true {
                let code = sqlite3_step(statement.raw)
                if code == SQLITE_ROW {
                    results.append(try row(statement))
                } else if code == SQLITE_DONE {
                    return results
                } else {
                    throw Failure.sqlite(lastMessage())
                }
            }
        }
    }

    /// The first row, or nil.
    func queryOne<T>(
        _ sql: String,
        bind: (Statement) -> Void = { _ in },
        row: (Statement) throws -> T
    ) throws -> T? {
        try query(sql, bind: bind, row: row).first
    }

    /// `BEGIN IMMEDIATE` … `COMMIT`, rolling back on any throw.
    ///
    /// Nestable in the sense that matters here: an inner call joins the outer
    /// transaction instead of starting a second one, which SQLite would refuse.
    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T {
        guard depth == 0 else { return try body() }
        try execute("BEGIN IMMEDIATE")
        depth += 1
        do {
            let result = try body()
            depth -= 1
            try execute("COMMIT")
            return result
        } catch {
            depth -= 1
            try? execute("ROLLBACK")
            throw error
        }
    }

    private var depth = 0

    private func prepared<T>(_ sql: String, _ body: (Statement) throws -> T) throws -> T {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &raw, nil) == SQLITE_OK else {
            throw Failure.sqlite(lastMessage())
        }
        defer { sqlite3_finalize(raw) }
        return try body(Statement(raw: raw))
    }

    private func lastMessage() -> String {
        String(cString: sqlite3_errmsg(handle))
    }

    // MARK: - Schema

    /// Numbered, ordered, each in its own transaction, tracked in
    /// `PRAGMA user_version`.
    ///
    /// What this replaces: eleven unconditional `ALTER TABLE`s whose *every*
    /// error was discarded. A fresh database was created in a shape that
    /// predated five of its own columns and relied on those blind ALTERs to
    /// finish the job; if one of them failed for a real reason — the database
    /// locked, the disk full, the file read-only — nothing said so, and the
    /// symptom arrived later as "no such column" from an unrelated query.
    private func migrate() throws {
        var version = try schemaVersion()
        for (index, migration) in Self.migrations.enumerated() {
            let target = index + 1
            guard version < target else { continue }
            try transaction {
                try migration(self)
                try execute("PRAGMA user_version = \(target)")
            }
            version = target
        }
        hasFullTextIndex = (try? tableExists("segments_fts")) ?? false
    }

    private func schemaVersion() throws -> Int {
        try queryOne("PRAGMA user_version") { $0.int(0) ?? 0 } ?? 0
    }

    private func tableExists(_ name: String) throws -> Bool {
        try queryOne(
            "SELECT 1 FROM sqlite_master WHERE name = ?1",
            bind: { $0.bind(1, name) },
            row: { _ in true }
        ) ?? false
    }

    /// `@Sendable`, and spelled `SQLiteConnection.` rather than `Self.`: a
    /// stored static array of function references is shared mutable state to the
    /// concurrency checker unless the element type is Sendable, and `Self` is not
    /// allowed in a stored property initializer.
    private typealias Migration = @Sendable (SQLiteConnection) throws -> Void

    private static let migrations: [Migration] = [
        SQLiteConnection.migration1_baseSchema,
        SQLiteConnection.migration2_indexes,
        SQLiteConnection.migration3_fullTextSearch,
        SQLiteConnection.migration4_attendees,
    ]

    /// Every table in its **current** shape, plus the ADD COLUMNs that lift a
    /// database created by an earlier build to the same shape.
    ///
    /// Both halves are needed and neither is redundant: `CREATE TABLE IF NOT
    /// EXISTS` does nothing to a table that already exists, so a legacy
    /// database would keep its five missing columns; and on a fresh database
    /// every ADD COLUMN is a duplicate, which is why that one error — and only
    /// that one — is ignored.
    private static func migration1_baseSchema(_ db: SQLiteConnection) throws {
        try db.execute("""
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
            word_count INTEGER,
            engine TEXT,
            latency_ms INTEGER,
            source_app TEXT,
            enhanced INTEGER,
            raw_text TEXT,
            calendar_event_title TEXT,
            attendees TEXT
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS segments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            recording_id TEXT NOT NULL REFERENCES recordings(id),
            speaker TEXT,
            start_seconds REAL NOT NULL,
            end_seconds REAL,
            text TEXT NOT NULL
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS chat_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            recording_id TEXT NOT NULL REFERENCES recordings(id),
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """)
        // What each summarization round-trip spent. `recording_id` is a plain
        // column, **not** a foreign key: the meeting flow summarizes before it
        // inserts the recording (the summary and its auto-title have to land in
        // the same row), so an FK with `foreign_keys=ON` would reject the write.
        try db.execute("""
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

        for (column, type) in [
            ("summary", "TEXT"),
            ("subtitle", "TEXT"),
            ("folder", "TEXT"),
            ("title_is_auto", "INTEGER NOT NULL DEFAULT 0"),
            ("user_notes", "TEXT"),
            ("word_count", "INTEGER"),
            // Issue #5. All nullable and never backfilled: six weeks of existing
            // rows never had these values, and a guessed engine or latency would
            // be a fabricated measurement sitting in a statistics window.
            ("engine", "TEXT"),
            ("latency_ms", "INTEGER"),
            ("source_app", "TEXT"),
            ("enhanced", "INTEGER"),
            // The pre-enhancement text, so what the model changed stays visible.
            ("raw_text", "TEXT"),
            // "SQLite is the truth" — except this one used to live only in the
            // Markdown front matter, so every rename or move silently dropped it.
            ("calendar_event_title", "TEXT"),
        ] {
            try db.addColumn(column, type: type, to: "recordings")
        }
    }

    /// Indexes for the queries that are actually made.
    ///
    /// `recordings.started_at` is the sort key of `usageRows`,
    /// `recentActivity`, `recentMeetings`, `recentDictations` and the retention
    /// sweep — every one of them was a full scan.
    private static func migration2_indexes(_ db: SQLiteConnection) throws {
        try db.execute("CREATE INDEX IF NOT EXISTS idx_segments_recording ON segments(recording_id)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_chat_recording ON chat_messages(recording_id)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_llm_usage_created ON llm_usage(created_at)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_recordings_started ON recordings(started_at)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_recordings_kind_started ON recordings(kind, started_at)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_chat_created ON chat_messages(created_at)")
        // `recentActivity`'s correlated "first segment" subquery.
        try db.execute("CREATE INDEX IF NOT EXISTS idx_segments_recording_start ON segments(recording_id, start_seconds)")
    }

    /// FTS5 over `segments.text`, kept in sync by triggers.
    ///
    /// `unicode61 remove_diacritics 2` is the point: the `LIKE` search folded
    /// ASCII only, so "über" never found "Über" — while the snippet the same
    /// search rendered *was* diacritic-insensitive, so a hit could be shown
    /// with a snippet that did not contain the search term.
    ///
    /// Tolerated failure: a SQLite without FTS5 leaves `hasFullTextIndex`
    /// false and search falls back to `LIKE`. A missing index is a worse
    /// search; a throwing migration would be an app that cannot open its
    /// database.
    private static func migration3_fullTextSearch(_ db: SQLiteConnection) throws {
        do {
            try db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5(
                text,
                content='segments',
                content_rowid='id',
                tokenize="unicode61 remove_diacritics 2"
            )
            """)
        } catch {
            return
        }
        try db.execute("""
        CREATE TRIGGER IF NOT EXISTS segments_fts_insert AFTER INSERT ON segments BEGIN
            INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text);
        END
        """)
        try db.execute("""
        CREATE TRIGGER IF NOT EXISTS segments_fts_delete AFTER DELETE ON segments BEGIN
            INSERT INTO segments_fts(segments_fts, rowid, text) VALUES('delete', old.id, old.text);
        END
        """)
        // Retention empties `text` in place, so updates matter as much as
        // inserts: a cleared segment must leave the index too.
        try db.execute("""
        CREATE TRIGGER IF NOT EXISTS segments_fts_update AFTER UPDATE ON segments BEGIN
            INSERT INTO segments_fts(segments_fts, rowid, text) VALUES('delete', old.id, old.text);
            INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text);
        END
        """)
        try db.execute("INSERT INTO segments_fts(rowid, text) SELECT id, text FROM segments")
    }

    /// Who was invited, so a re-projected note can still say it.
    ///
    /// Same reasoning as `calendar_event_title`: the attendee list came from the
    /// calendar event at recording time and lived only in the Markdown file, so
    /// every rename, move or re-render dropped it. Newline-separated rather than
    /// JSON — names, one per line, is all this ever holds, and it stays readable
    /// in a SQLite browser.
    private static func migration4_attendees(_ db: SQLiteConnection) throws {
        try db.addColumn("attendees", type: "TEXT", to: "recordings")
    }

    /// Idempotent `ADD COLUMN`: only "duplicate column name" is ignored.
    ///
    /// Everything else — a locked database, a read-only file, a full disk —
    /// throws, which is the whole difference from the version this replaces.
    private func addColumn(_ column: String, type: String, to table: String) throws {
        do {
            try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
        } catch Failure.sqlite(let message) where message.contains("duplicate column name") {
            return
        }
    }
}
