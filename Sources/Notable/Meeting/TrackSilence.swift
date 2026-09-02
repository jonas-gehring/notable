import Foundation

/// Did a captured track actually carry audio?
///
/// Every meeting-capture regression so far has taken exactly this shape, and
/// none of them announced itself: VPIO gating the input graph (2026-07) and a
/// hardened-runtime build shipped without the microphone entitlement
/// (2026-08, denied by tccd with no prompt) both produced PCM measuring a clean
/// **0.0 peak for the whole call** while the app reported a successful
/// recording. The 2026-08 case ran for two weeks — the notes looked plausible
/// because the *other* side was still being captured, so nothing looked wrong
/// until the transcripts were read closely: with only the remote track left,
/// diarization sees one cluster and the speaker naming hands it whichever name
/// is spoken — the local user's own.
///
/// Silence is therefore not an edge case in this pipeline, it is the failure
/// mode, and it has to be *said out loud*: `MeetingController` watches the mic
/// level while recording, and `produceNote` checks both tracks before writing.
enum TrackSilence {
    /// Peak amplitude at or below this counts as digital silence. A working
    /// capture — even a muted room, even a mic nobody speaks into — carries a
    /// noise floor orders of magnitude above this; the measured failures were
    /// exactly 0.0, so the threshold only has to separate "no signal at all"
    /// from "quiet", never "quiet" from "loud".
    static let peakThreshold: Float = 1e-4

    /// Below this length a track says nothing about whether the device works
    /// (a two-second recording can legitimately be silent), so it is never
    /// flagged.
    static let minimumSeconds: Double = 3

    /// True when the track is long enough to judge and carries no signal.
    static func isSilent(
        _ samples: [Float],
        sampleRate: Int = PCMDownsampler.targetSampleRate
    ) -> Bool {
        guard sampleRate > 0 else { return false }
        guard Double(samples.count) / Double(sampleRate) >= minimumSeconds else { return false }
        return peak(samples) <= peakThreshold
    }

    /// Largest absolute sample value.
    static func peak(_ samples: [Float]) -> Float {
        var highest: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > highest { highest = magnitude }
        }
        return highest
    }
}
