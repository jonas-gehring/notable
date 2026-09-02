import XCTest
@testable import Notable

/// Issue #1 Stufe 2. Two push-to-talk keys, one recording — and a release that
/// has to be matched to the key that actually started it. Extracted from the
/// CGEventTap callback precisely so this can be checked.
final class HotkeyRoutingTests: XCTestCase {
    private func event(
        _ spec: HotkeySpec,
        pressed: Bool,
        held: HotkeyRole? = nil,
        plain: HotkeySpec = .rightOption,
        enhance: HotkeySpec? = .rightCommand
    ) -> HotkeyRouting.Event {
        HotkeyRouting.event(
            keyCode: spec.keyCode, isPressed: pressed, held: held, plain: plain, enhance: enhance
        )
    }

    func testEachKeyReportsItsOwnRole() {
        XCTAssertEqual(event(.rightOption, pressed: true), .down(.plain))
        XCTAssertEqual(event(.rightCommand, pressed: true), .down(.enhanced))
    }

    func testUnrelatedKeyIsIgnored() {
        XCTAssertEqual(event(.fnGlobe, pressed: true), .ignore)
    }

    func testReleaseMustMatchTheKeyThatStarted() {
        XCTAssertEqual(event(.rightOption, pressed: false, held: .plain), .up(.plain))
        // The enhance key going up while the plain one is held would otherwise
        // end a recording it never started.
        XCTAssertEqual(event(.rightCommand, pressed: false, held: .plain), .ignore)
    }

    func testSecondKeyDuringARecordingIsIgnored() {
        XCTAssertEqual(event(.rightCommand, pressed: true, held: .plain), .ignore)
        XCTAssertEqual(event(.rightOption, pressed: true, held: .enhanced), .ignore)
    }

    /// One key cannot mean two things. If both settings point at the same key,
    /// the plain role wins — a silent enhancement is the wrong surprise.
    func testSameKeyForBothFallsBackToPlain() {
        XCTAssertEqual(
            event(.rightOption, pressed: true, plain: .rightOption, enhance: .rightOption),
            .down(.plain)
        )
    }

    /// No second key configured: the enhanced role is unreachable.
    func testWithoutASecondKeyNothingIsEverEnhanced() {
        for spec in HotkeySpec.allCases {
            let result = event(spec, pressed: true, plain: .rightOption, enhance: nil)
            XCTAssertNotEqual(result, .down(.enhanced), "\(spec.rawValue)")
        }
    }

    func testReleaseWithNothingHeldIsIgnored() {
        XCTAssertEqual(event(.rightOption, pressed: false, held: nil), .ignore)
    }
}
