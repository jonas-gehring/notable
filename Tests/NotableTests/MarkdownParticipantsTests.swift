import XCTest

/// Spec 24 §4.3: who the call showed goes into the note — beside, not instead
/// of, who was invited.
final class MarkdownParticipantsTests: XCTestCase {
    private func note(attendees: [String] = [], participants: [String] = []) -> MarkdownProjector.Note {
        MarkdownProjector.Note(
            title: "Sync", date: Date(timeIntervalSince1970: 0), calendarEventTitle: nil,
            attendees: attendees, participants: participants,
            segments: [("Ich", "Hallo."), ("Anna Weber", "Hallo zurück.")], summary: nil
        )
    }

    func testParticipantsStandBesideTheInvitation() {
        let markdown = MarkdownProjector.render(note(attendees: ["Anna Weber", "Ben Kraus"], participants: ["Anna Weber"]))
        XCTAssertTrue(markdown.contains("participants:\n  - \"Anna Weber\""))
        XCTAssertTrue(markdown.contains("Eingeladen: Anna Weber, Ben Kraus\nIm Call: Anna Weber\n"))
    }

    /// Without a screen reading, the note is byte for byte what it was.
    func testNoParticipantsNoLine() {
        let markdown = MarkdownProjector.render(note(attendees: ["Anna Weber"]))
        XCTAssertFalse(markdown.contains("participants:"))
        XCTAssertFalse(markdown.contains("Im Call:"))
    }
}

/// Where a passage sits in the recording, in front of every transcript line.
final class MarkdownTimestampTests: XCTestCase {
    private func note(startTimes: [TimeInterval]?) -> MarkdownProjector.Note {
        MarkdownProjector.Note(
            title: "Test", date: Date(timeIntervalSince1970: 1_780_000_000), calendarEventTitle: nil,
            segments: [("Ich", "Hallo."), ("Anna Weber", "Hallo zurück.")], summary: nil,
            startTimes: startTimes
        )
    }

    func testEveryLineCarriesItsStart() {
        let markdown = MarkdownProjector.render(note(startTimes: [5, 3723]))
        XCTAssertTrue(markdown.contains("[00:05] **Ich:** Hallo."))
        XCTAssertTrue(markdown.contains("[1:02:03] **Anna Weber:** Hallo zurück."))
    }

    /// Without times, or with times that do not fit, the transcript reads as before.
    func testNoOrMismatchedTimesRenderNone() {
        XCTAssertTrue(MarkdownProjector.render(note(startTimes: nil)).contains("\n**Ich:** Hallo."))
        XCTAssertTrue(MarkdownProjector.render(note(startTimes: [5])).contains("\n**Ich:** Hallo."))
    }

    func testTimestampFormat() {
        XCTAssertEqual(MarkdownProjector.timestamp(0), "00:00")
        XCTAssertEqual(MarkdownProjector.timestamp(187.9), "03:07")
        XCTAssertEqual(MarkdownProjector.timestamp(3723), "1:02:03")
        XCTAssertEqual(MarkdownProjector.timestamp(-3), "00:00")
    }
}
