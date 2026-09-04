import XCTest

final class DetectionStateMachineTests: XCTestCase {
    func testRunningProcessAloneIsNotAMeeting() {
        var machine = DetectionStateMachine()
        for _ in 0..<10 {
            XCTAssertNil(machine.tick(startSignal: false, callStillActive: true))
        }
        XCTAssertFalse(machine.isActive)
    }

    func testStartRequiresDebouncedCandidatePlusMic() {
        var machine = DetectionStateMachine(startThreshold: 2, endThreshold: 3)
        XCTAssertNil(machine.tick(startSignal: true, callStillActive: true))
        XCTAssertEqual(machine.tick(startSignal: true, callStillActive: true), .started)
        XCTAssertTrue(machine.isActive)
    }

    func testBlipResetsStartDebounce() {
        var machine = DetectionStateMachine(startThreshold: 2, endThreshold: 3)
        XCTAssertNil(machine.tick(startSignal: true, callStillActive: true))
        XCTAssertNil(machine.tick(startSignal: false, callStillActive: true)) // mic blip
        XCTAssertNil(machine.tick(startSignal: true, callStillActive: true)) // count restarts
        XCTAssertEqual(machine.tick(startSignal: true, callStillActive: true), .started)
    }

    func testEndIgnoresMicAndNeedsCandidateGone() {
        var machine = DetectionStateMachine(startThreshold: 1, endThreshold: 2)
        XCTAssertEqual(machine.tick(startSignal: true, callStillActive: true), .started)

        // Mic stays active (our own recording) — no end while the app runs.
        for _ in 0..<5 {
            XCTAssertNil(machine.tick(startSignal: true, callStillActive: true))
        }

        XCTAssertNil(machine.tick(startSignal: false, callStillActive: false))
        XCTAssertEqual(machine.tick(startSignal: false, callStillActive: false), .ended)
        XCTAssertFalse(machine.isActive)
    }
}
