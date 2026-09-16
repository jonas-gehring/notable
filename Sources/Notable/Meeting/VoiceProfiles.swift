import Foundation

/// Recognising a voice **across** meetings (Spec 36, Stufe 3) — the pure half:
/// what a profile is, how a meeting's cluster is matched against one, and what a
/// correction does to it.
///
/// Spec 24 §8.2 put voice profiles aside because the call window was going to
/// deliver the names in every call. Five weeks later `CallScreenAdapters.all` is
/// still empty and 1 of 23 remote labels carried a name (Spec 35 §1), so the
/// second source is built after all — under the same rule as everything else
/// here: **a wrong name is worse than `Sprecher n`.**
///
/// Three locks, and all three have to hold before a name is applied:
/// 1. the nearest profile is nearer than ``matchDistance``;
/// 2. **no second profile** is within ``matchDistance`` + ``ambiguityMargin`` —
///    two candidates that close is a coin toss, and Spec 24 §9.2 decided coin
///    tosses stay numbered;
/// 3. the name is not already on another cluster of the same meeting.
///
/// `"Ich"` and `"Sprecher ?"` never take part: the first is the local user by
/// construction, the second may be several people.
enum VoiceProfiles {
    /// One remembered voice.
    ///
    /// **`sum` is the accumulated sum of per-meeting unit centroids, not their
    /// mean.** That is what makes a correction reversible: with the sum and the
    /// meeting count, removing one meeting's contribution is a subtraction, and
    /// exact. A stored mean would have lost the divisor and a retraction could
    /// only ever be approximated.
    struct Profile: Sendable, Equatable, Identifiable {
        /// The normalised name — one profile per person, not one per naming.
        var id: String
        /// The name as it is written in the notes.
        var name: String
        var sum: [Float]
        var meetings: Int
        var createdAt: Date
        var updatedAt: Date

        /// What a comparison uses: the sum, normalised to unit length.
        var vector: [Float]? { SpeakerClusterCleanup.normalized(sum) }
    }

    /// One large cluster of the meeting being named.
    struct Candidate: Sendable, Equatable {
        var cluster: String
        var centroid: [Float]
    }

    struct Match: Sendable, Equatable {
        var cluster: String
        var name: String
        var profileID: String
        var distance: Float
    }

    /// Cosine distance under which a cluster is the same voice as a profile.
    ///
    /// **A starting value, not a measurement** — deliberately tight. §3.4 is the
    /// measurement: `MeetingReplayTests` (with `Tests/Fixtures/voices.csv`)
    /// prints the distance distribution for the same person and for different
    /// people across archived meetings, and the threshold becomes the measured
    /// one with a safety margin. Until then the error that costs nothing is
    /// preferred: a missed match leaves "Sprecher 1", a false match writes
    /// someone else's name onto a colleague.
    ///
    /// For orientation, and no more than that: Spec 24 §9.1 measured 0.58–1.04
    /// for *splinter segments* against a large cluster inside one meeting, where
    /// 1.0 is orthogonal — those are the distances of speech that carries no
    /// usable embedding at all. A centroid of a large cluster is a much stronger
    /// signal, so the same voice is expected far below that; how far is exactly
    /// what has not been measured.
    static let matchDistance: Float = 0.35
    /// A second profile this close behind the first makes it a coin toss.
    static let ambiguityMargin: Float = 0.1

    /// The key one person's profile lives under: case- and spacing-insensitive,
    /// so "anna weber" and "Anna  Weber" are one voice rather than two.
    static func identifier(for name: String) -> String {
        name
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Cosine distance of two vectors of any length; unusable input is
    /// "as far away as possible", never a lucky zero.
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard let left = SpeakerClusterCleanup.normalized(a),
              let right = SpeakerClusterCleanup.normalized(b) else { return 2 }
        return 1 - SpeakerClusterCleanup.dot(left, right)
    }

    /// Which clusters may take a profile's name.
    ///
    /// - Parameters:
    ///   - clusters: the meeting's **large** remote clusters and their centroids;
    ///     the caller has already dropped `"Ich"`, `"Sprecher ?"` and splinters,
    ///     and everything another source has already named.
    ///   - taken: names this meeting has handed out already (screen, calendar).
    ///
    /// Assignment goes by distance, closest first, so with two clusters near one
    /// profile the better match takes the name and the other one keeps its
    /// number — rather than the first one in the dictionary's order winning.
    static func assign(
        _ clusters: [Candidate],
        profiles: [Profile],
        taken: Set<String> = [],
        threshold: Float = matchDistance,
        margin: Float = ambiguityMargin
    ) -> [Match] {
        let usable = profiles.compactMap { profile -> (profile: Profile, vector: [Float])? in
            profile.vector.map { (profile, $0) }
        }
        guard !usable.isEmpty else { return [] }

        var proposals: [Match] = []
        for candidate in clusters {
            guard let vector = SpeakerClusterCleanup.normalized(candidate.centroid) else { continue }
            let ranked = usable
                .map { (profile: $0.profile, distance: 1 - SpeakerClusterCleanup.dot($0.vector, vector)) }
                .sorted { ($0.distance, $0.profile.id) < ($1.distance, $1.profile.id) }
            guard let best = ranked.first, best.distance < threshold else { continue }
            // Two profiles this close together: which of the two people it is
            // cannot be decided from the voice, so it is not decided at all.
            if ranked.count > 1, ranked[1].distance < threshold + margin { continue }
            proposals.append(Match(cluster: candidate.cluster, name: best.profile.name,
                                   profileID: best.profile.id, distance: best.distance))
        }

        var usedNames = Set(taken.map { identifier(for: $0) })
        var result: [Match] = []
        for match in proposals.sorted(by: { ($0.distance, $0.cluster) < ($1.distance, $1.cluster) }) {
            guard usedNames.insert(match.profileID).inserted else { continue }
            result.append(match)
        }
        return result
    }

    // MARK: - Learning and unlearning

    /// Adds one meeting's cluster to a profile, creating it when the name is new.
    /// `nil` when the contribution carries no usable vector.
    static func adding(
        _ contribution: [Float], to profile: Profile?, name: String, at now: Date
    ) -> Profile? {
        guard let unit = SpeakerClusterCleanup.normalized(contribution) else { return nil }
        guard var profile else {
            return Profile(id: identifier(for: name), name: name, sum: unit,
                           meetings: 1, createdAt: now, updatedAt: now)
        }
        guard profile.sum.count == unit.count else { return nil }
        for index in unit.indices { profile.sum[index] += unit[index] }
        profile.meetings += 1
        profile.name = name
        profile.updatedAt = now
        return profile
    }

    /// Takes one meeting's cluster back out of a profile — the correction in the
    /// speaker dialog (§3.3): the wrong profile loses this cluster.
    ///
    /// `nil` means the profile is gone: its last meeting was the one just
    /// retracted, and a profile built from nothing is not a voice.
    static func removing(_ contribution: [Float], from profile: Profile, at now: Date) -> Profile? {
        guard profile.meetings > 1, let unit = SpeakerClusterCleanup.normalized(contribution),
              profile.sum.count == unit.count else { return nil }
        var reduced = profile
        for index in unit.indices { reduced.sum[index] -= unit[index] }
        reduced.meetings -= 1
        reduced.updatedAt = now
        // Subtracting the only real contribution can leave a vector of zeros,
        // which is not a direction any more.
        guard reduced.vector != nil else { return nil }
        return reduced
    }

    // MARK: - Storage format

    /// Little-endian Float32, the way the vectors arrive from CoreML. Kept as a
    /// BLOB rather than JSON: 256 floats per profile, and this table is read on
    /// every meeting.
    static func encode(_ vector: [Float]) -> Data {
        let littleEndian = vector.map { $0.bitPattern.littleEndian }
        return littleEndian.withUnsafeBytes { Data($0) }
    }

    static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<UInt32>.size
        guard count > 0 else { return [] }
        var words = [UInt32](repeating: 0, count: count)
        words.withUnsafeMutableBufferPointer { buffer in
            _ = data.copyBytes(to: buffer, from: 0 ..< count * MemoryLayout<UInt32>.size)
        }
        return words.map { Float(bitPattern: UInt32(littleEndian: $0)) }
    }
}
