import FluidAudio
import XCTest

/// Spec 24, Stufe 1: the cleanup's thresholds are starting values. This
/// measures them on real meetings — every archived session's system track
/// through VAD, diarization and the cleanup, with the label statistics printed
/// before and after. Payhawk is the first case to read.
///
/// Skipped unless asked for: it reads the archive of whoever runs it and takes
/// minutes.
///
///     TEST_RUNNER_NOTABLE_REPLAY=1 xcodebuild … test \
///       -only-testing:NotableTests/MeetingReplayTests
final class MeetingReplayTests: XCTestCase {
    func testReplayArchivedMeetings() async throws {
        guard ProcessInfo.processInfo.environment["NOTABLE_REPLAY"] != nil else {
            throw XCTSkip("NOTABLE_REPLAY nicht gesetzt — liest das echte Archiv")
        }
        let archive = ModelInventory.applicationRoot.appendingPathComponent("spool-archive", isDirectory: true)
        let sessions = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
        let vad = try await VadManager(modelDirectory: ModelInventory.applicationRoot)
        // `NOTABLE_REPLAY_SESSIONS=B6,FB7` replays only sessions starting with one
        // of these prefixes — a full run holds every track in memory in turn and
        // can be stopped by the system halfway.
        let prefixes = (ProcessInfo.processInfo.environment["NOTABLE_REPLAY_SESSIONS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for session in sessions.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where prefixes.isEmpty || prefixes.contains(where: { session.lastPathComponent.hasPrefix($0) }) {
            let files = (try? FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)) ?? []
            guard let track = files.first(where: { $0.lastPathComponent.hasPrefix("system.") }) else { continue }
            let samples = SpoolAudio.read(track)
            guard samples.count > 16_000 * 30 else { continue }
            let result = try await MeetingPipeline.diarizeSystemTrack(samples, vad: vad, expectedSpeakers: nil)
            print("REPLAY \(session.lastPathComponent)")
            print("  vorher:  \(Self.statistics(result.raw))")
            print("  nachher: \(Self.statistics(result.cleaned))")
            let distances = SpeakerClusterCleanup.splinterDistances(result.raw)
                .map { entry in
                    let distance = entry.distance.map { String(format: "%.2f", $0) } ?? "–"
                    return "\(entry.label):\(distance)@\(String(format: "%.1f", entry.duration))s"
                }
            print("  Splitter-Distanzen (Schwelle \(SpeakerClusterCleanup.reassignDistance)): \(distances.joined(separator: " "))")
        }
    }

    /// **Spec 36 §3.4 — the measurement Stufe 3's threshold waits for.**
    ///
    /// Spec 24 §9.1 measured splinter segments *inside* one meeting (0.58–1.04
    /// to the nearest large cluster). For the centroids of large clusters
    /// **across** meetings there is no number at all, and that is the number
    /// `VoiceProfiles.matchDistance` stands in for.
    ///
    /// Reads `Tests/Fixtures/voices.csv` — the owner's own labels, see the file
    /// — replays every archived meeting mentioned there, and prints the two
    /// distributions: same person and different people. The threshold is then
    /// the largest one that keeps false hits at or under 5 %, with a safety
    /// margin. Until the file has rows, this skips.
    func testVoiceDistancesAcrossMeetings() async throws {
        guard ProcessInfo.processInfo.environment["NOTABLE_REPLAY"] != nil else {
            throw XCTSkip("NOTABLE_REPLAY nicht gesetzt — liest das echte Archiv")
        }
        let labelled = try Self.labelledVoices()
        try XCTSkipIf(labelled.isEmpty, """
            Tests/Fixtures/voices.csv enthält noch keine Zeilen. Ohne Grundwahrheit \
            gibt es keine Messung — die Datei sagt, wie sie gefüllt wird.
            """)

        let archive = ModelInventory.applicationRoot.appendingPathComponent("spool-archive", isDirectory: true)
        let sessions = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
        let vad = try await VadManager(modelDirectory: ModelInventory.applicationRoot)

        // (Name, Zentroid) je gelabeltem Cluster, über alle Meetings.
        var voices: [(name: String, session: String, vector: [Float])] = []
        for session in sessions.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = session.lastPathComponent
            let rows = labelled.filter { id.hasPrefix($0.session) }
            guard !rows.isEmpty else { continue }
            let files = (try? FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)) ?? []
            guard let track = files.first(where: { $0.lastPathComponent.hasPrefix("system.") }) else { continue }
            let samples = SpoolAudio.read(track)
            guard samples.count > 16_000 * 30 else { continue }
            let result = try await MeetingPipeline.diarizeSystemTrack(samples, vad: vad, expectedSpeakers: nil)
            let large = SpeakerClusterCleanup.largeLabels(SpeakerClusterCleanup.totals(result.cleaned))
            let centroids = SpeakerClusterCleanup.centroids(of: result.cleaned)
            for row in rows {
                guard large.contains(row.cluster), let vector = centroids[row.cluster] else {
                    print("VOICES \(id) Cluster \(row.cluster) (\(row.name)): kein großer Cluster mit Zentroid")
                    continue
                }
                voices.append((row.name, id, vector))
            }
        }
        print("VOICES \(voices.count) gelabelte Cluster aus \(Set(voices.map(\.session)).count) Meetings")

        var same: [Float] = []
        var different: [Float] = []
        for (index, left) in voices.enumerated() {
            for right in voices[(index + 1)...] {
                // Zwei Cluster desselben Meetings sagen nichts über Meetings
                // hinweg — genau die Frage, um die es hier geht.
                guard left.session != right.session else { continue }
                let distance = VoiceProfiles.distance(left.vector, right.vector)
                if left.name.caseInsensitiveCompare(right.name) == .orderedSame {
                    same.append(distance)
                } else {
                    different.append(distance)
                }
            }
        }
        print("VOICES gleiche Person:      \(Self.distribution(same))")
        print("VOICES verschiedene Person: \(Self.distribution(different))")

        // Die größte Schwelle mit höchstens 5 % Falschtreffern — und wie viele
        // richtige sie erwischt. Beides gehört in Spec 36 §8.
        let sorted = different.sorted()
        let allowed = Int(Double(sorted.count) * 0.05)
        let threshold = sorted.isEmpty ? Float(0) : (allowed == 0 ? sorted[0] : sorted[allowed - 1])
        let caught = same.filter { $0 < threshold }.count
        print("""
        VOICES Schwelle bei ≤ 5 % Falschtreffern: \(String(format: "%.2f", threshold)) \
        — erwischt \(caught) von \(same.count) gleichen Paaren. \
        Startwert im Code: \(VoiceProfiles.matchDistance).
        """)
        XCTAssertFalse(voices.isEmpty, "keine der gelabelten Sitzungen lag im Archiv")
    }

    /// `Meeting-Präfix,Cluster,Name` — Kommentare und Leerzeilen fallen weg.
    private static func labelledVoices() throws -> [(session: String, cluster: String, name: String)] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/NotableTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/voices.csv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3, parts[0].lowercased() != "meeting" else { return nil }
            return (parts[0], parts[1], parts[2])
        }
    }

    private static func distribution(_ values: [Float]) -> String {
        guard !values.isEmpty else { return "keine Paare" }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        return "n=\(sorted.count) min \(String(format: "%.2f", sorted[0])) "
            + "median \(String(format: "%.2f", median)) max \(String(format: "%.2f", sorted[sorted.count - 1]))"
    }

    private static func statistics(_ segments: [SpeakerClusterCleanup.Segment]) -> String {
        let counts = segments.reduce(into: [String: Int]()) { $0[$1.label, default: 0] += 1 }
        return SpeakerClusterCleanup.totals(segments)
            .sorted { $0.value > $1.value }
            .map { label, seconds in "\(label): \(Int(seconds)) s (\(counts[label] ?? 0))" }
            .joined(separator: ", ")
    }
}
