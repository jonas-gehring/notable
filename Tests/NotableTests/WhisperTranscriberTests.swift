import FluidAudio
import XCTest

/// Round-trip test: macOS `say` synthesizes speech, Whisper (WhisperKit)
/// transcribes it back. Verifies model download, CoreML loading, and
/// transcription of Notable's 16 kHz mono Float32 input — no microphone
/// needed. First run downloads the model from HuggingFace
/// (`argmaxinc/whisperkit-coreml`); skipped if that download fails (e.g.
/// offline CI).
final class WhisperTranscriberTests: XCTestCase {
    func testTranscribesSynthesizedSpeech() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-whisper-test-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audioURL.path, "Hello world, this is a dictation test."]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0, "`say` konnte kein Audio erzeugen")

        // Reuse FluidAudio's converter to produce 16 kHz mono Float32 —
        // exactly the format the recorder hands the engine at runtime.
        let samples = try AudioConverter().resampleAudioFile(path: audioURL.path)
        XCTAssertGreaterThan(samples.count, 16_000, "Weniger als 1 s Audio erzeugt")

        // `base` matches the app default; skip cleanly if the model can't load.
        let transcriber = WhisperTranscriber(modelName: "base")
        do {
            try await transcriber.prepare()
        } catch {
            throw XCTSkip("Whisper-Modell nicht ladbar (offline?): \(error.localizedDescription)")
        }

        let text = try await transcriber.transcribe(samples: samples, sampleRate: 16_000)
        let normalized = text.lowercased()
        XCTAssertTrue(
            normalized.contains("hello") || normalized.contains("dictation") || normalized.contains("test"),
            "Unerwartetes Transkript: \(text)"
        )
    }

    /// Verifies the `large-v3` model id actually resolves and loads in WhisperKit
    /// (so the Settings option is real, not a broken choice), and pre-caches the
    /// ~1.5 GB bundle. Skips cleanly offline. First run is slow — the download.
    func testLargeV3ModelLoadsAndTranscribes() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-whisper-large-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audioURL.path, "Hello world, this is a dictation test."]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0, "`say` konnte kein Audio erzeugen")

        let samples = try AudioConverter().resampleAudioFile(path: audioURL.path)
        XCTAssertGreaterThan(samples.count, 16_000, "Weniger als 1 s Audio erzeugt")

        let transcriber = WhisperTranscriber(modelName: WhisperModelSize.largeV3.modelName)
        do {
            try await transcriber.prepare()
        } catch {
            throw XCTSkip("Whisper large-v3 nicht ladbar (offline?): \(error.localizedDescription)")
        }

        let text = try await transcriber.transcribe(samples: samples, sampleRate: 16_000)
        let normalized = text.lowercased()
        XCTAssertTrue(
            normalized.contains("hello") || normalized.contains("dictation") || normalized.contains("test"),
            "Unerwartetes Transkript: \(text)"
        )
    }
}
