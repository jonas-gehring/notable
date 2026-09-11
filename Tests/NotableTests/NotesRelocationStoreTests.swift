import XCTest

/// Spec 27, Stufe 2: when the notes folder moves, the stored paths move with it —
/// otherwise every "Im Finder zeigen" and every later rename points at nothing.
final class NotesRelocationStoreTests: XCTestCase {
    private func meeting(_ path: String?) -> RecordingStore.Recording {
        RecordingStore.Recording(
            id: UUID().uuidString, kind: .meeting, startedAt: Date(timeIntervalSince1970: 1000),
            endedAt: Date(timeIntervalSince1970: 1600), title: "Meeting",
            calendarEventID: nil, markdownPath: path, summary: nil, subtitle: nil,
            folder: "Inbox", titleIsAuto: true
        )
    }

    func testEveryPathUnderTheFolderFollowsAndNothingElse() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-relocate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecordingStore(directory: dir)

        let inbox = meeting("/Users/u/Documents/Notable/Inbox/a.md")
        let project = meeting("/Users/u/Documents/Notable/Kunde/b.md")
        let lookalike = meeting("/Users/u/Documents/Notable2/c.md")
        let unplaced = meeting(nil)
        for recording in [inbox, project, lookalike, unplaced] {
            try await store.insertMeeting(recording, segments: [])
        }

        let target = "/Users/u/Library/Mobile Documents/com~apple~CloudDocs/Notable"
        let moved = try await store.relocateMarkdownPaths(from: "/Users/u/Documents/Notable", to: target)
        XCTAssertEqual(moved, 2)

        let inboxAfter = try await store.meeting(id: inbox.id)?.recording.markdownPath
        let projectAfter = try await store.meeting(id: project.id)?.recording.markdownPath
        let lookalikeAfter = try await store.meeting(id: lookalike.id)?.recording.markdownPath
        let unplacedAfter = try await store.meeting(id: unplaced.id)?.recording.markdownPath
        XCTAssertEqual(inboxAfter, target + "/Inbox/a.md")
        XCTAssertEqual(projectAfter, target + "/Kunde/b.md")
        XCTAssertEqual(lookalikeAfter, "/Users/u/Documents/Notable2/c.md", "gleicher Präfix, anderer Ordner")
        XCTAssertNil(unplacedAfter)
    }
}
