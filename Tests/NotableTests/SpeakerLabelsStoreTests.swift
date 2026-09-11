import XCTest

/// Spec 24, Stufe 4: a correction the user makes once, holds — through the
/// projection, and against every automatic source.
final class SpeakerLabelsStoreTests: XCTestCase {
    private var directory: URL!
    private var store: RecordingStore!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-speakers-\(UUID().uuidString)", isDirectory: true)
        store = RecordingStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func meeting() -> RecordingStore.Recording {
        RecordingStore.Recording(
            id: UUID().uuidString, kind: .meeting, startedAt: Date(timeIntervalSince1970: 1000),
            endedAt: Date(timeIntervalSince1970: 1600), title: "Meeting",
            calendarEventID: nil, markdownPath: nil, summary: nil, subtitle: nil,
            folder: "Inbox", titleIsAuto: true
        )
    }

    private func segment(_ speaker: String, _ start: Double, _ end: Double, cluster: String?) -> RecordingStore.Segment {
        RecordingStore.Segment(speaker: speaker, start: start, end: end, text: "…", cluster: cluster)
    }

    func testRenameAndMergeHoldAndAnAutomaticRunDoesNotOverwriteTheUser() async throws {
        let recording = meeting()
        try await store.insertMeeting(recording, segments: [
            segment("Ich", 0, 1, cluster: "Ich"),
            segment("Anna", 2, 4, cluster: "Sprecher 1"),
            segment("Anna", 5, 6, cluster: "Sprecher 1"),
            segment("Sprecher 2", 7, 9, cluster: "Sprecher 2"),
        ], labels: [.init(cluster: "Sprecher 1", name: "Anna", source: .llm)])

        var labels = try await store.speakerLabels(for: recording.id)
        XCTAssertEqual(labels.map(\.cluster), ["Ich", "Sprecher 1", "Sprecher 2"])
        XCTAssertEqual(labels[1].name, "Anna")
        XCTAssertEqual(labels[1].source, .llm)
        XCTAssertEqual(labels[1].segmentCount, 2)
        XCTAssertEqual(labels[1].seconds, 3, accuracy: 0.001)
        XCTAssertNil(labels[2].source)

        try await store.renameSpeaker(recordingID: recording.id, cluster: "Sprecher 2", to: "Ben")
        try await store.recordSpeakerLabels([.init(cluster: "Sprecher 2", name: "Falsch", source: .llm)], recordingID: recording.id)
        labels = try await store.speakerLabels(for: recording.id)
        XCTAssertEqual(labels[2].name, "Ben")
        XCTAssertEqual(labels[2].source, .user, "kein späterer Lauf überschreibt den Nutzer")

        try await store.mergeSpeaker(recordingID: recording.id, cluster: "Sprecher 1", into: "Sprecher 2")
        labels = try await store.speakerLabels(for: recording.id)
        XCTAssertEqual(labels.map(\.cluster), ["Ich", "Sprecher 2"])
        XCTAssertEqual(labels[1].name, "Ben")
        XCTAssertEqual(labels[1].segmentCount, 3)
        let speakers = try await store.segments(for: recording.id).map(\.speaker)
        XCTAssertEqual(speakers, ["Ich", "Ben", "Ben", "Ben"])
    }

    func testTheLocalUserStaysFixed() async throws {
        let recording = meeting()
        try await store.insertMeeting(recording, segments: [segment("Ich", 0, 1, cluster: "Ich")])
        try await store.renameSpeaker(recordingID: recording.id, cluster: "Ich", to: "Jonas")
        let speakers = try await store.segments(for: recording.id).map(\.speaker)
        XCTAssertEqual(speakers, ["Ich"])
    }

    func testAnEmptyNameMakesASpeakerAnonymousAgain() async throws {
        let recording = meeting()
        try await store.insertMeeting(recording, segments: [segment("Anna", 0, 1, cluster: "Sprecher 1")],
                                      labels: [.init(cluster: "Sprecher 1", name: "Anna", source: .screen)])
        try await store.renameSpeaker(recordingID: recording.id, cluster: "Sprecher 1", to: "  ")
        let labels = try await store.speakerLabels(for: recording.id)
        XCTAssertEqual(labels.first?.name, "Sprecher 1")
        XCTAssertEqual(labels.first?.source, .user)
    }

    /// Meetings from before the column carry no cluster; the shown label
    /// becomes one when the user edits it — not an estimate.
    func testAMeetingFromBeforeTheColumnCanBeRenamed() async throws {
        let recording = meeting()
        try await store.insertMeeting(recording, segments: [
            segment("Ich", 0, 1, cluster: nil),
            segment("Lukas", 2, 3, cluster: nil),
            segment("Lukas", 4, 5, cluster: nil),
        ])
        let before = try await store.speakerLabels(for: recording.id)
        XCTAssertEqual(before.map(\.cluster), ["Ich", "Lukas"])

        try await store.renameSpeaker(recordingID: recording.id, cluster: "Lukas", to: "Lukas Maier")
        let segments = try await store.segments(for: recording.id)
        XCTAssertEqual(segments.map(\.speaker), ["Ich", "Lukas Maier", "Lukas Maier"])
        XCTAssertEqual(segments.map(\.cluster), [nil, "Lukas", "Lukas"])
    }

    func testParticipantsRoundTrip() async throws {
        var recording = meeting()
        recording.participants = ["Anna Weber", "Ben Kraus"]
        try await store.insertMeeting(recording, segments: [])
        let loaded = try await store.meeting(id: recording.id)?.recording
        XCTAssertEqual(loaded?.participants, ["Anna Weber", "Ben Kraus"])
    }
}
