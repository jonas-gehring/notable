import XCTest

final class DetectionStateMachineTests: XCTestCase {
    func testRunningProcessAloneIsNotAMeeting() {
        var machine = DetectionStateMachine()
        for _ in 0..<10 {
            XCTAssertNil(machine.tick(candidatePresent: true, micActive: false))
        }
        XCTAssertFalse(machine.isActive)
    }

    func testStartRequiresDebouncedCandidatePlusMic() {
        var machine = DetectionStateMachine(startThreshold: 2, endThreshold: 3)
        XCTAssertNil(machine.tick(candidatePresent: true, micActive: true))
        XCTAssertEqual(machine.tick(candidatePresent: true, micActive: true), .started)
        XCTAssertTrue(machine.isActive)
    }

    func testBlipResetsStartDebounce() {
        var machine = DetectionStateMachine(startThreshold: 2, endThreshold: 3)
        XCTAssertNil(machine.tick(candidatePresent: true, micActive: true))
        XCTAssertNil(machine.tick(candidatePresent: true, micActive: false)) // mic blip
        XCTAssertNil(machine.tick(candidatePresent: true, micActive: true)) // count restarts
        XCTAssertEqual(machine.tick(candidatePresent: true, micActive: true), .started)
    }

    func testEndIgnoresMicAndNeedsCandidateGone() {
        var machine = DetectionStateMachine(startThreshold: 1, endThreshold: 2)
        XCTAssertEqual(machine.tick(candidatePresent: true, micActive: true), .started)

        // Mic stays active (our own recording) — no end while the app runs.
        for _ in 0..<5 {
            XCTAssertNil(machine.tick(candidatePresent: true, micActive: true))
        }

        XCTAssertNil(machine.tick(candidatePresent: false, micActive: true))
        XCTAssertEqual(machine.tick(candidatePresent: false, micActive: true), .ended)
        XCTAssertFalse(machine.isActive)
    }
}
