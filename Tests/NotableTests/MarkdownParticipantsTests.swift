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
