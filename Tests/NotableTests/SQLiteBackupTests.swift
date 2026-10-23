import SQLite3
import XCTest

/// Before a migration rewrites an existing database, a copy of it is taken
/// beside it. A fresh database gets none, and an older backup of another
/// version is never touched.
final class SQLiteBackupTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-backup-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directory.appendingPathComponent("notable.sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Reads one integer from a database without migrating it — opening a
    /// backup through `SQLiteConnection` would back it up in turn.
    private func readInt(_ sql: String, from url: URL) -> Int? {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(url.path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close_v2(raw)
            return nil
        }
        defer { sqlite3_close_v2(raw) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(raw, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("notable-v") }
            .sorted()
    }

    /// A database one migration behind: the current schema with
    /// `user_version` set back, which the last migration (idempotent DDL)
    /// then runs over again.
    private func makeDatabase(behindAt version: Int) throws {
        let db = try SQLiteConnection.open(at: databaseURL)
        try db.execute("CREATE TABLE marker (value INTEGER)")
        try db.execute("INSERT INTO marker VALUES (42)")
        try db.execute("PRAGMA user_version = \(version)")
    }

    func testBackupNameSitsBesideTheDatabase() {
        XCTAssertEqual(
            SQLiteConnection.backupURL(for: databaseURL, version: 8).path,
            directory.appendingPathComponent("notable-v8.sqlite").path
        )
    }

    func testFreshDatabaseIsNotBackedUp() throws {
        _ = try SQLiteConnection.open(at: databaseURL)
        XCTAssertEqual(backups(), [])
    }

    func testUpToDateDatabaseIsNotBackedUpAgain() throws {
        _ = try SQLiteConnection.open(at: databaseURL)
        _ = try SQLiteConnection.open(at: databaseURL)
        XCTAssertEqual(backups(), [])
    }

    func testPendingMigrationTakesACopyOfTheOldState() throws {
        let current = try XCTUnwrap(readIntAfterOpen())
        try makeDatabase(behindAt: current - 1)

        _ = try SQLiteConnection.open(at: databaseURL)

        let backup = SQLiteConnection.backupURL(for: databaseURL, version: current - 1)
        XCTAssertEqual(backups(), [backup.lastPathComponent])
        XCTAssertEqual(readInt("PRAGMA user_version", from: backup), current - 1, "Stand vor der Migration")
        XCTAssertEqual(readInt("SELECT value FROM marker", from: backup), 42, "mit den Daten")
        XCTAssertEqual(readInt("PRAGMA user_version", from: databaseURL), current, "die Migration lief trotzdem")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path + ".partial"))
    }

    /// An older backup of the same version is replaced; another version's
    /// backup is left alone.
    func testOnlyABackupOfTheSameVersionIsReplaced() throws {
        let current = try XCTUnwrap(readIntAfterOpen())
        try makeDatabase(behindAt: current - 1)
        let same = SQLiteConnection.backupURL(for: databaseURL, version: current - 1)
        let other = SQLiteConnection.backupURL(for: databaseURL, version: current - 2)
        try Data("alt".utf8).write(to: same)
        try Data("andere Version".utf8).write(to: other)

        _ = try SQLiteConnection.open(at: databaseURL)

        XCTAssertEqual(readInt("SELECT value FROM marker", from: same), 42)
        XCTAssertEqual(try Data(contentsOf: other), Data("andere Version".utf8))
    }

    /// The schema version a fresh database reaches, read the same way the
    /// backups are read.
    private func readIntAfterOpen() throws -> Int? {
        _ = try SQLiteConnection.open(at: databaseURL)
        return readInt("PRAGMA user_version", from: databaseURL)
    }
}
