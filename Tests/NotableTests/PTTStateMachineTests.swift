import XCTest

final class PTTStateMachineTests: XCTestCase {
    func testHoldAndReleaseIsClassicPTT() {
        var machine = PTTStateMachine()
        XCTAssertEqual(machine.keyDown(at: 0), .start)
        XCTAssertEqual(machine.keyUp(at: 1.2), .finish)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testShortTapLocksAndNextTapFinishes() {
        var machine = PTTStateMachine()
        XCTAssertEqual(machine.keyDown(at: 0), .start)
        XCTAssertEqual(machine.keyUp(at: 0.1), .none) // tap → locked
        XCTAssertTrue(machine.isLocked)

        XCTAssertEqual(machine.keyDown(at: 5.0), .finish)
        // The release of the stopping tap must be ignored.
        XCTAssertEqual(machine.keyUp(at: 5.1), .none)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testResetCancelsLockedRecording() {
        var machine = PTTStateMachine()
        _ = machine.keyDown(at: 0)
        _ = machine.keyUp(at: 0.1)
        XCTAssertTrue(machine.isLocked)

        machine.reset() // Esc
        XCTAssertEqual(machine.phase, .idle)
        // Next press starts a fresh recording.
        XCTAssertEqual(machine.keyDown(at: 2.0), .start)
    }

    func testKeyUpInIdleIsIgnored() {
        var machine = PTTStateMachine()
        XCTAssertEqual(machine.keyUp(at: 0), .none)
        XCTAssertEqual(machine.phase, .idle)
    }
}
