import XCTest

/// Spec 36 §3.2: which five seconds of a speaker are worth playing, and which
/// archived session belongs to a note.
final class SpeakerSampleTests: XCTestCase {
    func testTheLoudestPassageWinsNotTheFirst() {
        // The first turn of a cluster is regularly "Mhm." — a sample that says
        // nothing is worse than none.
        let segments = [(start: 0.0, end: 2.0), (start: 10.0, end: 20.0)]
        let window = SpeakerSample.loudest(in: segments) { start, _ in start >= 12 ? 1 : 0.01 }
        XCTAssertNotNil(window)
        XCTAssertGreaterThanOrEqual(window?.start ?? 0, 12)
        XCTAssertLessThanOrEqual(window?.duration ?? 99, SpeakerSample.maximumSeconds)
    }

    func testAShortSegmentIsTakenWholeAndNeverLongerThanFiveSeconds() {
        let short = SpeakerSample.loudest(in: [(start: 3.0, end: 4.5)]) { _, _ in 1 }
        XCTAssertEqual(short, SpeakerSample.Window(start: 3, end: 4.5))

        let long = SpeakerSample.loudest(in: [(start: 0.0, end: 60.0)]) { _, _ in 1 }
        XCTAssertEqual(long?.duration ?? 99, SpeakerSample.maximumSeconds, accuracy: 0.001)
    }

    func testNoSegmentsNoSample() {
        XCTAssertNil(SpeakerSample.loudest(in: []) { _, _ in 1 })
        XCTAssertNil(SpeakerSample.loudest(in: [(start: 5.0, end: 5.0)]) { _, _ in 1 })
    }

    func testRMSIsClampedToTheTrack() {
        let samples: [Float] = [1, -1, 1, -1]
        XCTAssertEqual(SpeakerSample.rms(samples, from: 0, to: 4), 1, accuracy: 1e-6)
        XCTAssertEqual(SpeakerSample.rms(samples, from: -10, to: 99), 1, accuracy: 1e-6)
        XCTAssertEqual(SpeakerSample.rms(samples, from: 3, to: 3), 0)
    }

    // MARK: - Welche Sitzung zur Notiz gehört

    private func candidate(_ seconds: TimeInterval, _ name: String, note: String? = nil) -> SpeakerSample.ArchivedSession {
        SpeakerSample.ArchivedSession(
            directory: URL(fileURLWithPath: "/tmp/spool-archive/\(name)"),
            startedAt: Date(timeIntervalSince1970: seconds),
            notePath: note
        )
    }

    /// The only link between a recording row and a spool directory is the start
    /// instant — `produceNote` stamps the same `Date` into both.
    func testTheStartInstantIsTheJoin() {
        let candidates = [candidate(1_000, "a"), candidate(2_000, "b")]
        XCTAssertEqual(SpeakerSample.session(startedAt: Date(timeIntervalSince1970: 2_000.4),
                                             markdownPath: nil, in: candidates)?.lastPathComponent, "b")
        XCTAssertNil(SpeakerSample.session(startedAt: Date(timeIntervalSince1970: 5_000),
                                           markdownPath: nil, in: candidates),
                     "ohne passende Sitzung lieber nichts abspielen als die falsche")
    }

    func testTheNotePathBreaksATieInTheSameSecond() {
        let candidates = [
            candidate(1_000, "a", note: "/Notes/Inbox/Erste.md"),
            candidate(1_000.5, "b", note: "/Notes/Inbox/Zweite.md"),
        ]
        XCTAssertEqual(SpeakerSample.session(startedAt: Date(timeIntervalSince1970: 1_000),
                                             markdownPath: "/Notes/Inbox/Zweite.md", in: candidates)?.lastPathComponent,
                       "b")
    }

    func testTheLocalUserIsTheMicrophoneTrack() {
        XCTAssertEqual(SpeakerSample.track(for: SpeakerNameResolver.micSpeakerLabel), .mic)
        XCTAssertEqual(SpeakerSample.track(for: "Sprecher 1"), .system)
    }
}
