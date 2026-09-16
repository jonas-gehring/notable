import XCTest

/// Spec 36, Stufe 3, in the store: what a meeting teaches a profile, and what a
/// correction takes back out of it.
///
/// Every test passes `learnsVoice:` explicitly — the switch is off by default
/// and none of this may depend on the machine it runs on.
final class VoiceProfileStoreTests: XCTestCase {
    private var directory: URL!
    private var store: RecordingStore!
    /// Two voices, far apart, so nothing here depends on the threshold.
    private let anna: [Float] = [1, 0, 0]
    private let ben: [Float] = [0, 1, 0]

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-voices-\(UUID().uuidString)", isDirectory: true)
        store = RecordingStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func meeting(_ startedAt: TimeInterval, labels: [RecordingStore.SpeakerLabelRecord] = []) async throws -> String {
        let recording = RecordingStore.Recording(
            id: UUID().uuidString, kind: .meeting, startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: Date(timeIntervalSince1970: startedAt + 600), title: "Meeting",
            folder: "Inbox", titleIsAuto: true
        )
        try await store.insertMeeting(recording, segments: [
            RecordingStore.Segment(speaker: labels.first?.name ?? "Sprecher 1", start: 0, end: 300, text: "…",
                                   cluster: "Sprecher 1"),
        ], labels: labels)
        return recording.id
    }

    private func profile(_ name: String) async throws -> VoiceProfiles.Profile? {
        try await store.voiceProfiles().first { $0.id == VoiceProfiles.identifier(for: name) }
    }

    /// A confirmed name (here: the calendar's one-to-one) becomes a profile, and
    /// a second meeting with the same name is a second meeting of one profile,
    /// not a second profile.
    func testAConfirmedNameBecomesAProfileAndGrows() async throws {
        let first = try await meeting(1_000, labels: [.init(cluster: "Sprecher 1", name: "Anna Weber", source: .calendar)])
        try await store.rememberVoices(["Sprecher 1": anna], confirmed: ["Sprecher 1": "Anna Weber"], recordingID: first)
        var stored = try await store.voiceProfiles()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.name, "Anna Weber")
        XCTAssertEqual(stored.first?.meetings, 1)

        let second = try await meeting(2_000, labels: [.init(cluster: "Sprecher 1", name: "Anna Weber", source: .calendar)])
        try await store.rememberVoices(["Sprecher 1": anna], confirmed: ["Sprecher 1": "Anna Weber"], recordingID: second)
        stored = try await store.voiceProfiles()
        XCTAssertEqual(stored.count, 1, "derselbe Name ist ein Profil, keine zwei")
        XCTAssertEqual(stored.first?.meetings, 2)
    }

    /// The centroids of a meeting are kept even when nothing confirmed a name —
    /// otherwise a correction made days later would have nothing to learn from.
    func testAnUnnamedClusterIsKeptButTeachesNobody() async throws {
        let id = try await meeting(1_000)
        try await store.rememberVoices(["Sprecher 1": anna], recordingID: id)
        let none = try await store.voiceProfiles()
        XCTAssertTrue(none.isEmpty, "ohne Bestätigung entsteht kein Profil")

        try await store.renameSpeaker(recordingID: id, cluster: "Sprecher 1", to: "Ben Kraus", learnsVoice: true)
        let learned = try await profile("Ben Kraus")
        XCTAssertEqual(learned?.meetings, 1, "die Korrektur ist der Trainingsdatensatz")
    }

    /// §3.3: the wrong profile loses this cluster, the right name gains it.
    func testACorrectionRetractsTheWrongProfileAndCreditsTheRightOne() async throws {
        let first = try await meeting(1_000, labels: [.init(cluster: "Sprecher 1", name: "Anna Weber", source: .calendar)])
        try await store.rememberVoices(["Sprecher 1": anna], confirmed: ["Sprecher 1": "Anna Weber"], recordingID: first)
        let second = try await meeting(2_000, labels: [.init(cluster: "Sprecher 1", name: "Anna Weber", source: .screen)])
        try await store.rememberVoices(["Sprecher 1": ben], confirmed: ["Sprecher 1": "Anna Weber"], recordingID: second)
        let both = try await profile("Anna Weber")
        XCTAssertEqual(both?.meetings, 2)

        try await store.renameSpeaker(recordingID: second, cluster: "Sprecher 1", to: "Ben Kraus", learnsVoice: true)

        let annaAfter = try await profile("Anna Weber")
        let benAfter = try await profile("Ben Kraus")
        XCTAssertEqual(annaAfter?.meetings, 1, "das falsche Profil verliert diesen Cluster")
        XCTAssertEqual(benAfter?.meetings, 1, "der richtige Name bekommt ihn")
        // And what is left of the retracted profile is the voice of the *first*
        // meeting — the subtraction is exact, not approximate.
        let annaVector = try XCTUnwrap(annaAfter?.vector)
        XCTAssertEqual(VoiceProfiles.distance(annaVector, anna), 0, accuracy: 1e-5)
        let benVector = try XCTUnwrap(benAfter?.vector)
        XCTAssertEqual(VoiceProfiles.distance(benVector, ben), 0, accuracy: 1e-5)

        let labels = try await store.speakerLabels(for: second)
        XCTAssertEqual(labels.first?.source, .user)
    }

    /// A name that was never learned for this meeting must not be subtracted
    /// from — a `voice` match does not feed itself back, and retracting a
    /// contribution that was never made would bend the profile away from the
    /// person it belongs to.
    func testAMatchThatWasNeverLearnedIsNotSubtracted() async throws {
        let learned = try await meeting(1_000, labels: [.init(cluster: "Sprecher 1", name: "Anna Weber", source: .calendar)])
        try await store.rememberVoices(["Sprecher 1": anna], confirmed: ["Sprecher 1": "Anna Weber"], recordingID: learned)

        // The next meeting is named by the voice — stored, but not learned from.
        let matched = try await meeting(2_000, labels: [.init(cluster: "Sprecher 1", name: "Anna Weber", source: .voice)])
        try await store.rememberVoices(["Sprecher 1": ben], recordingID: matched)
        let before = try await profile("Anna Weber")
        XCTAssertEqual(before?.meetings, 1)

        try await store.renameSpeaker(recordingID: matched, cluster: "Sprecher 1", to: "Ben Kraus", learnsVoice: true)
        let annaAfter = try await profile("Anna Weber")
        let benAfter = try await profile("Ben Kraus")
        XCTAssertEqual(annaAfter?.meetings, 1, "unverändert — hier wurde nie etwas gelernt")
        XCTAssertEqual(benAfter?.meetings, 1)
    }

    func testWithTheSwitchOffNothingIsLearned() async throws {
        let id = try await meeting(1_000)
        try await store.rememberVoices(["Sprecher 1": anna], recordingID: id)
        try await store.renameSpeaker(recordingID: id, cluster: "Sprecher 1", to: "Ben Kraus", learnsVoice: false)
        let stored = try await store.voiceProfiles()
        XCTAssertTrue(stored.isEmpty)
        // The correction itself still holds — it is a note, not a voice.
        let labels = try await store.speakerLabels(for: id)
        XCTAssertEqual(labels.first?.name, "Ben Kraus")
    }

    /// "Vergessen" removes the voice and leaves the notes exactly as they are:
    /// the name that was applied is a fact about that meeting.
    func testForgettingAProfileLeavesTheNoteAlone() async throws {
        let id = try await meeting(1_000, labels: [.init(cluster: "Sprecher 1", name: "Anna Weber", source: .calendar)])
        try await store.rememberVoices(["Sprecher 1": anna], confirmed: ["Sprecher 1": "Anna Weber"], recordingID: id)
        let existing = try await profile("Anna Weber")
        let stored = try XCTUnwrap(existing)

        try await store.forgetVoiceProfile(id: stored.id)
        let remaining = try await store.voiceProfiles()
        XCTAssertTrue(remaining.isEmpty)

        let labels = try await store.speakerLabels(for: id)
        XCTAssertEqual(labels.first?.name, "Anna Weber")
        XCTAssertEqual(labels.first?.source, .calendar)
        let segments = try await store.segments(for: id)
        XCTAssertEqual(segments.first?.speaker, "Anna Weber")

        // And the freed cluster can be learned again without a ghost behind it.
        try await store.renameSpeaker(recordingID: id, cluster: "Sprecher 1", to: "Ben Kraus", learnsVoice: true)
        let benAfter = try await profile("Ben Kraus")
        let annaAfter = try await profile("Anna Weber")
        XCTAssertEqual(benAfter?.meetings, 1)
        XCTAssertNil(annaAfter)
    }
}
