import XCTest
@testable import Notable

/// Spec 30 §3.7. A failed dictation must survive the task that failed it, and
/// two jobs in flight must never write over each other's audio.
final class LastClipTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LastClipTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func clip(_ failure: String = "Mikrofonzugriff fehlt.", text: String? = nil) -> LastClip {
        LastClip(
            recordedAt: Date(timeIntervalSince1970: 1_757_800_000),
            duration: 1.5,
            failure: failure,
            targetBundleID: "com.apple.mail",
            text: text
        )
    }

    private let speech: [Float] = (0 ..< 16_000).map { Float(sin(Double($0) / 20)) * 0.3 }

    func testAFailedClipComesBackWithItsAudio() throws {
        try LastClipStore.stash(speech, generation: 1, in: directory)
        try LastClipStore.keep(clip(), generation: 1, in: directory)

        XCTAssertEqual(LastClipStore.pending(in: directory), clip())
        let restored = LastClipStore.samples(in: directory)
        XCTAssertEqual(restored.count, speech.count)
        for (a, b) in zip(restored, speech) {
            XCTAssertEqual(a, b, accuracy: SpoolAudio.roundTripError * 2)
        }
    }

    func testASucceededJobLeavesNothingBehind() throws {
        try LastClipStore.stash(speech, generation: 2, in: directory)
        LastClipStore.discard(generation: 2, in: directory)

        XCTAssertNil(LastClipStore.pending(in: directory))
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(left.isEmpty, "\(left)")
    }

    /// Spec 29 lets a second recording start while the first transcribes. Each
    /// job stashes under its own name.
    func testTwoJobsInFlightKeepSeparateAudio() throws {
        let other: [Float] = Array(repeating: 0.5, count: 8_000)
        try LastClipStore.stash(speech, generation: 3, in: directory)
        try LastClipStore.stash(other, generation: 4, in: directory)

        LastClipStore.discard(generation: 4, in: directory)
        try LastClipStore.keep(clip(), generation: 3, in: directory)

        XCTAssertEqual(LastClipStore.samples(in: directory).count, speech.count)
    }

    func testTheNewestFailureReplacesTheOlderOne() throws {
        try LastClipStore.stash(speech, generation: 5, in: directory)
        try LastClipStore.keep(clip("erster"), generation: 5, in: directory)
        try LastClipStore.stash(Array(repeating: 0.1, count: 400), generation: 6, in: directory)
        try LastClipStore.keep(clip("zweiter"), generation: 6, in: directory)

        XCTAssertEqual(LastClipStore.pending(in: directory)?.failure, "zweiter")
        XCTAssertEqual(LastClipStore.samples(in: directory).count, 400)
    }

    /// A paste that failed after transcription has its text; retrying that must
    /// not depend on the audio stash having been written.
    func testTextOnlyClipIsKept() throws {
        try LastClipStore.keep(clip(text: "Hallo Welt."), generation: 7, in: directory)
        XCTAssertEqual(LastClipStore.pending(in: directory)?.text, "Hallo Welt.")
        XCTAssertTrue(LastClipStore.samples(in: directory).isEmpty)
    }

    /// Metadata for audio that does not exist would offer a retry that cannot work.
    func testNeitherAudioNorTextKeepsNothing() throws {
        try LastClipStore.keep(clip(), generation: 8, in: directory)
        XCTAssertNil(LastClipStore.pending(in: directory))
    }

    func testClearRemovesTheClip() throws {
        try LastClipStore.stash(speech, generation: 9, in: directory)
        try LastClipStore.keep(clip(), generation: 9, in: directory)
        LastClipStore.clear(in: directory)
        XCTAssertNil(LastClipStore.pending(in: directory))
    }

    func testStrayStashesAreRemovedButTheLastClipStays() throws {
        try LastClipStore.stash(speech, generation: 10, in: directory)
        try LastClipStore.keep(clip(), generation: 10, in: directory)
        try LastClipStore.stash(speech, generation: 11, in: directory)
        try LastClipStore.stash(speech, generation: 12, in: directory)

        LastClipStore.removeStrayStashes(in: directory)

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(left, ["last.i16", "last.json"])
        XCTAssertNotNil(LastClipStore.pending(in: directory))
    }

    func testMissingDirectoryIsNotAnError() {
        XCTAssertNil(LastClipStore.pending(in: directory))
        LastClipStore.removeStrayStashes(in: directory)
        LastClipStore.clear(in: directory)
    }
}
