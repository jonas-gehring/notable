import FluidAudio
import XCTest

/// Streaming round-trip: an English sentence fed in half-second chunks,
/// exactly like the live dictation path. First run downloads the Parakeet
/// Unified models from HuggingFace.
final class EnglishStreamingTests: XCTestCase {
    func testStreamedChunksProduceTranscript() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-stream-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "Please schedule the product launch for early September and inform the whole team."]
        try say.run()
        say.waitUntilExit()
        let samples = try AudioConverter().resampleAudioFile(path: url.path)

        let transcriber = EnglishStreamingTranscriber()
        try await transcriber.prepare()
        try await transcriber.beginUtterance()

        // Feed in 0.5 s chunks like the recording tick does.
        let chunkSize = 8_000
        var index = 0
        while index < samples.count {
            let end = min(index + chunkSize, samples.count)
            try await transcriber.feed(Array(samples[index..<end]))
            index = end
        }
        let text = try await transcriber.finish().lowercased()

        XCTAssertTrue(
            text.contains("september") || text.contains("launch") || text.contains("schedule"),
            "Unerwartetes Streaming-Transkript: \(text)"
        )

        // Reusable for the next utterance after reset.
        try await transcriber.beginUtterance()
        let empty = await transcriber.partial()
        XCTAssertTrue(empty.isEmpty, "reset() muss den Transkript-Zustand leeren")
    }
}
