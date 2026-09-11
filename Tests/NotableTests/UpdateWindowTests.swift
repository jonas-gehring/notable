import XCTest

/// Spec 25: when an update may replace the running app, and what it leaves
/// behind. Every row of the table in §3.1.
final class UpdateWindowTests: XCTestCase {
    private func decide(_ change: (inout UpdateWindow.Inputs) -> Void) -> UpdateWindow.Decision {
        var inputs = UpdateWindow.Inputs()
        change(&inputs)
        return UpdateWindow.decide(inputs)
    }

    // MARK: - Hard locks: nothing overrides them

    func testEveryHardLockWaitsEvenWhenNobodyIsThere() {
        let unattended: (inout UpdateWindow.Inputs) -> Void = {
            $0.windowVisible = false
            $0.idleSeconds = 3600
            $0.screenLocked = true
        }
        XCTAssertEqual(decide { unattended(&$0); $0.isRecording = true }, .wait(.recording))
        XCTAssertEqual(decide { unattended(&$0); $0.processingNotes = 1 }, .wait(.processing))
        XCTAssertEqual(decide { unattended(&$0); $0.dictationBusy = true }, .wait(.dictation))
        XCTAssertEqual(decide { unattended(&$0); $0.draftOpen = true }, .wait(.draft))
    }

    func testNoHardLockWhenIdle() {
        XCTAssertNil(UpdateWindow.hardLock(UpdateWindow.Inputs(windowVisible: true)))
    }

    // MARK: - Attention

    func testNoWindowInstallsNow() {
        XCTAssertEqual(decide { $0.windowVisible = false }, .installNow)
    }

    func testAnOpenWindowWaitsWhileSomeoneIsWorking() {
        XCTAssertEqual(decide { $0.windowVisible = true; $0.idleSeconds = 599 }, .wait(.windowsInUse))
    }

    func testTenMinutesIdleInstallsDespiteOpenWindows() {
        XCTAssertEqual(decide { $0.windowVisible = true; $0.idleSeconds = 600 }, .installNow)
    }

    func testALockedScreenInstallsDespiteOpenWindows() {
        XCTAssertEqual(decide { $0.windowVisible = true; $0.screenLocked = true }, .installNow)
    }

    // MARK: - The 72-hour nudge

    func testNudgeOnlyAfterThreeDaysOfOpenWindows() {
        let start = Date(timeIntervalSince1970: 0)
        let later = start.addingTimeInterval(UpdateWindow.nudgeAfter)
        XCTAssertTrue(UpdateWindow.shouldNudge(waitingSince: start, now: later, reason: .windowsInUse, alreadyNudged: false))
        XCTAssertFalse(UpdateWindow.shouldNudge(waitingSince: start, now: later.addingTimeInterval(-1),
                                                reason: .windowsInUse, alreadyNudged: false))
        XCTAssertFalse(UpdateWindow.shouldNudge(waitingSince: start, now: later, reason: .windowsInUse, alreadyNudged: true))
    }

    func testAHardLockNeverNudges() {
        let start = Date(timeIntervalSince1970: 0)
        let much = start.addingTimeInterval(UpdateWindow.nudgeAfter * 10)
        for reason in [UpdateWindow.Reason.recording, .processing, .dictation, .draft] {
            XCTAssertFalse(UpdateWindow.shouldNudge(waitingSince: start, now: much, reason: reason, alreadyNudged: false))
        }
    }
}

final class UpdateMarkersTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "notable-update-markers-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func recordAttempt(unattended: Bool = true, windows: [String] = []) {
        UpdateMarkers.recordBeforeQuit(from: "1.1.1", to: "1.2.0", notes: "- Neu", unattended: unattended,
                                       windows: windows, defaults: defaults, now: Date(timeIntervalSince1970: 1000))
    }

    func testASuccessfulUpdateIsSaidOnceAndRemembered() {
        recordAttempt()
        XCTAssertEqual(UpdateMarkers.consumeOutcome(running: "1.2.0", defaults: defaults), .installed(from: "1.1.1", to: "1.2.0"))
        XCTAssertNil(UpdateMarkers.consumeOutcome(running: "1.2.0", defaults: defaults), "nur einmal melden")
        XCTAssertEqual(UpdateMarkers.lastUpdate(defaults: defaults),
                       UpdateMarkers.Record(version: "1.2.0", at: Date(timeIntervalSince1970: 1000), unattended: true, notes: "- Neu"))
    }

    /// The script relaunched the old bundle: that is a failure, and "zuletzt
    /// aktualisiert" must not claim otherwise.
    func testTheSameVersionAfterTheSwapIsAFailure() {
        recordAttempt()
        XCTAssertEqual(UpdateMarkers.consumeOutcome(running: "1.1.1", defaults: defaults), .failed(target: "1.2.0", running: "1.1.1"))
        XCTAssertNil(UpdateMarkers.lastUpdate(defaults: defaults))
    }

    func testNothingToSayWithoutAnAttempt() {
        XCTAssertNil(UpdateMarkers.consumeOutcome(running: "1.2.0", defaults: defaults))
    }

    func testWindowsAreRestoredOnce() {
        recordAttempt(windows: ["notes", "stats"])
        XCTAssertEqual(UpdateMarkers.consumeRestoreWindows(defaults: defaults), ["notes", "stats"])
        XCTAssertEqual(UpdateMarkers.consumeRestoreWindows(defaults: defaults), [])
    }

    func testTheWaitingClockStartsOncePerVersion() {
        let first = UpdateMarkers.waitingSince("v1.2.0", defaults: defaults, now: Date(timeIntervalSince1970: 10))
        let again = UpdateMarkers.waitingSince("v1.2.0", defaults: defaults, now: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(first, again)
        let next = UpdateMarkers.waitingSince("v1.3.0", defaults: defaults, now: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(next, Date(timeIntervalSince1970: 99))
    }
}
