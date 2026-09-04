import AVFoundation
import XCTest
@testable import Notable

/// The system-audio tap's IO proc runs on CoreAudio's real-time thread, with a
/// deadline of one buffer period. It used to convert, lock, allocate and write
/// to disk there; overrunning that deadline drops tap buffers, and a system
/// track shorter than the wall clock mis-attributes every later speaker.
///
/// These tests pin the hand-off itself: what goes into the IO-proc entry point
/// comes out of the spool, unchanged in length and content.
final class RealtimeCaptureTests: XCTestCase {
    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    /// One buffer of a constant value, as CoreAudio would hand it over.
    private func makeBuffer(frames: AVAudioFrameCount, value: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(sourceFormat.channelCount) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) { data[frame] = value }
        }
        return buffer
    }

    private func makeSpoolURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-\(UUID().uuidString).pcm")
    }

    func testEverythingHandedToTheIOProcReachesTheSpool() throws {
        let url = makeSpoolURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let downsampler = PCMDownsampler()
        try downsampler.reset(spoolingTo: url)
        downsampler.beginRealtimeCapture(format: sourceFormat)

        // 50 × 1024 frames at 48 kHz ≈ 1.07 s → ≈ 17 067 samples at 16 kHz.
        let bufferCount = 50
        let frames: AVAudioFrameCount = 1024
        for _ in 0..<bufferCount {
            let buffer = makeBuffer(frames: frames, value: 0.5)
            downsampler.appendFromIOProc(buffer.audioBufferList)
        }

        let samples = downsampler.drain()
        let expected = Double(bufferCount) * Double(frames) * (16_000.0 / 48_000.0)
        XCTAssertEqual(Double(samples.count), expected, accuracy: expected * 0.02,
                       "die Systemspur muss so lang sein wie das, was hereinkam")
        XCTAssertEqual(downsampler.droppedBuffers, 0)

        // The signal survived the hand-off — a ring that copies the wrong bytes
        // would still produce the right *length*.
        let middle = samples[samples.count / 2]
        XCTAssertEqual(middle, 0.5, accuracy: 0.05)
    }

    /// `drain()` has to flush the ring first; anything still queued belongs to
    /// this recording, and losing the tail is exactly the silent shortening
    /// this path exists to avoid.
    func testDrainFlushesWhatIsStillInTheRing() throws {
        let url = makeSpoolURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let downsampler = PCMDownsampler()
        try downsampler.reset(spoolingTo: url)
        downsampler.beginRealtimeCapture(format: sourceFormat)

        let buffer = makeBuffer(frames: 4096, value: 0.25)
        downsampler.appendFromIOProc(buffer.audioBufferList)
        // No wait, no sleep: drain must do the waiting.
        let samples = downsampler.drain()

        XCTAssertGreaterThan(samples.count, 1000, "der letzte Puffer darf nicht verlorengehen")
    }

    /// The level meter feeds the mic watchdog and the overlay. It is written by
    /// the consumer thread now, so the question is whether that thread runs at
    /// all — a ring nobody drains reports silence for a perfectly loud meeting.
    ///
    /// Polled rather than read once: the hand-off is asynchronous by design,
    /// and the very last converted chunk can be empty (the resampler holds a
    /// few frames back), which would make a single read at the end flaky.
    func testLevelIsReportedFromTheConsumerSide() throws {
        let downsampler = PCMDownsampler()
        try downsampler.reset()
        downsampler.beginRealtimeCapture(format: sourceFormat)
        defer { downsampler.endRealtimeCapture() }

        var peak: Float = 0
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, peak <= 0.1 {
            for _ in 0..<10 {
                downsampler.appendFromIOProc(makeBuffer(frames: 1024, value: 0.4).audioBufferList)
            }
            peak = max(peak, downsampler.currentLevel)
        }
        XCTAssertGreaterThan(peak, 0.1, "der Consumer-Thread läuft nicht")
    }

    /// A buffer arriving before the ring exists (or after it is gone) must be a
    /// no-op, not a crash: the IO proc can fire either side of teardown.
    func testBuffersOutsideTheCaptureWindowAreIgnored() throws {
        let downsampler = PCMDownsampler()
        try downsampler.reset()
        let buffer = makeBuffer(frames: 512, value: 1)

        downsampler.appendFromIOProc(buffer.audioBufferList) // before begin
        downsampler.beginRealtimeCapture(format: sourceFormat)
        downsampler.endRealtimeCapture()
        downsampler.appendFromIOProc(buffer.audioBufferList) // after end

        XCTAssertTrue(downsampler.drain().isEmpty)
    }

    /// A format the slots were not allocated for is a drop, and a counted one —
    /// a silent `return` was how a channel-layout mismatch used to lose whole
    /// meetings' worth of remote audio without a trace.
    func testMismatchedLayoutIsCountedRatherThanSwallowed() throws {
        let downsampler = PCMDownsampler()
        try downsampler.reset()
        downsampler.beginRealtimeCapture(format: sourceFormat)

        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                 channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 512)!
        buffer.frameLength = 512
        downsampler.appendFromIOProc(buffer.audioBufferList)

        XCTAssertEqual(downsampler.droppedBuffers, 1, "ein verworfener Puffer muss gezählt werden")
        downsampler.endRealtimeCapture()
        XCTAssertTrue(downsampler.drain().isEmpty)
    }
}
