import FluidAudio
import XCTest

/// Measures warm whole-clip inference by clip length — the data basis for
/// deciding how much incremental decoding must buy. Results in the log as
/// "LATENCY_PROBE".
final class LatencyProbeTests: XCTestCase {
    func testWarmInferenceLatencyByClipLength() async throws {
        let sampleRate = 16_000

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-latency-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "This is a benchmark sentence used to measure transcription latency across different clip lengths."]
        try say.run()
        say.waitUntilExit()
        let base = try AudioConverter().resampleAudioFile(path: url.path)

        let transcriber = ParakeetTranscriber()
        try await transcriber.prepare()
        _ = try await transcriber.transcribe(samples: base, sampleRate: sampleRate) // warm-up

        for targetSeconds in [5, 15, 30, 60] {
            let targetCount = targetSeconds * sampleRate
            var clip: [Float] = []
            clip.reserveCapacity(targetCount)
            while clip.count < targetCount { clip.append(contentsOf: base) }
            clip = Array(clip.prefix(targetCount))

            let started = ContinuousClock.now
            _ = try await transcriber.transcribe(samples: clip, sampleRate: sampleRate)
            let elapsed = started.duration(to: .now)
            let millis = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15
            print(String(format: "LATENCY_PROBE %ds audio -> %.0f ms", targetSeconds, millis))
        }
    }
}
