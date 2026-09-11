import Foundation

/// Stufe 1 of Spec 24: dissolve the diarizer's splinters before anyone names them.
///
/// Measured on "Interview with Payhawk" (54 min, one or two people on the far
/// side): five labels, two of them splinters — "Sprecher 4" with 5 s ("Mm-hmm.",
/// "Thanks a lot for your time today.") and "Sprecher 2" with one second ("Mm.",
/// "And"). Each is a label the reader has to resolve in their head, and one
/// nobody can name.
///
/// The embeddings that tell the clusters apart used to be thrown away in
/// `MeetingPipeline.process`; here they decide where a splinter belongs. Two
/// rules keep it on the safe side:
/// - **small** means both — under 8 s *and* under 3 % of the remote speech — so
///   a quiet but real participant in a long call is not a splinter;
/// - **two large clusters are never merged here.** A voice merged by mistake
///   cannot be separated again; only independent evidence may merge them — the
///   call's own display (`ScreenSpeakerAssignment`) or the user.
enum SpeakerClusterCleanup {
    struct Segment: Equatable, Sendable {
        var label: String
        var start: TimeInterval
        var end: TimeInterval
        var embedding: [Float]
        var quality: Float

        var duration: TimeInterval { max(0, end - start) }
    }

    static let smallSeconds: TimeInterval = 8
    static let smallShare = 0.03
    /// Cosine distance under which a splinter's segment joins the nearest large
    /// cluster; farther away it keeps its own label. A starting value, **not a
    /// measurement** — `MeetingReplayTests` (skipped unless asked for) replays
    /// archived meetings and prints the label statistics before and after.
    static let reassignDistance: Float = 0.6

    static func cleaned(_ segments: [Segment]) -> [Segment] {
        let durations = totals(segments)
        let large = largeLabels(durations)
        var result = segments
        if !large.isEmpty, large.count < durations.count {
            let centroids = largeCentroids(segments, large: large)
            for index in result.indices where !large.contains(result[index].label) {
                guard let vector = normalized(result[index].embedding),
                      let nearest = centroids
                        .map({ (label: $0.label, distance: 1 - dot($0.vector, vector)) })
                        .min(by: { $0.distance < $1.distance }),
                      nearest.distance < reassignDistance
                else { continue }
                result[index].label = nearest.label
            }
        }
        return renumbered(result)
    }

    static func totals(_ segments: [Segment]) -> [String: TimeInterval] {
        segments.reduce(into: [:]) { $0[$1.label, default: 0] += $1.duration }
    }

    /// The clusters that are not splinters.
    static func largeLabels(_ durations: [String: TimeInterval]) -> Set<String> {
        let total = durations.values.reduce(0, +)
        return Set(durations.filter { !($0.value < smallSeconds && $0.value < smallShare * total) }.keys)
    }

    /// "1", "2", … by first appearance, so the labels a reader sees count up
    /// from one again after splinters vanished.
    static func renumbered(_ segments: [Segment]) -> [Segment] {
        var mapping: [String: String] = [:]
        for segment in segments.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) where mapping[segment.label] == nil {
            mapping[segment.label] = String(mapping.count + 1)
        }
        return segments.map { segment in
            var renamed = segment
            renamed.label = mapping[segment.label] ?? segment.label
            return renamed
        }
    }

    /// For measuring the threshold on real meetings (`MeetingReplayTests`):
    /// every splinter segment's cosine distance to the nearest large cluster,
    /// `nil` where it carries no usable embedding.
    static func splinterDistances(_ segments: [Segment]) -> [(label: String, duration: TimeInterval, distance: Float?)] {
        let large = largeLabels(totals(segments))
        let centroids = largeCentroids(segments, large: large)
        return segments.filter { !large.contains($0.label) }.map { segment in
            let distance = normalized(segment.embedding).flatMap { vector in
                centroids.map { 1 - dot($0.vector, vector) }.min()
            }
            return (segment.label, segment.duration, distance)
        }
    }

    // MARK: - Vectors

    private static func largeCentroids(_ segments: [Segment], large: Set<String>) -> [(label: String, vector: [Float])] {
        large.sorted().compactMap { label in
            centroid(of: segments.filter { $0.label == label }).map { (label, $0) }
        }
    }

    /// Mean of the L2-normalised segment embeddings, weighted by quality.
    private static func centroid(of segments: [Segment]) -> [Float]? {
        var sum: [Float]?
        for segment in segments {
            guard let vector = normalized(segment.embedding) else { continue }
            if sum == nil { sum = [Float](repeating: 0, count: vector.count) }
            guard sum?.count == vector.count else { continue }
            let weight = max(segment.quality, 0.05)
            for i in vector.indices { sum?[i] += weight * vector[i] }
        }
        return sum.flatMap(normalized)
    }

    private static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty else { return nil }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return vector.map { $0 / norm }
    }

    /// Of two unit vectors; a dimension mismatch counts as opposite.
    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var sum: Float = 0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }
}
