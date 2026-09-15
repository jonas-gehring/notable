import XCTest

/// Spec 34 B: an app that keeps only its output open after hanging up has left
/// the call once the far side has been silent long enough — muted and listening
/// has not.
final class CallEndRuleTests: XCTestCase {
    func testHoldingTheMicrophoneIsAlwaysARunningCall() {
        for tier in [MeetingApps.Tier.dedicated, .browser, .ambient] {
            XCTAssertTrue(CallEndRule.isStillActive(tier: tier, holdsInput: true, holdsOutput: true, remoteSilentFor: 3600))
        }
    }

    func testMutedButListeningIsStillInTheCall() {
        XCTAssertTrue(CallEndRule.isStillActive(tier: .dedicated, holdsInput: false, holdsOutput: true, remoteSilentFor: 5))
    }

    func testAnAppKeepingOnlyASilentOutputHasLeftTheCall() {
        XCTAssertFalse(CallEndRule.isStillActive(tier: .dedicated, holdsInput: false, holdsOutput: true,
                                                 remoteSilentFor: CallEndRule.remoteSilenceForEnd))
    }

    func testWithoutASystemTrackTheOutputStillCounts() {
        XCTAssertTrue(CallEndRule.isStillActive(tier: .dedicated, holdsInput: false, holdsOutput: true, remoteSilentFor: nil))
    }

    func testNoAudioAtAllHasEnded() {
        XCTAssertFalse(CallEndRule.isStillActive(tier: .dedicated, holdsInput: false, holdsOutput: false, remoteSilentFor: nil))
    }

    func testBrowsersAndSlackNeverCountTheirOutput() {
        XCTAssertFalse(CallEndRule.isStillActive(tier: .browser, holdsInput: false, holdsOutput: true, remoteSilentFor: 0))
        XCTAssertFalse(CallEndRule.isStillActive(tier: .ambient, holdsInput: false, holdsOutput: true, remoteSilentFor: nil))
    }
}

/// Spec 34 C: three minutes without sound → ask; two more unanswered → stop.
final class MeetingSilenceWatchTests: XCTestCase {
    private let quiet: Float = 0.001
    private let between: Float = 0.01
    private let speech: Float = 0.05

    /// One observation per second from `from` through `to`, both included.
    private func feed(_ watch: inout MeetingSilenceWatch, mic: Float, system: Float?,
                      from: Int, to: Int) -> [MeetingSilenceWatch.Event] {
        guard from <= to else { return [] }
        return (from...to).compactMap { watch.observe(micLevel: mic, systemLevel: system, at: TimeInterval($0)) }
    }

    func testAsksAfterThreeMinutesAndStopsTwoMinutesLater() {
        var watch = MeetingSilenceWatch()
        XCTAssertEqual(feed(&watch, mic: quiet, system: quiet, from: 0, to: 179), [])
        XCTAssertEqual(feed(&watch, mic: quiet, system: quiet, from: 180, to: 180), [.ask])
        XCTAssertEqual(watch.silentMinutes, 3)
        XCTAssertEqual(feed(&watch, mic: quiet, system: quiet, from: 181, to: 299), [])
        XCTAssertEqual(feed(&watch, mic: quiet, system: quiet, from: 300, to: 300), [.stop])
    }

    /// The far side talking while I stay quiet is a meeting, not silence.
    func testTheFarSideSpeakingIsNotSilence() {
        var watch = MeetingSilenceWatch()
        XCTAssertEqual(feed(&watch, mic: quiet, system: speech, from: 0, to: 1000), [])
    }

    func testSoundAfterTheQuestionWithdrawsItAndTheCountStartsOver() {
        var watch = MeetingSilenceWatch()
        XCTAssertEqual(feed(&watch, mic: quiet, system: quiet, from: 0, to: 180), [.ask])
        XCTAssertEqual(feed(&watch, mic: speech, system: quiet, from: 200, to: 200), [.withdraw])
        XCTAssertEqual(feed(&watch, mic: quiet, system: quiet, from: 201, to: 380), [])
        XCTAssertEqual(feed(&watch, mic: quiet, system: quiet, from: 381, to: 381), [.ask])
    }

    func testKeepRecordingWaitsTenMinutesBeforeAskingAgain() {
        var watch = MeetingSilenceWatch()
        XCTAssertEqual(feed(&watch, mic: quiet, system: quiet, from: 0, to: 180), [.ask])
        watch.keepRecording(at: 190)
        XCTAssertEqual(feed(&watch, mic: quiet, system: quiet, from: 191, to: 789), [], "kein Stopp, keine Frage")
        XCTAssertEqual(feed(&watch, mic: quiet, system: quiet, from: 790, to: 790), [.ask])
        XCTAssertEqual(watch.silentMinutes, 10)
    }

    /// Room noise hovering between the thresholds neither starts nor resets.
    func testTheBandBetweenThresholdsKeepsTheState() {
        var never = MeetingSilenceWatch()
        XCTAssertEqual(feed(&never, mic: between, system: between, from: 0, to: 1000), [], "startet keine Stille")

        var counting = MeetingSilenceWatch()
        XCTAssertEqual(feed(&counting, mic: quiet, system: quiet, from: 0, to: 60), [])
        XCTAssertEqual(feed(&counting, mic: between, system: quiet, from: 61, to: 180), [.ask], "setzt sie nicht zurück")
    }

    func testWithoutASystemTrackTheMicrophoneDecidesAlone() {
        var watch = MeetingSilenceWatch()
        XCTAssertEqual(feed(&watch, mic: quiet, system: nil, from: 0, to: 180), [.ask])
    }
}

/// Spec 34 D: the lifecycle fields in `meta.json`, and that an old file without
/// them still recovers.
final class SpoolMetaLifecycleTests: XCTestCase {
    func testAMetaFromBeforeSpec34StillDecodes() throws {
        let meta = try JSONDecoder().decode(SpoolStore.Meta.self, from: Data(#"{"startedAt": 0}"#.utf8))
        XCTAssertNil(meta.startMode)
        XCTAssertNil(meta.endReason)
    }

    func testAMalformedLifecycleFieldDoesNotCostTheMeeting() throws {
        let json = #"{"startedAt": 0, "endReason": 42}"#
        let meta = try JSONDecoder().decode(SpoolStore.Meta.self, from: Data(json.utf8))
        XCTAssertNil(meta.endReason)
    }

    func testLifecycleFieldsRoundTrip() throws {
        let meta = SpoolStore.Meta(startedAt: Date(timeIntervalSinceReferenceDate: 0),
                                   startMode: "manual", callSource: "Microsoft Teams",
                                   endReason: MeetingEndReason.callEnded.rawValue)
        let decoded = try JSONDecoder().decode(SpoolStore.Meta.self, from: JSONEncoder().encode(meta))
        XCTAssertEqual(decoded.startMode, "manual")
        XCTAssertEqual(decoded.callSource, "Microsoft Teams")
        XCTAssertEqual(decoded.endReason, "callEnded")
    }
}
