import XCTest

/// The guard that turns a silent capture from an invisible failure into a
/// stated one. Both regressions it exists for produced *exactly* zero-valued
/// PCM for a whole meeting, so the cases here are that shape, plus the two
/// boundaries where flagging would be wrong: a too-short track, and a track
/// that is merely quiet.
final class TrackSilenceTests: XCTestCase {
    private let rate = PCMDownsampler.targetSampleRate

    private func samples(seconds: Double, amplitude: Float) -> [Float] {
        let count = Int(Double(rate) * seconds)
        return (0..<count).map { i in
            amplitude * sin(Float(i) * 0.05)
        }
    }

    /// The measured field failure: a full-length track of pure zeros.
    func testDigitalSilenceIsFlagged() {
        let track = [Float](repeating: 0, count: rate * 30)
        XCTAssertTrue(TrackSilence.isSilent(track))
        XCTAssertEqual(TrackSilence.peak(track), 0)
    }

    /// A quiet room is not a broken microphone. A noise floor three orders of
    /// magnitude above the threshold must never be reported as a fault — a
    /// false alarm here trains the user to ignore the real one.
    func testQuietButLiveTrackIsNotFlagged() {
        XCTAssertFalse(TrackSilence.isSilent(samples(seconds: 30, amplitude: 0.02)))
    }

    /// Just above the threshold still counts as signal: the threshold separates
    /// "nothing at all" from "something", not "quiet" from "loud".
    func testThresholdSeparatesNothingFromSomething() {
        let barelyThere = samples(seconds: 10, amplitude: TrackSilence.peakThreshold * 10)
        XCTAssertFalse(TrackSilence.isSilent(barelyThere))
    }

    /// A one-second recording that is silent says nothing about the device;
    /// flagging it would fire on every accidental start/stop.
    func testTooShortToJudgeIsNeverFlagged() {
        let blip = [Float](repeating: 0, count: rate)
        XCTAssertFalse(TrackSilence.isSilent(blip))
        XCTAssertFalse(TrackSilence.isSilent([]))
    }
}
