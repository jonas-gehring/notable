import XCTest

final class ReviewFixTests: XCTestCase {
    @MainActor
    func testTypingChunksNeverSplitSurrogatePairs() {
        let text = "Hallo 👨‍👩‍👧‍👦 Welt 🎉 und noch mehr Text danach für mehrere Chunks."
        let chunks = Paster.utf16Chunks(of: text, limit: 20)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 22, "Ein Zeichen darf das Limit nur als Ganzes überschreiten")
            let roundTrip = String(utf16CodeUnits: chunk, count: chunk.count)
            XCTAssertFalse(roundTrip.contains("\u{FFFD}"), "Chunk zerreißt ein Surrogatpaar: \(chunk)")
        }
        let rejoined = chunks.map { String(utf16CodeUnits: $0, count: $0.count) }.joined()
        XCTAssertEqual(rejoined, text)
    }

    func testYamlFrontmatterEscapesBackslashesAndNewlines() {
        let note = MarkdownProjector.Note(
            title: "Pfad \\ mit \"Quotes\"\nund Zeile",
            date: Date(timeIntervalSince1970: 1_780_000_000),
            calendarEventTitle: nil,
            segments: [],
            summary: nil
        )
        let markdown = MarkdownProjector.render(note)
        let titleLine = markdown.split(separator: "\n").first { $0.hasPrefix("title:") }!
        XCTAssertTrue(titleLine.contains("\\\\"), "Backslash muss escaped sein: \(titleLine)")
        XCTAssertTrue(titleLine.contains("\\\""), "Quote muss escaped sein: \(titleLine)")
        // Frontmatter block (between the two --- fences) must stay one line per key.
        let frontmatter = markdown.components(separatedBy: "---")[1]
        XCTAssertEqual(
            frontmatter.split(separator: "\n").filter { $0.hasPrefix("title:") }.count, 1,
            "Newline darf das Frontmatter nicht brechen: \(frontmatter)"
        )
        XCTAssertTrue(titleLine.contains("und Zeile"), "Titeltext muss (mit Leerzeichen statt Newline) erhalten bleiben")
    }

    func testFileNameUsesLocalCalendarDay() {
        // 23:30 local on some day — date part and time part must agree.
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 5
        components.hour = 23; components.minute = 30
        let date = Calendar.current.date(from: components)!
        let name = MarkdownProjector.fileName(title: "Late", date: date)
        XCTAssertTrue(name.hasPrefix("2026-03-05 23.30"), "Lokales Datum erwartet: \(name)")
    }
}
