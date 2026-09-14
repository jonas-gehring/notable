import XCTest
@testable import Notable

/// Spec 29. Every silent dead end of the old dictation path, as a decision that
/// can be checked. The controller carries these out; if one of them regresses,
/// it regresses here first.
final class DictationPipelineTests: XCTestCase {
    // MARK: - Start

    func testGrantedAndOrdinaryFieldStarts() {
        XCTAssertEqual(DictationPipeline.start(permission: .granted, secureInput: false, knownSilent: false), .start)
    }

    /// A denied device still opens and records zeros. Key-down is the only moment
    /// the real cause can be named.
    func testDeniedMicrophoneRefusesOnKeyDown() {
        XCTAssertEqual(
            DictationPipeline.start(permission: .denied, secureInput: false, knownSilent: false),
            .refuse(.microphoneDenied)
        )
    }

    func testUndeterminedPermissionAsksAndDoesNotRecord() {
        XCTAssertEqual(
            DictationPipeline.start(permission: .notDetermined, secureInput: false, knownSilent: false),
            .requestPermission
        )
    }

    func testPermissionOutranksEveryOtherReason() {
        XCTAssertEqual(
            DictationPipeline.start(permission: .denied, secureInput: true, knownSilent: true),
            .refuse(.microphoneDenied)
        )
    }

    func testSecureInputRefusesBeforeRecording() {
        XCTAssertEqual(
            DictationPipeline.start(permission: .granted, secureInput: true, knownSilent: false),
            .refuse(.secureInput)
        )
    }

    func testClosedLidWithoutAlternativeRefuses() {
        XCTAssertEqual(
            DictationPipeline.start(permission: .granted, secureInput: false, knownSilent: true),
            .refuse(.lidClosed)
        )
    }

    // MARK: - Role

    func testRoleIsTakenFromTheKeyThatStarts() {
        XCTAssertTrue(DictationPipeline.enhanceRequested(after: .start, pressed: .enhanced, current: false))
        XCTAssertFalse(DictationPipeline.enhanceRequested(after: .start, pressed: .plain, current: true))
    }

    /// Ending a plain hands-free dictation with the enhance key must not send it
    /// off the device.
    func testStoppingAPlainLockWithTheEnhanceKeyKeepsItPlain() {
        XCTAssertFalse(DictationPipeline.enhanceRequested(after: .finish, pressed: .enhanced, current: false))
    }

    /// And the reverse must not silently drop an enhancement that was asked for.
    func testStoppingAnEnhancedLockWithThePlainKeyKeepsTheEnhancement() {
        XCTAssertTrue(DictationPipeline.enhanceRequested(after: .finish, pressed: .plain, current: true))
    }

    /// Spec 32 Stufe 2: the same rule for all three roles.
    func testTheStartedRoleIncludesCommands() {
        XCTAssertEqual(DictationPipeline.startedRole(after: .start, pressed: .command, current: .plain), .command)
        XCTAssertEqual(DictationPipeline.startedRole(after: .finish, pressed: .command, current: .plain), .plain)
        XCTAssertEqual(DictationPipeline.startedRole(after: .finish, pressed: .plain, current: .command), .command)
    }

    func testANoOpPressChangesNothing() {
        XCTAssertTrue(DictationPipeline.enhanceRequested(after: .none, pressed: .plain, current: true))
    }

    // MARK: - Stop

    func testNormalRecordingIsTranscribed() {
        XCTAssertEqual(
            DictationPipeline.afterStop(duration: 2, minimumDuration: 0.3, peak: 0.2, device: "MacBook Pro-Mikrofon"),
            .transcribe
        )
    }

    func testTooShortIsSaidOutLoud() {
        XCTAssertEqual(
            DictationPipeline.afterStop(duration: 0.25, minimumDuration: 0.3, peak: 0.2, device: nil),
            .refuse(.tooShort)
        )
    }

    /// Exactly 0.0 is what every capture regression has looked like.
    func testDigitalSilenceNamesTheDevice() {
        XCTAssertEqual(
            DictationPipeline.afterStop(duration: 4, minimumDuration: 0.3, peak: 0, device: "AirPods"),
            .refuse(.nothingHeard(device: "AirPods"))
        )
    }

    /// Unlike a meeting track, a short dictation is judged too: a real
    /// microphone's noise floor is there from the first buffer.
    func testSilenceIsJudgedEvenOnAShortClip() {
        XCTAssertEqual(
            DictationPipeline.afterStop(duration: 0.5, minimumDuration: 0.3, peak: 0, device: nil),
            .refuse(.nothingHeard(device: nil))
        )
    }

    /// A very quiet room is not a dead microphone.
    func testQuietButLiveSignalIsTranscribed() {
        XCTAssertEqual(
            DictationPipeline.afterStop(duration: 3, minimumDuration: 0.3, peak: 0.002, device: nil),
            .transcribe
        )
    }

    func testEmptyTranscriptIsItsOwnCase() {
        XCTAssertEqual(DictationPipeline.afterTranscript("  \n "), .nothingRecognized)
        XCTAssertNil(DictationPipeline.afterTranscript("Hallo."))
    }

    // MARK: - Paste

    func testSameAppPastes() {
        XCTAssertEqual(
            DictationPipeline.paste(target: "com.apple.mail", frontmost: "com.apple.mail",
                                    frontmostName: "Mail", secureInput: false),
            .paste
        )
    }

    func testBundleIDComparisonIgnoresCase() {
        XCTAssertEqual(
            DictationPipeline.paste(target: "com.tinyspeck.slackmacgap", frontmost: "com.tinyspeck.SlackMacGap",
                                    frontmostName: "Slack", secureInput: false),
            .paste
        )
    }

    /// ⌘Tab during transcription: the text must not go into the new window.
    func testSwitchedAppGoesToTheClipboardAndSaysWhere() {
        XCTAssertEqual(
            DictationPipeline.paste(target: "com.apple.mail", frontmost: "com.tinyspeck.slackmacgap",
                                    frontmostName: "Slack", secureInput: false),
            .clipboard(.targetChanged(app: "Slack"))
        )
    }

    func testUnknownSideIsNotAMismatch() {
        XCTAssertEqual(
            DictationPipeline.paste(target: nil, frontmost: "com.apple.mail", frontmostName: "Mail", secureInput: false),
            .paste
        )
        XCTAssertEqual(
            DictationPipeline.paste(target: "com.apple.mail", frontmost: nil, frontmostName: nil, secureInput: false),
            .paste
        )
    }

    func testSecureInputAtPasteTimeGoesToTheClipboard() {
        XCTAssertEqual(
            DictationPipeline.paste(target: "com.apple.mail", frontmost: "com.apple.mail",
                                    frontmostName: "Mail", secureInput: true),
            .clipboard(.secureInput)
        )
    }

    // MARK: - Esc

    func testEscDuringRecordingDiscardsTheRecording() {
        var jobs = JobQueue()
        jobs.enqueue(1)
        XCTAssertEqual(DictationPipeline.escapeTarget(isCapturing: true, jobs: jobs), .recording)
    }

    /// The branch the old code had but no event could reach.
    func testEscAfterReleaseAbortsTheNewestJob() {
        var jobs = JobQueue()
        jobs.enqueue(3)
        jobs.enqueue(4)
        XCTAssertEqual(DictationPipeline.escapeTarget(isCapturing: false, jobs: jobs), .job(4))
    }

    func testEscWithNothingRunningDoesNothing() {
        XCTAssertEqual(DictationPipeline.escapeTarget(isCapturing: false, jobs: JobQueue()), .none)
    }

    // MARK: - Jobs

    func testJobsKeepSpokenOrder() {
        var jobs = JobQueue()
        jobs.enqueue(1)
        jobs.enqueue(2)
        XCTAssertEqual(jobs.oldest, 1)
        XCTAssertEqual(jobs.newest, 2)
        jobs.finish(1)
        XCTAssertEqual(jobs.oldest, 2)
    }

    func testFinishingAnUnknownJobIsHarmless() {
        var jobs = JobQueue()
        jobs.enqueue(1)
        jobs.finish(9)
        XCTAssertEqual(jobs.jobs, [1])
    }

    func testEnqueueIsIdempotent() {
        var jobs = JobQueue()
        jobs.enqueue(5)
        jobs.enqueue(5)
        XCTAssertEqual(jobs.count, 1)
    }

    // MARK: - Limits

    func testMaximumIsWallClock() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertFalse(DictationPipeline.reachedMaximum(startedAt: start, now: start.addingTimeInterval(599), maximum: 600))
        XCTAssertTrue(DictationPipeline.reachedMaximum(startedAt: start, now: start.addingTimeInterval(600), maximum: 600))
    }

    func testIdleTimeoutFiresAfterSustainedSilence() {
        var idle = IdleDetector(timeout: 2)
        XCTAssertFalse(idle.observe(level: 0.01, at: 0))
        XCTAssertFalse(idle.observe(level: 0.01, at: 1.9))
        XCTAssertTrue(idle.observe(level: 0.01, at: 2.0))
    }

    /// A soft speaker between the two thresholds neither starts nor ends the
    /// silence — the old single threshold timed them out mid-sentence.
    func testIdleHysteresisBandKeepsTheState() {
        var idle = IdleDetector(timeout: 2)
        XCTAssertFalse(idle.observe(level: 0.06, at: 0))
        XCTAssertNil(idle.silentSince, "Mittelband startet keine Stille")
        XCTAssertFalse(idle.observe(level: 0.01, at: 1))
        XCTAssertFalse(idle.observe(level: 0.06, at: 2), "Mittelband beendet sie auch nicht")
        XCTAssertTrue(idle.observe(level: 0.06, at: 3))
    }

    func testClearSoundResetsTheSilence() {
        var idle = IdleDetector(timeout: 2)
        _ = idle.observe(level: 0.01, at: 0)
        XCTAssertFalse(idle.observe(level: 0.2, at: 1.5))
        XCTAssertFalse(idle.observe(level: 0.01, at: 3))
        XCTAssertTrue(idle.observe(level: 0.01, at: 5))
    }

    func testZeroTimeoutNeverFires() {
        var idle = IdleDetector(timeout: 0)
        XCTAssertFalse(idle.observe(level: 0, at: 0))
        XCTAssertFalse(idle.observe(level: 0, at: 10_000))
    }

    // MARK: - Failures

    func testEveryFailureHasATitleAndSaysSomething() {
        let all: [DictationFailure] = [
            .microphoneDenied, .microphoneRequested, .secureInput, .lidClosed, .microphoneUnavailable,
            .nothingHeard(device: "X"), .nothingHeard(device: nil), .nothingRecognized, .tooShort,
            .targetChanged(app: "Slack"), .targetChanged(app: nil), .pasteBlocked, .modelMissing,
            .transcriptionFailed, .deviceLost,
            .localModelUnavailable(reason: nil), .localModelUnavailable(reason: "aus"), .commandFailed,
        ]
        for failure in all {
            XCTAssertFalse(failure.title.isEmpty, "\(failure)")
            XCTAssertTrue(failure.message.hasPrefix(failure.title), "\(failure)")
        }
    }

    /// A working feature must not wear the warning triangle.
    func testOrdinaryOutcomesAreNoticesNotErrors() {
        XCTAssertTrue(DictationFailure.tooShort.isNotice)
        XCTAssertTrue(DictationFailure.nothingRecognized.isNotice)
        XCTAssertFalse(DictationFailure.microphoneDenied.isNotice)
        XCTAssertEqual(DictationFailure.tooShort.cue, .cancelled)
        XCTAssertEqual(DictationFailure.deviceLost.cue, .failed)
    }

    /// Spec 30 §3.5: every cue has its own file in the bundle's resources, and a
    /// system fallback that exists.
    func testEveryCueHasItsOwnSoundAndAFallback() {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Sounds")
        for cue in SoundCue.allCases {
            let bundled = resources.appendingPathComponent(cue.fileName + ".caf").path
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundled), bundled)
            let fallback = "/System/Library/Sounds/\(cue.systemSoundName).aiff"
            XCTAssertTrue(FileManager.default.fileExists(atPath: fallback), fallback)
        }
    }

    // MARK: - Lock threshold

    /// A hold between the tap threshold and the minimum duration used to lock
    /// the microphone open. It now finishes — and the too-short rule names it.
    func testBriefHoldFinishesInsteadOfLocking() {
        var machine = PTTStateMachine()
        XCTAssertEqual(machine.keyDown(at: 0), .start)
        XCTAssertEqual(machine.keyUp(at: 0.25), .finish)
        XCTAssertFalse(machine.isLocked)
    }

    func testClearTapStillLocks() {
        var machine = PTTStateMachine()
        _ = machine.keyDown(at: 0)
        XCTAssertEqual(machine.keyUp(at: 0.1), .none)
        XCTAssertTrue(machine.isLocked)
    }
}
