import FluidAudio
import Foundation

struct MeetingTranscriptSegment: Sendable {
    var speaker: String?
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

/// Post-meeting processing: VAD-segment the mic track ("Ich"), diarize the
/// system track ("Sprecher n"), then transcribe each segment slice with
/// Parakeet and merge chronologically. Runs entirely on-device.
enum MeetingPipeline {
    struct SegmentSpec: Equatable, Sendable {
        enum Track: Equatable, Sendable {
            case microphone
            case system
        }
        var track: Track
        var speaker: String?
        var start: TimeInterval
        var end: TimeInterval
    }

    /// Pure merge/labeling step — unit-tested separately from the models.
    static func orderedSpecs(
        micSegments: [(start: TimeInterval, end: TimeInterval)],
        systemSegments: [(speakerID: String, start: TimeInterval, end: TimeInterval)]
    ) -> [SegmentSpec] {
        var specs: [SegmentSpec] = []
        specs.append(contentsOf: micSegments.map {
            SegmentSpec(track: .microphone, speaker: "Ich", start: $0.start, end: $0.end)
        })
        specs.append(contentsOf: systemSegments.map {
            SegmentSpec(track: .system, speaker: "Sprecher \($0.speakerID)", start: $0.start, end: $0.end)
        })
        return specs.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// How the diarizer is asked to separate the remote speakers.
    ///
    /// Three deliberate departures from the defaults, all of them about the
    /// same failure: a two-person call coming back as one speaker, or a
    /// three-person call coming back as six.
    ///
    /// - `clusteringThreshold` 0.62 instead of 0.7. The track handed to the
    ///   diarizer is already VAD-compacted, so the embeddings are computed on
    ///   speech only and sit closer together than the library's default assumes;
    ///   at 0.7 two distinct remote voices routinely merged into one label, and
    ///   a merged label is the error that cannot be repaired afterwards — a
    ///   split one at least shows up as "Sprecher 2" and "Sprecher 3" saying
    ///   compatible things.
    /// - `minSpeechDuration` 0.4 instead of 1.0, matching
    ///   `minimumSegmentDuration`: a one-second floor threw away every "Ja." and
    ///   "Genau." before they could even be attributed.
    /// - `numClusters` from the calendar when it says something. An invitation
    ///   with four people is the best prior available for how many voices are on
    ///   the far end, and it costs nothing when there is none.
    static func diarizerConfig(expectedSpeakers: Int?) -> DiarizerConfig {
        DiarizerConfig(
            clusteringThreshold: 0.62,
            minSpeechDuration: 0.4,
            minSilenceGap: 0.4,
            numClusters: expectedSpeakers ?? -1
        )
    }

    /// Segments too short to transcribe meaningfully are dropped.
    ///
    /// 0.25 s, not 0.5: at half a second the dropped slices were exactly the
    /// one-word answers — "Ja.", "Nein.", "Okay." — that a question from "Ich"
    /// is aimed at, so the transcript recorded the question and lost the reply.
    /// FluidAudio's VAD emits speech from 0.15 s, Parakeet transcribes a 0.4 s
    /// clip without complaint (dictation does it daily), and anything that comes
    /// back empty is discarded a few lines below anyway.
    static let minimumSegmentDuration: TimeInterval = 0.25

    /// Parakeet pads every call to 240 000 samples (15 s) before the encoder
    /// runs, so a 0.8 s segment costs the same as a 15 s one. A meeting is
    /// hundreds of short turns; sent one by one, almost all of that compute is
    /// spent on padding. Consecutive turns of the same speaker are therefore
    /// merged into one call — up to this length, and only across pauses short
    /// enough that the merged slice is still that speaker talking.
    static let maximumGroupDuration: TimeInterval = 14
    static let maximumGroupGap: TimeInterval = 1.5

    /// Pure and unit-tested.
    static func groupedSpecs(_ specs: [SegmentSpec]) -> [SegmentSpec] {
        var grouped: [SegmentSpec] = []
        for spec in specs {
            guard var last = grouped.last,
                  last.track == spec.track,
                  last.speaker == spec.speaker,
                  spec.start - last.end <= maximumGroupGap,
                  spec.end - last.start <= maximumGroupDuration
            else {
                grouped.append(spec)
                continue
            }
            last.end = spec.end
            grouped[grouped.count - 1] = last
        }
        return grouped
    }

    /// One stretch of speech, in the compacted signal and in the original one.
    struct SpeechRegion: Equatable, Sendable {
        var compactStart: TimeInterval
        var originalStart: TimeInterval
        var duration: TimeInterval

        var compactEnd: TimeInterval { compactStart + duration }
    }

    /// Silence between the compacted stretches. Enough for the segmenter to
    /// see a boundary, small enough not to dilute the embeddings again.
    static let compactionPadding: TimeInterval = 0.3

    /// Maps a diarized segment from the compacted timeline back onto the
    /// original one. A segment may span several stretches (the compaction
    /// glued them together), so this can return more than one interval; the
    /// padding between stretches belongs to no speaker and is dropped.
    static func mapToOriginal(
        start: TimeInterval,
        end: TimeInterval,
        regions: [SpeechRegion]
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        regions.compactMap { region in
            let from = max(start, region.compactStart)
            let to = min(end, region.compactEnd)
            guard to > from else { return nil }
            let shift = region.originalStart - region.compactStart
            return (from + shift, to + shift)
        }
    }

    /// - Parameter expectedSpeakers: how many voices the *remote* side is
    ///   expected to have — the calendar's invitee count minus the local user.
    ///   `nil` means "let the diarizer decide", which is what a call with no
    ///   calendar event gets. It is a prior, not a promise: someone who never
    ///   speaks costs nothing, and an uninvited joiner still gets a label.
    static func process(
        micSamples: [Float],
        systemSamples: [Float],
        transcriber: any TranscriptionEngine,
        expectedSpeakers: Int? = nil
    ) async throws -> [MeetingTranscriptSegment] {
        let sampleRate = PCMDownsampler.targetSampleRate

        // One VAD manager for both tracks — it was being loaded twice.
        let vad = (micSamples.isEmpty && systemSamples.isEmpty) ? nil : try await VadManager()

        // Mic track → utterances of "Ich".
        var micSegments: [(TimeInterval, TimeInterval)] = []
        if !micSamples.isEmpty, let vad {
            micSegments = try await vad.segmentSpeech(micSamples).map { ($0.startTime, $0.endTime) }
        }

        // System track → diarized speakers.
        //
        // The track is mostly silence: it holds nothing while *I* speak. Handing
        // that to the diarizer destroys it — measured on identical audio, the
        // silence holes alone collapse a British male and an American female
        // into a single speaker, while the compacted signal separates them
        // cleanly. So VAD first, diarize speech only, then map back.
        var systemSegments: [(String, TimeInterval, TimeInterval)] = []
        if !systemSamples.isEmpty, let vad {
            let speech = try await vad.segmentSpeech(systemSamples)

            var compact: [Float] = []
            var regions: [SpeechRegion] = []
            let padding = [Float](repeating: 0, count: Int(compactionPadding * Double(sampleRate)))
            // Growing this by += reallocates repeatedly, transiently holding 2×.
            compact.reserveCapacity(speech.reduce(0) {
                $0 + Int(($1.endTime - $1.startTime + compactionPadding) * Double(sampleRate))
            })
            for segment in speech {
                let from = max(0, min(Int(segment.startTime * Double(sampleRate)), systemSamples.count))
                let to = max(from, min(Int(segment.endTime * Double(sampleRate)), systemSamples.count))
                guard to > from else { continue }
                if !compact.isEmpty { compact += padding }
                regions.append(SpeechRegion(
                    compactStart: Double(compact.count) / Double(sampleRate),
                    originalStart: segment.startTime,
                    duration: Double(to - from) / Double(sampleRate)
                ))
                compact += systemSamples[from..<to]
            }

            if !compact.isEmpty {
                let models = try await DiarizerModels.downloadIfNeeded()
                let diarizer = DiarizerManager(config: Self.diarizerConfig(expectedSpeakers: expectedSpeakers))
                diarizer.initialize(models: models)
                defer { diarizer.cleanup() }
                let result = try diarizer.performCompleteDiarization(compact, sampleRate: sampleRate)
                systemSegments = result.segments.flatMap { segment in
                    mapToOriginal(
                        start: TimeInterval(segment.startTimeSeconds),
                        end: TimeInterval(segment.endTimeSeconds),
                        regions: regions
                    ).map { (segment.speakerId, $0.start, $0.end) }
                }
            }
        }

        let specs = groupedSpecs(orderedSpecs(micSegments: micSegments, systemSegments: systemSegments))

        var transcript: [MeetingTranscriptSegment] = []
        for spec in specs where spec.end - spec.start >= minimumSegmentDuration {
            let source = spec.track == .microphone ? micSamples : systemSamples
            let startIndex = max(0, min(Int(spec.start * Double(sampleRate)), source.count))
            let endIndex = max(startIndex, min(Int(spec.end * Double(sampleRate)), source.count))
            guard endIndex > startIndex else { continue }

            let raw = try await transcriber.transcribe(
                samples: Array(source[startIndex..<endIndex]),
                sampleRate: sampleRate
            )
            let text = TextPolisher.polish(raw, options: .fromDefaults())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            transcript.append(MeetingTranscriptSegment(
                speaker: spec.speaker,
                start: spec.start,
                end: spec.end,
                text: text
            ))
        }
        return transcript
    }
}
