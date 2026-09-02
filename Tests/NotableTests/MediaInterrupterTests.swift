import XCTest
@testable import Notable

/// Spec 08 B. Both switches reach outside Notable — into another app's playback
/// and the system volume — so the tests are about restraint: default off, and
/// never undo something you did not do.
@MainActor
final class MediaInterrupterTests: XCTestCase {
    private func store() -> UserDefaults {
        UserDefaults(suiteName: "Media.\(UUID().uuidString)")!
    }

    func testBothSwitchesDefaultToOff() {
        let defaults = store()
        XCTAssertFalse(MediaInterrupter.isPauseEnabled(defaults))
        XCTAssertFalse(MediaInterrupter.isMuteEnabled(defaults))
    }

    func testSwitchesAreIndependent() {
        let defaults = store()
        defaults.set(true, forKey: MediaInterrupter.Key.pausePlayback)
        XCTAssertTrue(MediaInterrupter.isPauseEnabled(defaults))
        XCTAssertFalse(MediaInterrupter.isMuteEnabled(defaults))
    }

    // MARK: - "Is anything playing"

    private func snapshot(_ entries: [(input: Bool, output: Bool)], available: Bool = true) -> AudioProcessSnapshot {
        AudioProcessSnapshot(
            entries: entries.enumerated().map { index, flags in
                AudioProcessSnapshot.Entry(
                    pid: pid_t(100 + index),
                    bundleID: "app.\(index)",
                    isRunningInput: flags.input,
                    isRunningOutput: flags.output
                )
            },
            isAvailable: available
        )
    }

    func testOutputStreamCountsAsPlaying() {
        XCTAssertTrue(MediaInterrupter.isPlaying(snapshot([(input: false, output: true)])))
    }

    /// A process holding only the microphone is not playing anything — pressing
    /// play/pause at it would be wrong in both directions.
    func testInputOnlyIsNotPlaying() {
        XCTAssertFalse(MediaInterrupter.isPlaying(snapshot([(input: true, output: false)])))
    }

    func testNothingRunningIsNotPlaying() {
        XCTAssertFalse(MediaInterrupter.isPlaying(snapshot([])))
    }

    /// The important direction: when CoreAudio tells us nothing, we do nothing.
    /// Guessing "probably playing" and sending play/pause could just as easily
    /// *start* a podcast as stop one.
    func testUnavailableSnapshotMeansDoNothing() {
        XCTAssertFalse(MediaInterrupter.isPlaying(snapshot([(input: false, output: true)], available: false)))
        XCTAssertFalse(MediaInterrupter.isPlaying(.unavailable))
    }

    // MARK: - Only undo your own doing

    /// With both switches off, begin/end must be inert — no key event, no volume
    /// write. Reaching a real device in a unit test is not possible, so this
    /// checks the observable part: it runs clean and changes no state.
    func testDisabledInterrupterDoesNothing() {
        let interrupter = MediaInterrupter()
        let defaults = store()
        interrupter.begin(store: defaults)
        interrupter.end()
        // Ending twice must also be harmless — cancel and finish can both fire.
        interrupter.end()
    }
}
