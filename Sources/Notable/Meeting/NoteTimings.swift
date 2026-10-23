import Foundation

/// How long a meeting took from the moment it stopped to the finished note,
/// and where that time went — written into `meta.json` and the log.
///
/// After the stop everything runs one step after the other: VAD, diarization,
/// one ASR call per segment, speaker naming, the summary. How long that takes
/// for an hour of meeting was recorded nowhere, so every idea about making it
/// faster was a guess. These are the numbers to judge one by.
///
/// Milliseconds as plain integers: they are for the archive and the log, and
/// a meeting should be comparable with the next one by eye.
struct NoteTimings: Codable, Equatable, Sendable {
    /// Length of the recording, so a processing time can be read against it.
    var audioSeconds = 0
    /// Loading the meeting's ASR model. Cold after a launch, near zero when
    /// dictation already holds Parakeet.
    var modelMs = 0
    /// VAD and diarization of both tracks, including the microphone's own
    /// diarization when the system track had no speech.
    var segmentationMs = 0
    /// One ASR call per segment group, the polish, and the cleanup after it.
    var transcriptionMs = 0
    /// The whole pipeline as the caller saw it — the three above plus
    /// whatever the hand-off to the detached task cost.
    var pipelineMs = 0
    /// Screen, voice, calendar and the model's naming round-trip.
    var namingMs = 0
    /// The summary provider's round-trip, zero when there was nothing to
    /// summarize.
    var summaryMs = 0
    /// From the stop (or, for a recovered meeting, from the start of its
    /// processing) to the note's SQLite row.
    var totalMs = 0

    /// Whatever the named steps do not account for: draining the tracks,
    /// the silence check, writing the Markdown and the row, voice profiles.
    var otherMs: Int { max(0, totalMs - pipelineMs - namingMs - summaryMs) }

    /// One line for the log and `meta.json`, e.g. "gesamt 84210 ms · audio
    /// 3720 s · pipeline 61020 ms (modell 1200, segmente 19800, asr 40010) ·
    /// namen 3100 ms · zusammenfassung 18900 ms · rest 1190 ms".
    var summary: String {
        [
            "gesamt \(totalMs) ms",
            "audio \(audioSeconds) s",
            "pipeline \(pipelineMs) ms (modell \(modelMs), segmente \(segmentationMs), asr \(transcriptionMs))",
            "namen \(namingMs) ms",
            "zusammenfassung \(summaryMs) ms",
            "rest \(otherMs) ms",
        ].joined(separator: " · ")
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    init() {}

    /// Lenient field by field, like the meta around it: a later version that
    /// adds or renames a step must not cost the older numbers.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audioSeconds = (try? container.decodeIfPresent(Int.self, forKey: .audioSeconds)) ?? 0
        modelMs = (try? container.decodeIfPresent(Int.self, forKey: .modelMs)) ?? 0
        segmentationMs = (try? container.decodeIfPresent(Int.self, forKey: .segmentationMs)) ?? 0
        transcriptionMs = (try? container.decodeIfPresent(Int.self, forKey: .transcriptionMs)) ?? 0
        pipelineMs = (try? container.decodeIfPresent(Int.self, forKey: .pipelineMs)) ?? 0
        namingMs = (try? container.decodeIfPresent(Int.self, forKey: .namingMs)) ?? 0
        summaryMs = (try? container.decodeIfPresent(Int.self, forKey: .summaryMs)) ?? 0
        totalMs = (try? container.decodeIfPresent(Int.self, forKey: .totalMs)) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case audioSeconds, modelMs, segmentationMs, transcriptionMs, pipelineMs, namingMs, summaryMs, totalMs
    }
}
