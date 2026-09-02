import FluidAudio
import XCTest

final class IncrementalDictationTests: XCTestCase {
    func testCutPointLandsInSilenceGap() {
        let sr = 16_000
        var samples: [Float] = []
        samples += (0..<sr).map { sinf(Float($0) * 0.3) * 0.4 } // 1 s loud
        samples += [Float](repeating: 0, count: sr / 2)          // 0.5 s silence
        samples += (0..<sr).map { sinf(Float($0) * 0.3) * 0.4 } // 1 s loud

        let cut = IncrementalDictation.cutPoint(
            in: samples,
            searchStart: Int(0.8 * Double(sr)),
            searchEnd: Int(2.2 * Double(sr)),
            sampleRate: sr
        )
        XCTAssertGreaterThan(cut, sr, "Schnitt muss in der Stille liegen (nach 1,0 s)")
        XCTAssertLessThan(cut, sr + sr / 2, "Schnitt muss in der Stille liegen (vor 1,5 s)")
    }

    /// FluidAudio's `transcribe(_:decoderState:)` silently drops to a
    /// *stateless* chunked path above ASRConstants.maxModelSamples (15 s) —
    /// the carried decoder state is then neither read nor written. The session
    /// must recognise that limit rather than walk into it.
    func testStatefulLimitStaysBelowFluidAudiosChunkerThreshold() {
        let sr = 16_000
        XCTAssertLessThan(
            Int(IncrementalDictation.maximumSliceSeconds * Double(sr)), 240_000,
            "15 s ist die Grenze zum zustandslosen Pfad — darunter bleiben"
        )
        XCTAssertFalse(IncrementalDictation.exceedsStatefulLimit(sampleCount: 13 * sr, sampleRate: sr))
        XCTAssertTrue(IncrementalDictation.exceedsStatefulLimit(sampleCount: 20 * sr, sampleRate: sr))
    }

    /// Real incremental run: a long clip is fed as head (at a silence seam)
    /// plus tail with carried decoder state; the combined text must contain
    /// both halves' content.
    func testSessionHeadPlusTailMatchesContent() async throws {
        let sr = 16_000

        func speak(_ text: String) throws -> [Float] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("notable-incr-\(UUID().uuidString).aiff")
            defer { try? FileManager.default.removeItem(at: url) }
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", url.path, text]
            try say.run()
            say.waitUntilExit()
            return try AudioConverter().resampleAudioFile(path: url.path)
        }

        let first = try speak("The first part of this dictation talks about the quarterly revenue figures in great detail, covering every single region and product line we have.")
        let second = try speak("And the second part is about the upcoming product launch in September.")
        let gap = [Float](repeating: 0, count: sr / 2)
        let full = first + gap + second

        let transcriber = ParakeetTranscriber()
        try await transcriber.prepare()
        let session = transcriber.makeSession()

        // Simulate the mid-recording tick: snapshot ends shortly into part two.
        let snapshot = Array(full.prefix(first.count + gap.count + sr))
        let fed = try await session.feedStableHead(from: snapshot, sampleRate: sr)
        XCTAssertTrue(fed, "Bei >8 s Audio muss inkrementell gefüttert werden")
        XCTAssertGreaterThan(session.processedCount, 0)
        XCTAssertFalse(session.text.isEmpty)

        let finalText = try await session.finish(with: full, sampleRate: sr).lowercased()
        XCTAssertTrue(finalText.contains("revenue") || finalText.contains("quarterly"), finalText)
        XCTAssertTrue(finalText.contains("september") || finalText.contains("launch"), finalText)
    }
}
