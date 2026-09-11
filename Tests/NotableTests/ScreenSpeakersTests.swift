import XCTest

/// Spec 24, the pure half of reading the call window. Every rule errs towards
/// leaving a label anonymous: a wrong name is worse than `Sprecher n`.
final class ScreenSpeakersTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let owner: Set<String> = ["jonas", "gehring"]

    private func observation(_ second: Double, roster: [String] = [], active: [String] = []) -> ScreenObservation {
        ScreenObservation(at: t0.addingTimeInterval(second), source: .accessibility, roster: roster, activeSpeakers: active)
    }

    private func interval(_ name: String, _ start: Double, _ end: Double) -> ScreenTimeline.Interval {
        ScreenTimeline.Interval(name: name, start: start, end: end)
    }

    // MARK: - Timeline

    func testOnlyASingleHighlightCounts() {
        let intervals = ScreenTimeline.speakingIntervals(
            [observation(0, active: ["Anna"]), observation(1, active: ["Anna", "Ben"]), observation(2)],
            recordingStart: t0
        )
        XCTAssertEqual(intervals, [interval("Anna", 0, 1)])
    }

    /// A gap in the sampling is not someone speaking for its whole length.
    func testHighlightsMergeButAGapDoesNotStretchThem() {
        let intervals = ScreenTimeline.speakingIntervals(
            [observation(0, active: ["Anna"]), observation(1, active: ["Anna"]), observation(10, active: ["Anna"])],
            recordingStart: t0
        )
        XCTAssertEqual(intervals, [interval("Anna", 0, 3), interval("Anna", 10, 12)])
    }

    // MARK: - Roster

    func testExpectedRemoteSpeakersIsTheMostVisibleAtOnceMinusTheUser() {
        let observations = [observation(0, roster: ["Anna", "Jonas"]), observation(1, roster: ["Anna", "Ben", "Jonas"])]
        XCTAssertEqual(ScreenRoster.expectedRemoteSpeakers(observations), 2)
        XCTAssertNil(ScreenRoster.expectedRemoteSpeakers([observation(0, roster: ["Jonas"])]))
        XCTAssertNil(ScreenRoster.expectedRemoteSpeakers([]))
    }

    func testRemoteParticipantsLeaveOutTheLocalUser() {
        let observations = [observation(0, roster: ["Jonas Gehring (Du)", "Anna Weber", "Du"]),
                            observation(1, roster: ["anna weber", "You"])]
        XCTAssertEqual(ScreenRoster.remoteParticipants(observations, ownerTokens: owner), ["Anna Weber"])
    }

    func testOneToOneNeedsOnePersonAndOneLargeCluster() {
        XCTAssertEqual(ScreenRoster.oneToOneName(remoteParticipants: ["Anna"], largeClusters: ["Sprecher 1"])?.name, "Anna")
        XCTAssertNil(ScreenRoster.oneToOneName(remoteParticipants: ["Anna", "Ben"], largeClusters: ["Sprecher 1"]))
        XCTAssertNil(ScreenRoster.oneToOneName(remoteParticipants: ["Anna"], largeClusters: ["Sprecher 1", "Sprecher 2"]))
    }

    // MARK: - Assignment

    private func assign(_ segments: [ScreenSpeakerAssignment.Segment], _ intervals: [ScreenTimeline.Interval],
                        delay: TimeInterval = 0) -> ScreenSpeakerAssignment.Result {
        ScreenSpeakerAssignment.assign(segments, intervals: intervals, delay: delay, ownerTokens: owner)
    }

    private func seg(_ cluster: String, _ start: Double, _ end: Double) -> ScreenSpeakerAssignment.Segment {
        ScreenSpeakerAssignment.Segment(cluster: cluster, start: start, end: end)
    }

    func testTheDominantNameWins() {
        XCTAssertEqual(assign([seg("Sprecher 1", 0, 20)], [interval("Anna", 0, 18)]).names, ["Sprecher 1": "Anna"])
    }

    func testTooLittleCoverageNamesNothing() {
        XCTAssertEqual(assign([seg("Sprecher 1", 0, 100)], [interval("Anna", 0, 5)]).names, [:])
    }

    func testTheLocalUserIsNeverATarget() {
        let result = assign([seg("Sprecher 1", 0, 20)], [interval("Jonas Gehring", 0, 20)])
        XCTAssertEqual(result.names, [:])
    }

    /// Two clusters, one name: the diarizer split a person — independent
    /// evidence, so here they merge, into the one with more speech.
    func testTwoClustersWithOneNameMergeIntoTheLonger() {
        let result = assign([seg("Sprecher 3", 0, 10), seg("Sprecher 5", 20, 50)],
                            [interval("Anna", 0, 10), interval("Anna", 20, 50)])
        XCTAssertEqual(result.names, ["Sprecher 3": "Anna", "Sprecher 5": "Anna"])
        XCTAssertEqual(result.merges, ["Sprecher 3": "Sprecher 5"])
    }

    /// One cluster, two people: named segment by segment, and only where one
    /// name covers at least 80 % of it.
    func testOneClusterHoldingTwoPeopleIsNamedSegmentBySegment() {
        let segments = [seg("Sprecher 1", 0, 10), seg("Sprecher 1", 10, 20), seg("Sprecher 1", 20, 30)]
        let result = assign(segments, [interval("Anna", 0, 10), interval("Ben", 10, 20),
                                       interval("Anna", 20, 25), interval("Ben", 25, 30)])
        XCTAssertEqual(result.names, [:])
        XCTAssertEqual(result.segmentNames, [0: "Anna", 1: "Ben"])
    }

    func testTheDisplayDelayIsTakenOutOfTheTimeline() {
        let segments = [seg("Sprecher 1", 0, 10), seg("Sprecher 2", 10, 20)]
        let intervals = [interval("Anna", 5, 15), interval("Ben", 15, 25)]
        XCTAssertNil(assign(segments, intervals).names["Sprecher 2"], "ohne Verzögerung halb Anna, halb Ben")
        XCTAssertEqual(assign(segments, intervals, delay: 5).names, ["Sprecher 1": "Anna", "Sprecher 2": "Ben"])
    }

    // MARK: - Self-check on the local user's own voice

    private let ownSpeech: [(start: TimeInterval, end: TimeInterval)] = [(0, 5), (10, 15), (20, 25)]

    func testAHighlightThatFollowsTheOwnVoiceIsTrusted() throws {
        let highlights = [interval("Du", 0.5, 5.5), interval("Du", 10.5, 15.5), interval("Du", 20.5, 25.5)]
        let outcome = try XCTUnwrap(ScreenSelfCheck.evaluate(ownSpeech: ownSpeech, highlights: highlights, ownerTokens: owner))
        XCTAssertEqual(outcome.delay, 0.5, accuracy: 0.001)
        XCTAssertEqual(outcome.agreement, 1, accuracy: 0.001)
        XCTAssertTrue(ScreenSelfCheck.trusts(outcome))
    }

    /// A deliberately wrong adapter: the "own" highlight sits between the
    /// user's utterances. Stufe 3 must not be applied to such a meeting.
    func testAShiftedAdapterIsNotTrusted() {
        let highlights = [interval("Jonas Gehring", 5, 10), interval("Jonas Gehring", 15, 20), interval("Jonas Gehring", 25, 30)]
        let outcome = ScreenSelfCheck.evaluate(ownSpeech: ownSpeech, highlights: highlights, ownerTokens: owner)
        XCTAssertFalse(ScreenSelfCheck.trusts(outcome))
    }

    func testWithoutOwnSpeechThereIsNoVerdict() {
        XCTAssertNil(ScreenSelfCheck.evaluate(ownSpeech: [], highlights: [], ownerTokens: owner))
        XCTAssertFalse(ScreenSelfCheck.trusts(nil))
    }

    // MARK: - Spool

    func testObservationsSurviveInTheSpoolAndATornLineIsSkipped() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("notable-screen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let session = try SpoolStore.create(meta: SpoolStore.Meta(startedAt: t0), base: base)
        let first = observation(0, roster: ["Anna"], active: ["Anna"])
        let second = observation(1, roster: ["Anna", "Ben"], active: [])
        SpoolStore.appendScreenObservation(first, to: session)
        SpoolStore.appendScreenObservation(second, to: session)
        let handle = try FileHandle(forWritingTo: session.screenURL)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"at":"#.utf8))
        try handle.close()

        XCTAssertEqual(SpoolStore.readScreenObservations(session), [first, second])
    }
}
