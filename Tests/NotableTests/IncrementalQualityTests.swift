import FluidAudio
import XCTest

/// The point of incremental decoding is that a long dictation costs the same
/// at release as a short one. It is only worth having if the text it produces
/// is as complete as the whole-clip path — a carried decoder state that snaps
/// (or a seam that swallows a word) would trade correctness for latency.
/// This drives a real 40 s clip through both paths and compares them.
/// Results in the log as "INCREMENTAL_PROBE".
final class IncrementalQualityTests: XCTestCase {
    /// Distinct sentences: a lost or duplicated seam shows up as a missing or
    /// doubled keyword rather than disappearing into a repetitive clip.
    private static let sentences = [
        ("alpha", "The first topic is the quarterly revenue in the northern region, which grew by eleven percent."),
        ("bravo", "Second, the product launch is now scheduled for the middle of September."),
        ("charlie", "Third, we still have an open question about the hiring budget for the platform team."),
        ("delta", "Fourth, the migration to the new database finished last weekend without any downtime."),
        ("echo", "Finally, the customer workshop in Hamburg was postponed until the end of October."),
    ]

    private func speak(_ text: String, sampleRate: Int) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-incr-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-r", "150", "-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        return try AudioConverter().resampleAudioFile(path: url.path)
    }

    func testIncrementalMatchesWholeClipAndPaysOffAtRelease() async throws {
        let sampleRate = 16_000

        // Assemble the clip with real pauses — the seams the cut points aim for.
        var clip: [Float] = []
        let pause = [Float](repeating: 0, count: sampleRate / 2)
        for (_, sentence) in Self.sentences {
            clip += try speak(sentence, sampleRate: sampleRate)
            clip += pause
        }
        let seconds = Double(clip.count) / Double(sampleRate)
        // Must clear the 14 s stateful limit (maximumSliceSeconds) with margin so
        // both regimes below are exercised: several 2 s ticks *and* the cold-session
        // whole-clip fallback (which only throws above that limit). The exact length
        // depends on the machine's `say` voice/rate (~24.5 s here), so the guard sits
        // well under it rather than right at the edge.
        XCTAssertGreaterThan(seconds, 18, "Der Clip muss lang genug für mehrere Slices und den Ganzclip-Fallback sein")

        let transcriber = ParakeetTranscriber()
        try await transcriber.prepare()
        _ = try await transcriber.transcribe(samples: Array(clip.prefix(sampleRate)), sampleRate: sampleRate) // warm

        // Whole-clip baseline: what the finish path falls back to.
        let wholeStarted = ContinuousClock.now
        let whole = try await transcriber.transcribe(samples: clip, sampleRate: sampleRate).lowercased()
        let wholeMillis = Self.millis(since: wholeStarted)

        // Incremental: the 2 s tick feeds the stable head while recording; at
        // release only the tail is left. That last call is the latency the
        // user actually feels.
        let session = transcriber.makeSession()
        var tick = 2 * sampleRate
        while tick < clip.count {
            _ = try await session.feedStableHead(from: Array(clip.prefix(tick)), sampleRate: sampleRate)
            tick += 2 * sampleRate
        }
        let pending = clip.count - session.processedCount
        let releaseStarted = ContinuousClock.now
        let incremental = try await session.finish(with: clip, sampleRate: sampleRate).lowercased()
        let releaseMillis = Self.millis(since: releaseStarted)

        print(String(
            format: "INCREMENTAL_PROBE %.1fs audio | whole-clip %.0f ms | release %.0f ms (%.1fs tail)",
            seconds, wholeMillis, releaseMillis, Double(pending) / Double(sampleRate)
        ))

        // Completeness: every sentence must survive the seams. A snapped
        // decoder state or a bad cut loses exactly this.
        for (label, sentence) in Self.sentences {
            let keyword = sentence
                .split(separator: " ")
                .first { $0.count > 7 }
                .map { String($0).lowercased() } ?? ""
            XCTAssertTrue(
                incremental.contains(keyword),
                "\(label): \"\(keyword)\" fehlt im inkrementellen Text — \(incremental)"
            )
            XCTAssertTrue(whole.contains(keyword), "\(label): Baseline selbst unvollständig — \(whole)")
        }

        // No duplication at the seams: the carried state must not re-emit the
        // head of a slice it already committed.
        let wholeWords = whole.split(separator: " ").count
        let incrementalWords = incremental.split(separator: " ").count
        XCTAssertLessThan(
            Double(incrementalWords), Double(wholeWords) * 1.25,
            "Inkrementell erzeugt deutlich mehr Wörter → Dopplung an einer Naht: \(incremental)"
        )
        XCTAssertGreaterThan(
            Double(incrementalWords), Double(wholeWords) * 0.75,
            "Inkrementell erzeugt deutlich weniger Wörter → Textverlust: \(incremental)"
        )

        // The whole reason the feature exists.
        XCTAssertLessThan(
            releaseMillis, wholeMillis,
            "Inkrementell muss bei Release schneller sein als der ganze Clip"
        )

        // When no tick ever fired (model still downloading, say), finish() would
        // hand the session the entire clip in one call. Above 15 s FluidAudio
        // silently switches to its stateless chunker, so the session must give
        // up rather than pretend — the controller then re-runs the whole clip,
        // which is what `whole` above already proved correct.
        let cold = transcriber.makeSession()
        do {
            _ = try await cold.finish(with: clip, sampleRate: sampleRate)
            XCTFail("Ein \(Int(seconds)) s-Slice darf nicht still auf den zustandslosen Pfad rutschen")
        } catch DictationSession.SessionError.sliceExceedsStatefulLimit {
            // expected — the whole-clip fallback takes over
        }
    }

    private static func millis(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
    }
}
