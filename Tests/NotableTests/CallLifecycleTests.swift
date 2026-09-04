import XCTest

/// Spec 09: the call *end* signal. The old detector ended a meeting when the app
/// quit, which never happens for Teams or Slack — these cover the replacement.
final class AudioProcessSnapshotTests: XCTestCase {
    private func snapshot(_ entries: [AudioProcessSnapshot.Entry]) -> AudioProcessSnapshot {
        AudioProcessSnapshot(entries: entries, isAvailable: true)
    }

    private func entry(_ bundleID: String?, pid: pid_t = 1, input: Bool, output: Bool = false)
        -> AudioProcessSnapshot.Entry {
        .init(pid: pid, bundleID: bundleID, isRunningInput: input, isRunningOutput: output)
    }

    func testMicrophoneHolderIsFound() {
        let snap = snapshot([entry("us.zoom.xos", input: true)])
        XCTAssertNotNil(snap.inputEntry(bundleID: "us.zoom.xos"))
        XCTAssertNil(snap.inputEntry(bundleID: "com.microsoft.teams2"))
    }

    func testRunningAppWithoutMicrophoneIsNotACall() {
        // Teams is open all day playing notification sounds — not a call.
        let snap = snapshot([entry("com.microsoft.teams2", input: false, output: true)])
        XCTAssertNil(snap.inputEntry(bundleID: "com.microsoft.teams2"))
        XCTAssertTrue(snap.isActive(bundleID: "com.microsoft.teams2"))
    }

    func testHelperProcessesMatchTheirApp() {
        // Chromium/Electron audio lives in helpers; exact matching would see
        // nothing at all for Chrome, Teams and Slack.
        let snap = snapshot([entry("com.google.Chrome.helper", input: true)])
        XCTAssertNotNil(snap.inputEntry(bundleID: "com.google.Chrome"))
    }

    func testSafariAudioIsFoundUnderItsWebKitProcess() {
        // Measured on macOS 15: Safari's audio runs as com.apple.WebKit.GPU,
        // which shares no prefix with com.apple.Safari.
        let snap = snapshot([entry("com.apple.WebKit.GPU", input: true)])
        XCTAssertNil(snap.inputEntry(bundleID: "com.apple.Safari"))
        XCTAssertNotNil(snap.inputEntry(anyOf: ["com.apple.Safari", "com.apple.WebKit"]))
        XCTAssertTrue(snap.isActive(anyOf: ["com.apple.Safari", "com.apple.WebKit"]))
    }

    func testUnrelatedBundleWithSharedPrefixDoesNotMatch() {
        let snap = snapshot([entry("com.google.ChromeCanary", input: true)])
        XCTAssertNil(snap.inputEntry(bundleID: "com.google.Chrome"))
    }

    func testPriorityFollowsTheGivenOrder() {
        let snap = snapshot([
            entry("com.tinyspeck.slackmacgap", pid: 2, input: true),
            entry("us.zoom.xos", pid: 3, input: true),
        ])
        XCTAssertEqual(snap.inputEntry(anyOf: ["us.zoom.xos", "com.tinyspeck.slackmacgap"])?.pid, 3)
    }

    func testUnavailableSnapshotFindsNothing() {
        // The caller must fall back to the legacy heuristic, not conclude "no call".
        XCTAssertFalse(AudioProcessSnapshot.unavailable.isAvailable)
        XCTAssertNil(AudioProcessSnapshot.unavailable.inputEntry(bundleID: "us.zoom.xos"))
    }
}

final class CallEndDetectionTests: XCTestCase {
    func testCallEndsOnlyAfterTheEndThreshold() {
        var machine = DetectionStateMachine(startThreshold: 1, endThreshold: 4)
        XCTAssertEqual(machine.tick(startSignal: true, callStillActive: true), .started)

        for _ in 0..<3 {
            XCTAssertNil(machine.tick(startSignal: false, callStillActive: false))
        }
        XCTAssertEqual(machine.tick(startSignal: false, callStillActive: false), .ended)
        XCTAssertFalse(machine.isActive)
    }

    func testMutingDoesNotEndTheCall() {
        // Start signal gone (mic released by a mute), but the call process still
        // plays the other side — that is a running meeting, not an ended one.
        var machine = DetectionStateMachine(startThreshold: 1, endThreshold: 4)
        XCTAssertEqual(machine.tick(startSignal: true, callStillActive: true), .started)
        for _ in 0..<10 {
            XCTAssertNil(machine.tick(startSignal: false, callStillActive: true))
        }
        XCTAssertTrue(machine.isActive)
    }

    func testShortGapDoesNotEndTheCall() {
        var machine = DetectionStateMachine(startThreshold: 1, endThreshold: 4)
        XCTAssertEqual(machine.tick(startSignal: true, callStillActive: true), .started)
        XCTAssertNil(machine.tick(startSignal: true, callStillActive: false))
        XCTAssertNil(machine.tick(startSignal: true, callStillActive: false))
        XCTAssertNil(machine.tick(startSignal: true, callStillActive: true)) // recovered
        for _ in 0..<3 {
            XCTAssertNil(machine.tick(startSignal: true, callStillActive: false))
        }
        XCTAssertEqual(machine.tick(startSignal: true, callStillActive: false), .ended)
    }

    func testEndedCallCanStartAgain() {
        var machine = DetectionStateMachine(startThreshold: 2, endThreshold: 2)
        XCTAssertNil(machine.tick(startSignal: true, callStillActive: true))
        XCTAssertEqual(machine.tick(startSignal: true, callStillActive: true), .started)
        XCTAssertNil(machine.tick(startSignal: false, callStillActive: false))
        XCTAssertEqual(machine.tick(startSignal: false, callStillActive: false), .ended)
        XCTAssertNil(machine.tick(startSignal: true, callStillActive: true))
        XCTAssertEqual(machine.tick(startSignal: true, callStillActive: true), .started)
    }
}

final class ConsentIdentityTests: XCTestCase {
    func testUnidentifiedBrowserCallIsNotRememberable() {
        // "Immer aufnehmen" for a bare browser would record every voice search.
        XCTAssertFalse(MeetingIdentity.isRememberable(MeetingIdentity.unknownWebKey))
        XCTAssertFalse(MeetingIdentity.isRememberable("unknown"))
    }

    func testKnownSourcesAreRememberable() {
        XCTAssertTrue(MeetingIdentity.isRememberable("us.zoom.xos"))
        XCTAssertTrue(MeetingIdentity.isRememberable("web:google-meet"))
    }
}
