import FluidAudio
import XCTest

/// Headless end-to-end run of the full meeting pipeline: two synthesized
/// audio tracks (mic = "Ich", system = remote participant) through VAD,
/// diarization, and per-segment ASR. First run downloads the diarization
/// models from HuggingFace.
final class MeetingPipelineE2ETests: XCTestCase {
    private func synthesize(_ text: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-meeting-test-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else {
            throw XCTSkip("`say` nicht verfügbar")
        }
        return try AudioConverter().resampleAudioFile(path: url.path)
    }

    func testTwoTrackMeetingProducesAttributedTranscript() async throws {
        let sampleRate = 16_000
        let gap = [Float](repeating: 0, count: sampleRate)

        let mine = try synthesize("Hello everyone, I will present the quarterly results now.")
        let remote = try synthesize("Thank you very much. The numbers look really good this time.")

        // Mic track: my sentence, then silence while the other speaks.
        let micTrack = mine + gap + [Float](repeating: 0, count: remote.count)
        // System track: silence while I speak, then the remote participant.
        let systemTrack = [Float](repeating: 0, count: mine.count) + gap + remote

        let transcriber = ParakeetTranscriber()
        try await transcriber.prepare()

        let segments = try await MeetingPipeline.process(
            micSamples: micTrack,
            systemSamples: systemTrack,
            transcriber: transcriber
        )

        XCTAssertGreaterThanOrEqual(segments.count, 2, "Erwartet: je ein Segment pro Spur")
        XCTAssertEqual(segments.first?.speaker, "Ich", "Mikrofon-Segment muss zuerst kommen")
        XCTAssertTrue(
            segments.contains { $0.speaker?.hasPrefix("Sprecher") == true },
            "System-Spur muss diarisiert als 'Sprecher n' auftauchen"
        )
        XCTAssertEqual(
            segments.map(\.start),
            segments.map(\.start).sorted(),
            "Segmente müssen chronologisch sortiert sein"
        )

        let fullText = segments.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(
            fullText.contains("results") || fullText.contains("quarterly"),
            "Mikrofon-Inhalt fehlt: \(fullText)"
        )
        XCTAssertTrue(
            fullText.contains("numbers") || fullText.contains("thank"),
            "System-Audio-Inhalt fehlt: \(fullText)"
        )
    }
}
