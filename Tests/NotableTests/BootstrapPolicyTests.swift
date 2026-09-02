import XCTest
@testable import Notable

/// Spec 10. The stand-in model only ever matters on a cold cache, which makes it
/// exactly the kind of code nobody exercises by accident — so the rules are pure
/// and tested rather than discovered on someone else's first launch.
final class BootstrapPolicyTests: XCTestCase {
    private func needs(
        selected: ASREngineID = .parakeetV3,
        present: Bool,
        whisperSize: WhisperModelSize = .base,
        enabled: Bool = true
    ) -> Bool {
        BootstrapPolicy.needsBootstrap(
            selected: selected,
            selectedModelPresent: present,
            selectedWhisperSize: whisperSize,
            enabled: enabled
        )
    }

    // MARK: - Whether to bootstrap at all

    /// The warm-cache case, which is every launch after the first: nothing changes,
    /// no second model, no extra memory.
    func testPresentModelNeedsNoBootstrap() {
        XCTAssertFalse(needs(present: true))
    }

    func testMissingModelNeedsBootstrap() {
        XCTAssertTrue(needs(present: false))
    }

    func testDisabledSettingWins() {
        XCTAssertFalse(needs(present: false, enabled: false))
    }

    /// Bootstrapping Tiny with Tiny would be a loop with extra steps.
    func testTinyIsNeverBootstrappedWithItself() {
        XCTAssertFalse(needs(selected: .whisper, present: false, whisperSize: .tiny))
        XCTAssertTrue(needs(selected: .whisper, present: false, whisperSize: .largeV3))
    }

    // MARK: - Which engine transcribes

    func testSelectedWinsAsSoonAsItIsReady() {
        XCTAssertEqual(BootstrapPolicy.engine(selectedReady: true, bootstrapReady: true), .selected)
        XCTAssertEqual(BootstrapPolicy.engine(selectedReady: true, bootstrapReady: false), .selected)
    }

    func testBootstrapCarriesUntilTheSelectedModelIsReady() {
        XCTAssertEqual(BootstrapPolicy.engine(selectedReady: false, bootstrapReady: true), .bootstrap)
    }

    /// Neither ready: exactly today's behaviour — wait, and say so.
    func testNeitherReadyMeansWait() {
        XCTAssertEqual(BootstrapPolicy.engine(selectedReady: false, bootstrapReady: false), .wait)
    }

    // MARK: - When to swap

    func testSwapHappensImmediatelyWhenIdle() {
        XCTAssertEqual(BootstrapPolicy.swap(isRecording: false), .now)
    }

    /// The transcriber the audio was recorded for has to finish the job — a swap
    /// mid-recording would cost the dictation.
    func testSwapIsDeferredDuringARecording() {
        XCTAssertEqual(BootstrapPolicy.swap(isRecording: true), .deferred)
    }

    // MARK: - The stand-in itself

    /// Whisper Tiny is already a full engine here: no new model format, no new
    /// download path, and multilingual (not the `.en` variant).
    func testTheStandInIsAnEngineThatAlreadyExists() {
        XCTAssertEqual(BootstrapPolicy.bootstrapEngine, .whisper)
        XCTAssertEqual(BootstrapPolicy.bootstrapSize, .tiny)
        XCTAssertTrue(WhisperModelSize.allCases.contains(BootstrapPolicy.bootstrapSize))
        XCTAssertEqual(BootstrapPolicy.bootstrapSize.modelName, "tiny", "nicht die englisch-only Variante")
    }
}
