import FluidAudio
import Foundation

struct MeetingTranscriptSegment: Sendable {
    var speaker: String?
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    /// The label the pipeline minted ("Ich", "Sprecher 3"), kept when a name
    /// replaces `speaker` (Spec 24). Without it nobody could tell, after a
    /// rename, which segments belong together.
    var cluster: String? = nil
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
    ///   - cleanup: the steps after the speech recognition. All of them by
    ///     default; `EchoBleedTests` switches them off to show what they repair.
    static func process(
        micSamples: [Float],
        systemSamples: [Float],
        transcriber: any TranscriptionEngine,
        expectedSpeakers: Int? = nil,
        cleanup: Cleanup = .all
    ) async throws -> [MeetingTranscriptSegment] {
        try await processDetailed(
            micSamples: micSamples, systemSamples: systemSamples,
            transcriber: transcriber, expectedSpeakers: expectedSpeakers,
            cleanup: cleanup
        ).segments
    }

    /// What the pipeline repairs after the speech recognition (benchmark of
    /// 2026-10-20, see `EchoFilter`, `MeetingLanguageGuard`, `OwnerVoice`).
    struct Cleanup: OptionSet, Sendable {
        let rawValue: Int
        /// The far side's words, heard a second time through the microphone.
        static let echo = Cleanup(rawValue: 1 << 0)
        /// Short English strays in a German meeting.
        static let language = Cleanup(rawValue: 1 << 1)
        /// Several voices on the microphone and none on the system track.
        static let microphoneVoices = Cleanup(rawValue: 1 << 2)

        static let all: Cleanup = [.echo, .language, .microphoneVoices]
    }

    /// What one meeting's audio became — and what its voices sounded like.
    ///
    /// The centroids used to die with the diarization (Spec 24 §1.2 noted the
    /// embeddings being thrown away; Stufe 1 rescued them only for the length
    /// of the cleanup). Spec 36 needs them one step further out: a profile is
    /// the centroid of a large cluster, and it has to survive the pipeline to
    /// be stored. `process` stays as the shell for every caller that only wants
    /// the transcript — the same arrangement as `resolve`/`resolveDetailed`.
    struct Outcome: Sendable {
        var segments: [MeetingTranscriptSegment]
        /// Displayed cluster label ("Sprecher 1") → centroid. `"Sprecher ?"` is
        /// not in here: it may be several people, so its mean is nobody.
        var voices: [String: [Float]] = [:]
        /// Speech seconds per cluster, so a caller can tell a large cluster
        /// from a splinter without walking the transcript again.
        var seconds: [String: TimeInterval] = [:]
        /// What the cleanup did, for the log and `meta.json`, so a note that
        /// lost a sentence can say why.
        var report = CleanupReport()
    }

    struct CleanupReport: Equatable, Sendable {
        var echoSentences = 0
        var echoWords = 0
        var language: String?
        var languageDropped = 0
        var languageDroppedWords = 0
        var languageRewritten = 0
        /// The microphone was split into voices (no speech on the system track).
        var microphoneVoices = false
        /// …and one of them was loud enough to be "Ich".
        var ownerFound = false

        /// One line for the log and `meta.json`, e.g. "echo 41 Sätze/512 Wörter ·
        /// german: 3 verworfen, 7 umgeschrieben · mikrofon: mehrere Stimmen, Ich erkannt".
        var summary: String {
            var parts = ["echo \(echoSentences) Sätze/\(echoWords) Wörter"]
            parts.append("\(language ?? "sprache?"): \(languageDropped) verworfen, \(languageRewritten) umgeschrieben")
            if microphoneVoices {
                parts.append(ownerFound ? "mikrofon: mehrere Stimmen, Ich erkannt" : "mikrofon: mehrere Stimmen, Ich nicht erkannt")
            }
            return parts.joined(separator: " · ")
        }
    }

    static func processDetailed(
        micSamples: [Float],
        systemSamples: [Float],
        transcriber: any TranscriptionEngine,
        expectedSpeakers: Int? = nil,
        cleanup: Cleanup = .all
    ) async throws -> Outcome {
        let sampleRate = PCMDownsampler.targetSampleRate

        // One VAD manager for both tracks — it was being loaded twice.
        let vad = (micSamples.isEmpty && systemSamples.isEmpty) ? nil : try await VadManager(modelDirectory: ModelInventory.applicationRoot)

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
        var voices: [String: [Float]] = [:]
        var seconds: [String: TimeInterval] = [:]
        if !systemSamples.isEmpty, let vad {
            let diarized = try await diarizeTrack(systemSamples, vad: vad, expectedSpeakers: expectedSpeakers)
            systemSegments = diarized.cleaned.flatMap { segment in
                mapToOriginal(start: segment.start, end: segment.end, regions: diarized.regions)
                    .map { (segment.label, $0.start, $0.end) }
            }
            // Under the label the note shows, not the diarizer's bare number.
            for (label, vector) in SpeakerClusterCleanup.centroids(of: diarized.cleaned) {
                voices["Sprecher \(label)"] = vector
            }
            for (label, total) in SpeakerClusterCleanup.totals(diarized.cleaned) {
                seconds["Sprecher \(label)"] = total
            }
        }

        var specs = orderedSpecs(micSegments: micSegments, systemSegments: systemSegments)
        var report = CleanupReport()

        // No speech on the system track means nobody was on the far end of a
        // call, so every voice of the meeting came through the microphone (a
        // meeting in the room, a phone on speaker). The mic track is then
        // diarized like the system track, and `OwnerVoice` decides which voice
        // is "Ich". With a single voice nothing changes. Expected voices: the
        // remote ones the calendar suggests, plus the user.
        if systemSegments.isEmpty, !micSegments.isEmpty, cleanup.contains(.microphoneVoices), let vad {
            let diarized = try await diarizeTrack(micSamples, vad: vad, expectedSpeakers: expectedSpeakers.map { $0 + 1 })
            if let split = microphoneVoices(diarized, samples: micSamples) {
                specs = split.specs.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
                seconds = split.seconds
                report.microphoneVoices = true
                report.ownerFound = split.ownerFound
            }
        }
        specs = groupedSpecs(specs)

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
                text: text,
                cluster: spec.speaker
            ))
        }

        // Echo first: the language of the meeting is better counted without the
        // second copy of the other side.
        if cleanup.contains(.echo), !systemSegments.isEmpty {
            let filtered = EchoFilter.filtered(transcript)
            transcript = filtered.segments
            report.echoSentences = filtered.removedSentences
            report.echoWords = filtered.removedWords
        }
        if cleanup.contains(.language) {
            let guarded = MeetingLanguageGuard.guarded(transcript)
            transcript = guarded.segments
            report.language = guarded.language?.rawValue
            report.languageDropped = guarded.dropped
            report.languageDroppedWords = guarded.droppedWords
            report.languageRewritten = guarded.rewritten
        }
        return Outcome(segments: transcript, voices: voices, seconds: seconds, report: report)
    }

    /// The microphone track split into voices, or nil when it holds fewer
    /// than two, which leaves it "Ich" from end to end as before.
    struct MicrophoneVoices: Sendable {
        var specs: [SegmentSpec]
        /// Speech seconds under the displayed label, "Ich" left out: the
        /// same shape as the system track's, which never contains "Ich".
        var seconds: [String: TimeInterval]
        var ownerFound: Bool
    }

    /// No centroids come out of here, on purpose: a room microphone and a
    /// call's codec are two different recordings of the same voice, and
    /// nobody has measured whether a voice profile (Spec 36) carries over
    /// between them. A profile that does not is a confident wrong name.
    static func microphoneVoices(_ diarized: Diarization, samples: [Float]) -> MicrophoneVoices? {
        let totals = SpeakerClusterCleanup.totals(diarized.cleaned)
        let large = SpeakerClusterCleanup.largeLabels(totals).subtracting([SpeakerClusterCleanup.unknownLabel])
        guard large.count >= 2 else { return nil }

        let sampleRate = Double(PCMDownsampler.targetSampleRate)
        var levels: [String: [Float]] = [:]
        var intervals: [(cluster: String, start: TimeInterval, end: TimeInterval)] = []
        for segment in diarized.cleaned {
            for interval in mapToOriginal(start: segment.start, end: segment.end, regions: diarized.regions) {
                intervals.append((cluster: segment.label, start: interval.start, end: interval.end))
                let from = max(0, min(Int(interval.start * sampleRate), samples.count))
                let to = max(from, min(Int(interval.end * sampleRate), samples.count))
                guard to > from else { continue }
                levels[segment.label, default: []].append(OwnerVoice.decibels(samples[from..<to]))
            }
        }
        let owner = OwnerVoice.owner(levels: levels, large: large)
        // The diarizer's labels count up by speech share ("1", "2", …); "?" last.
        let clusters = totals.keys.sorted { lhs, rhs in
            (Int(lhs) ?? .max, lhs) < (Int(rhs) ?? .max, rhs)
        }
        let labels = OwnerVoice.displayLabels(clusters: clusters, owner: owner)

        var seconds: [String: TimeInterval] = [:]
        for (cluster, total) in totals where cluster != owner {
            seconds[labels[cluster] ?? "Sprecher \(cluster)", default: 0] += total
        }
        let specs = intervals.map {
            SegmentSpec(track: .microphone, speaker: labels[$0.cluster] ?? "Sprecher \($0.cluster)", start: $0.start, end: $0.end)
        }
        return MicrophoneVoices(specs: specs, seconds: seconds, ownerFound: owner != nil)
    }

    /// One track's diarization: before and after the splinter cleanup, on the
    /// compacted timeline, with the regions to map it back.
    struct Diarization: Sendable {
        var raw: [SpeakerClusterCleanup.Segment]
        var cleaned: [SpeakerClusterCleanup.Segment]
        var regions: [SpeechRegion]
    }

    /// A track, VAD-compacted, diarized, and cleaned of splinters (Spec 24,
    /// Stufe 1). The system track always; the microphone when the system track
    /// had no speech. Split out so `MeetingReplayTests` can print the label
    /// statistics before and after the cleanup on archived meetings.
    ///
    /// The system track is mostly silence: it holds nothing while *I* speak.
    /// Handing that to the diarizer destroys it — measured on identical audio,
    /// the silence holes alone collapse a British male and an American female
    /// into a single speaker, while the compacted signal separates them
    /// cleanly. So VAD first, diarize speech only, then map back.
    static func diarizeTrack(
        _ samples: [Float],
        vad: VadManager,
        expectedSpeakers: Int?
    ) async throws -> Diarization {
        let sampleRate = PCMDownsampler.targetSampleRate
        let speech = try await vad.segmentSpeech(samples)

        var compact: [Float] = []
        var regions: [SpeechRegion] = []
        let padding = [Float](repeating: 0, count: Int(compactionPadding * Double(sampleRate)))
        // Growing this by += reallocates repeatedly, transiently holding 2×.
        compact.reserveCapacity(speech.reduce(0) {
            $0 + Int(($1.endTime - $1.startTime + compactionPadding) * Double(sampleRate))
        })
        for segment in speech {
            let from = max(0, min(Int(segment.startTime * Double(sampleRate)), samples.count))
            let to = max(from, min(Int(segment.endTime * Double(sampleRate)), samples.count))
            guard to > from else { continue }
            if !compact.isEmpty { compact += padding }
            regions.append(SpeechRegion(
                compactStart: Double(compact.count) / Double(sampleRate),
                originalStart: segment.startTime,
                duration: Double(to - from) / Double(sampleRate)
            ))
            compact += samples[from..<to]
        }
        guard !compact.isEmpty else { return Diarization(raw: [], cleaned: [], regions: regions) }

        let models = try await DiarizerModels.downloadIfNeeded(to: ModelInventory.directory(.diarizer))
        let diarizer = DiarizerManager(config: Self.diarizerConfig(expectedSpeakers: expectedSpeakers))
        diarizer.initialize(models: models)
        defer { diarizer.cleanup() }
        let result = try diarizer.performCompleteDiarization(compact, sampleRate: sampleRate)
        // The embeddings used to be dropped right here; the cleanup needs them.
        let raw = result.segments.map {
            SpeakerClusterCleanup.Segment(
                label: $0.speakerId,
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds),
                embedding: $0.embedding,
                quality: $0.qualityScore
            )
        }
        return Diarization(raw: raw, cleaned: SpeakerClusterCleanup.cleaned(raw), regions: regions)
    }
}
