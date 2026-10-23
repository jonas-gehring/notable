import Foundation

/// Which voice on a diarized microphone track is the local user.
///
/// The mic track used to be "Ich" from end to end. That is right in a call,
/// where the other side arrives on the system track, and wrong everywhere
/// else: in a meeting in the room, or a phone on speaker, every voice comes
/// through the one microphone, and in 4 of the 16 benchmark meetings of
/// 2026-10-20 the whole conversation stood under "Ich", once with the roles
/// of the two people swapped in the summary. `MeetingPipeline` therefore
/// diarizes the microphone when the system track carried no speech at all, and
/// asks this which cluster is the user.
///
/// The answer is the loudest voice, and only by a clear margin: whoever sits
/// at the laptop is closest to its microphone. Without the margin there is no
/// "Ich" at all and every voice stays "Sprecher n". A meeting where the user
/// is a number is honest; one where somebody else speaks as "Ich" is not.
/// **`leadDecibels` is a starting value, not a measurement.**
enum OwnerVoice {
    /// How much louder (median level) the user's voice must be than the next.
    static let leadDecibels: Float = 3

    /// - Parameters:
    ///   - levels: per cluster, the level of each of its segments in dBFS.
    ///   - large: the clusters that are voices rather than splinters
    ///     (`SpeakerClusterCleanup.largeLabels`); only they can be the user.
    static func owner(levels: [String: [Float]], large: Set<String>) -> String? {
        let ranked = large
            .compactMap { label -> (label: String, level: Float)? in
                guard let values = levels[label], let level = median(values) else { return nil }
                return (label: label, level: level)
            }
            .sorted { ($0.level, $1.label) > ($1.level, $0.label) }
        guard let loudest = ranked.first else { return nil }
        guard ranked.count >= 2 else { return loudest.label }
        return loudest.level - ranked[1].level >= leadDecibels ? loudest.label : nil
    }

    /// The labels the note shows, from the diarizer's own ("1", "2", …, "?"):
    /// the user's cluster becomes "Ich", the rest count up from "Sprecher 1"
    /// again in the diarizer's order (speech share), and "?" stays
    /// "Sprecher ?".
    static func displayLabels(clusters: [String], owner: String?) -> [String: String] {
        var result: [String: String] = [:]
        var next = 1
        for cluster in clusters {
            if cluster == owner {
                result[cluster] = SpeakerNameResolver.micSpeakerLabel
            } else if cluster == SpeakerClusterCleanup.unknownLabel {
                result[cluster] = SpeakerNameResolver.unknownSpeakerLabel
            } else {
                result[cluster] = "Sprecher \(next)"
                next += 1
            }
        }
        return result
    }

    /// RMS of a stretch of samples in dBFS; very quiet is -120, not -infinity.
    static func decibels(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return -120 }
        let power = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        guard power > 1e-12 else { return -120 }
        return max(-120, 10 * log10(power))
    }

    static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
