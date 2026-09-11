import Foundation

// Spec 24, the pure half of reading the call window: what an observation is,
// how observations become a timeline, what the roster alone settles, how the
// timeline names clusters, and how the local user's own voice checks the
// adapter. No AppKit, no Accessibility — all of it table-tested.
//
// The rule from `speaker-naming.md` holds throughout: **a wrong name is worse
// than `Sprecher n`.** Every threshold below errs towards leaving a label alone.

/// One look at the call window (§4.3): who is shown, who is highlighted.
/// Names and times only — no image is ever kept (§3).
struct ScreenObservation: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case accessibility
        case ocr
    }

    var at: Date
    var source: Source
    var roster: [String]
    /// Stufe 3; empty when the adapter cannot tell.
    var activeSpeakers: [String]
}

enum ScreenTimeline {
    struct Interval: Equatable, Sendable {
        var name: String
        var start: TimeInterval
        var end: TimeInterval
    }

    /// An observation holds until the next one, at most this long — a gap in
    /// the sampling is not evidence of anyone speaking.
    static let maxHold: TimeInterval = 2

    /// Intervals on the recording's timeline in which **exactly one** name is
    /// highlighted; none and several are not counted (§4.4).
    static func speakingIntervals(_ observations: [ScreenObservation], recordingStart: Date) -> [Interval] {
        let sorted = observations.sorted { $0.at < $1.at }
        var intervals: [Interval] = []
        for (index, observation) in sorted.enumerated() {
            guard observation.activeSpeakers.count == 1, let name = observation.activeSpeakers.first else { continue }
            let start = observation.at.timeIntervalSince(recordingStart)
            let next = index + 1 < sorted.count ? sorted[index + 1].at.timeIntervalSince(recordingStart) : .infinity
            let end = min(next, start + maxHold)
            guard end > start else { continue }
            if var last = intervals.last, last.name == name, start - last.end < 0.001 {
                last.end = end
                intervals[intervals.count - 1] = last
            } else {
                intervals.append(Interval(name: name, start: start, end: end))
            }
        }
        return intervals
    }
}

enum ScreenRoster {
    /// How call apps label the local user's own tile.
    static let selfLabels: Set<String> = ["du", "you", "ich", "me"]

    /// The local user under their own name or the app's self label ("Du",
    /// "Jonas Gehring (Du)").
    static func isSelf(_ name: String, ownerTokens: Set<String>) -> Bool {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if selfLabels.contains(lowered) { return true }
        if let open = lowered.lastIndex(of: "("), lowered.hasSuffix(")"),
           selfLabels.contains(String(lowered[lowered.index(after: open)..<lowered.index(before: lowered.endIndex)])) {
            return true
        }
        return SpeakerNameResolver.isOwnerName(name, ownerTokens: ownerTokens)
    }

    /// Everyone the call showed except the local user, first-seen order.
    static func remoteParticipants(_ observations: [ScreenObservation], ownerTokens: Set<String>) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for observation in observations {
            for raw in observation.roster {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !isSelf(name, ownerTokens: ownerTokens),
                      seen.insert(name.lowercased()).inserted else { continue }
                names.append(name)
            }
        }
        return names
    }

    /// For the diarizer: the most participants ever visible at once, minus the
    /// local user (§4.3). Ahead of the calendar, which has been empty for every
    /// meeting measured.
    static func expectedRemoteSpeakers(_ observations: [ScreenObservation]) -> Int? {
        let most = observations.map { Set($0.roster.map { $0.lowercased() }).count }.max() ?? 0
        return most > 1 ? most - 1 : nil
    }

    /// The 1:1 case needs no timeline: exactly one remote person seen over the
    /// whole meeting, and exactly one large cluster left after Stufe 1.
    static func oneToOneName(remoteParticipants: [String], largeClusters: [String]) -> (cluster: String, name: String)? {
        guard remoteParticipants.count == 1, largeClusters.count == 1 else { return nil }
        return (largeClusters[0], remoteParticipants[0])
    }
}

enum ScreenSpeakerAssignment {
    struct Segment: Equatable, Sendable {
        var cluster: String
        var start: TimeInterval
        var end: TimeInterval
    }

    struct Result: Equatable, Sendable {
        /// Cluster → name, where the screen settles it.
        var names: [String: String] = [:]
        /// Clusters the screen shows to be one person: merged into the one
        /// with more speech. Independent evidence, so here — unlike in Stufe 1 —
        /// merging is allowed.
        var merges: [String: String] = [:]
        /// A cluster holding two people is named segment by segment, and only
        /// where one name clearly covers the segment; the rest stays anonymous.
        var segmentNames: [Int: String] = [:]
    }

    static let dominantShare = 0.6
    static let minimumCoveredSeconds: TimeInterval = 10
    static let minimumCoveredShare = 0.3
    static let splitShare = 0.3
    static let segmentShare = 0.8

    /// - Parameter delay: how late the display highlights a speaker, from
    ///   `ScreenSelfCheck` — the intervals are moved back by it.
    static func assign(
        _ segments: [Segment],
        intervals: [ScreenTimeline.Interval],
        delay: TimeInterval,
        ownerTokens: Set<String>
    ) -> Result {
        // The local user is "Ich" by construction; their name is never a target.
        let usable = intervals
            .filter { !ScreenRoster.isSelf($0.name, ownerTokens: ownerTokens) }
            .map { ScreenTimeline.Interval(name: $0.name, start: $0.start - delay, end: $0.end - delay) }

        var clusterTime: [String: TimeInterval] = [:]
        var covered: [String: [String: TimeInterval]] = [:]
        var perSegment: [[String: TimeInterval]] = []
        for segment in segments {
            clusterTime[segment.cluster, default: 0] += max(0, segment.end - segment.start)
            var here: [String: TimeInterval] = [:]
            for interval in usable {
                let seconds = overlap(segment.start, segment.end, interval.start, interval.end)
                if seconds > 0 { here[interval.name, default: 0] += seconds }
            }
            perSegment.append(here)
            for (name, seconds) in here { covered[segment.cluster, default: [:]][name, default: 0] += seconds }
        }

        var result = Result()
        for (cluster, byName) in covered {
            let total = byName.values.reduce(0, +)
            guard total > 0,
                  total >= minimumCoveredSeconds || total >= minimumCoveredShare * (clusterTime[cluster] ?? 0)
            else { continue }
            let ranked = byName.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            if ranked[0].value >= dominantShare * total {
                result.names[cluster] = ranked[0].key
                continue
            }
            // Two names with a real share each: the diarizer fused two people.
            guard ranked.filter({ $0.value >= splitShare * total }).count >= 2 else { continue }
            for (index, segment) in segments.enumerated() where segment.cluster == cluster {
                let duration = segment.end - segment.start
                guard duration > 0,
                      let best = perSegment[index].max(by: { $0.value < $1.value }),
                      best.value >= segmentShare * duration
                else { continue }
                result.segmentNames[index] = best.key
            }
        }

        // Two clusters, one name: the diarizer split a person.
        var clustersByName: [String: [String]] = [:]
        for (cluster, name) in result.names { clustersByName[name, default: []].append(cluster) }
        for clusters in clustersByName.values where clusters.count > 1 {
            let ordered = clusters.sorted { ((clusterTime[$0] ?? 0), $1) > ((clusterTime[$1] ?? 0), $0) }
            for cluster in ordered.dropFirst() { result.merges[cluster] = ordered[0] }
        }
        return result
    }

    static func overlap(_ a0: TimeInterval, _ a1: TimeInterval, _ b0: TimeInterval, _ b1: TimeInterval) -> TimeInterval {
        max(0, min(a1, b1) - max(a0, b0))
    }
}

/// Does the adapter read the window right? Checked per meeting on the one
/// speaker whose truth is known: when the local user speaks (the mic track),
/// the call has to highlight **them** (§4.4). That also yields the display's
/// delay, measured instead of guessed.
enum ScreenSelfCheck {
    struct Outcome: Equatable, Sendable {
        var delay: TimeInterval
        /// Share of the user's own speech the display highlighted them for.
        var agreement: Double
    }

    static let minimumAgreement = 0.7
    static let maximumDelay: TimeInterval = 3

    static func evaluate(
        ownSpeech: [(start: TimeInterval, end: TimeInterval)],
        highlights: [ScreenTimeline.Interval],
        ownerTokens: Set<String>
    ) -> Outcome? {
        let speech = ownSpeech.filter { $0.end > $0.start }
        guard !speech.isEmpty else { return nil }
        let own = highlights.filter { ScreenRoster.isSelf($0.name, ownerTokens: ownerTokens) }

        var lags: [TimeInterval] = []
        for utterance in speech {
            if let highlight = own.first(where: {
                $0.start >= utterance.start - 0.5 && $0.start <= utterance.start + maximumDelay
            }) {
                lags.append(max(0, highlight.start - utterance.start))
            }
        }
        let delay = lags.isEmpty ? 0 : lags.reduce(0, +) / Double(lags.count)

        let total = speech.reduce(0) { $0 + ($1.end - $1.start) }
        var hit: TimeInterval = 0
        for utterance in speech {
            for highlight in own {
                hit += ScreenSpeakerAssignment.overlap(utterance.start, utterance.end,
                                                       highlight.start - delay, highlight.end - delay)
            }
        }
        return Outcome(delay: delay, agreement: min(1, hit / total))
    }

    /// Stufe 3 is applied to a meeting only when this holds — otherwise the
    /// window looks different from what the adapter expects, and the timeline is
    /// logged, not used.
    static func trusts(_ outcome: Outcome?) -> Bool {
        (outcome?.agreement ?? 0) >= minimumAgreement
    }
}

/// Stufe 2 and 3 put together for one meeting — pure, so the order of the
/// sources is tested rather than read out of `produceNote`.
enum ScreenNaming {
    struct Outcome: Sendable {
        var segments: [MeetingTranscriptSegment]
        /// Cluster → name, source `screen`.
        var names: [String: String]
        var participants: [String]
        var selfCheck: ScreenSelfCheck.Outcome?
    }

    /// 1. The timeline (Stufe 3), only if the self-check trusts the adapter for
    ///    this meeting: names, merges of a split person, segment names for two
    ///    people in one cluster.
    /// 2. Otherwise the 1:1 case (Stufe 2): one remote person, one large cluster.
    static func apply(
        _ segments: [MeetingTranscriptSegment],
        observations: [ScreenObservation],
        recordingStart: Date,
        ownerTokens: Set<String>
    ) -> Outcome {
        guard !observations.isEmpty else { return Outcome(segments: segments, names: [:], participants: [], selfCheck: nil) }
        let participants = ScreenRoster.remoteParticipants(observations, ownerTokens: ownerTokens)
        var result = segments
        var names: [String: String] = [:]
        let mic = SpeakerNameResolver.micSpeakerLabel
        let remote = result.indices.filter { result[$0].cluster.map { $0 != mic } ?? false }

        let intervals = ScreenTimeline.speakingIntervals(observations, recordingStart: recordingStart)
        let ownSpeech = result.filter { $0.cluster == mic }.map { (start: $0.start, end: $0.end) }
        let check = ScreenSelfCheck.evaluate(ownSpeech: ownSpeech, highlights: intervals, ownerTokens: ownerTokens)
        if !intervals.isEmpty, ScreenSelfCheck.trusts(check), let check {
            let assignment = ScreenSpeakerAssignment.assign(
                remote.map { ScreenSpeakerAssignment.Segment(cluster: result[$0].cluster ?? "", start: result[$0].start, end: result[$0].end) },
                intervals: intervals, delay: check.delay, ownerTokens: ownerTokens
            )
            for (position, name) in assignment.segmentNames { result[remote[position]].speaker = name }
            for index in remote {
                if let cluster = result[index].cluster, let into = assignment.merges[cluster] { result[index].cluster = into }
            }
            for (cluster, name) in assignment.names where assignment.merges[cluster] == nil { names[cluster] = name }
        }

        if names.isEmpty {
            let durations = remote.reduce(into: [String: TimeInterval]()) {
                $0[result[$1].cluster ?? "", default: 0] += result[$1].end - result[$1].start
            }
            let large = SpeakerClusterCleanup.largeLabels(durations).sorted()
            if let one = ScreenRoster.oneToOneName(remoteParticipants: participants, largeClusters: large) {
                names[one.cluster] = one.name
            }
        }

        for index in result.indices {
            if let cluster = result[index].cluster, let name = names[cluster] { result[index].speaker = name }
        }
        return Outcome(segments: result, names: names, participants: participants, selfCheck: check)
    }

    /// Remote labels still showing their minted name — what the model may try.
    static func unnamedLabels(in segments: [MeetingTranscriptSegment]) -> Set<String> {
        Set(segments.compactMap { segment in
            guard let cluster = segment.cluster, cluster != SpeakerNameResolver.micSpeakerLabel,
                  segment.speaker == cluster else { return nil }
            return cluster
        })
    }
}
