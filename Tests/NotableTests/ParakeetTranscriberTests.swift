import FluidAudio
import XCTest

/// Round-trip test: macOS `say` synthesizes speech, Parakeet transcribes it
/// back. Verifies model download, CoreML loading, and transcription without
/// needing microphone access. First run downloads the models from
/// HuggingFace, so allow several minutes.
final class ParakeetTranscriberTests: XCTestCase {
    func testTranscribesSynthesizedSpeech() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-asr-test-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audioURL.path, "Hello world, this is a dictation test."]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0, "`say` konnte kein Audio erzeugen")

        let samples = try AudioConverter().resampleAudioFile(path: audioURL.path)
        XCTAssertGreaterThan(samples.count, 16_000, "Weniger als 1 s Audio erzeugt")

        let transcriber = ParakeetTranscriber()
        try await transcriber.prepare()
        let text = try await transcriber.transcribe(samples: samples, sampleRate: 16_000)

        let normalized = text.lowercased()
        XCTAssertTrue(
            normalized.contains("hello") || normalized.contains("dictation") || normalized.contains("test"),
            "Unerwartetes Transkript: \(text)"
        )
    }
}
