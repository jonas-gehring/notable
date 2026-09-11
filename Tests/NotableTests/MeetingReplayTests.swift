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
        for session in sessions.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let files = (try? FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)) ?? []
            guard let track = files.first(where: { $0.lastPathComponent.hasPrefix("system.") }) else { continue }
            let samples = SpoolAudio.read(track)
            guard samples.count > 16_000 * 30 else { continue }
            let result = try await MeetingPipeline.diarizeSystemTrack(samples, vad: vad, expectedSpeakers: nil)
            print("REPLAY \(session.lastPathComponent)")
            print("  vorher:  \(Self.statistics(result.raw))")
            print("  nachher: \(Self.statistics(result.cleaned))")
        }
    }

    private static func statistics(_ segments: [SpeakerClusterCleanup.Segment]) -> String {
        let counts = segments.reduce(into: [String: Int]()) { $0[$1.label, default: 0] += 1 }
        return SpeakerClusterCleanup.totals(segments)
            .sorted { $0.value > $1.value }
            .map { label, seconds in "\(label): \(Int(seconds)) s (\(counts[label] ?? 0))" }
            .joined(separator: ", ")
    }
}
