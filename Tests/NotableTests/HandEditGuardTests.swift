import XCTest

/// A note's `.md` is rebuilt from SQLite on every rename, move and notes save.
/// What the user typed into the file by hand must survive that as a copy, and
/// a file nobody touched must not grow one.
final class HandEditGuardTests: XCTestCase {
    private let before = "# Weekly\n\n## Transkript\n\n**Ich:** Hallo\n"
    private let after = "# Weekly Sync\n\n## Transkript\n\n**Ich:** Hallo\n"

    func testUntouchedFileIsSimplyReplaced() {
        XCTAssertEqual(
            HandEditGuard.decide(onDisk: Data(before.utf8), lastWritten: before, replacement: after),
            .overwrite
        )
    }

    func testMissingFileHasNothingToKeep() {
        XCTAssertEqual(HandEditGuard.decide(onDisk: nil, lastWritten: before, replacement: after), .overwrite)
    }

    /// A second save with nothing changed, or a file someone already brought to
    /// the new state: writing loses nothing.
    func testFileAlreadyHoldingTheReplacementNeedsNoCopy() {
        XCTAssertEqual(
            HandEditGuard.decide(onDisk: Data(after.utf8), lastWritten: before, replacement: after),
            .overwrite
        )
    }

    func testHandEditIsKept() {
        let edited = before + "\nNachtrag aus Obsidian\n"
        XCTAssertEqual(
            HandEditGuard.decide(onDisk: Data(edited.utf8), lastWritten: before, replacement: after),
            .keepCopy
        )
    }

    /// Bytes, not text: an editor that only appended a newline did change the
    /// file, and the comparison must not decide for the user that it did not
    /// matter.
    func testEvenATrailingNewlineCounts() {
        XCTAssertEqual(
            HandEditGuard.decide(onDisk: Data((before + "\n").utf8), lastWritten: before, replacement: after),
            .keepCopy
        )
    }

    func testFileThatIsNotTextIsKept() {
        XCTAssertEqual(
            HandEditGuard.decide(onDisk: Data([0xFF, 0xFE, 0x00]), lastWritten: before, replacement: after),
            .keepCopy
        )
    }

    // MARK: - Copy name

    func testCopyNameKeepsDateTitleAndExtension() {
        XCTAssertEqual(
            HandEditGuard.copyName(for: "2026-10-01 09.30 Weekly.md") { _ in false },
            "2026-10-01 09.30 Weekly (bearbeitet).md"
        )
    }

    func testEarlierCopiesAreNeverOverwritten() {
        let taken: Set<String> = [
            "2026-10-01 09.30 Weekly (bearbeitet).md",
            "2026-10-01 09.30 Weekly (bearbeitet 2).md",
        ]
        XCTAssertEqual(
            HandEditGuard.copyName(for: "2026-10-01 09.30 Weekly.md") { taken.contains($0) },
            "2026-10-01 09.30 Weekly (bearbeitet 3).md"
        )
    }

    func testNameWithoutExtension() {
        XCTAssertEqual(HandEditGuard.copyName(for: "Notiz") { _ in false }, "Notiz (bearbeitet)")
    }

    /// The projection is written as UTF-8 without a BOM — the comparison rests
    /// on that, so it is pinned against the real write path.
    func testWrittenProjectionReadsBackAsItsOwnBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-handedit-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = "# Übergabe – Café\n\n**Sprecher 1:** 30 € für 🙂\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            HandEditGuard.decide(onDisk: try Data(contentsOf: url), lastWritten: text, replacement: after),
            .overwrite
        )
    }
}
