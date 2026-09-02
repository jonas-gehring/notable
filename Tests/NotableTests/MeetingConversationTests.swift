import FluidAudio
import XCTest

/// A real meeting is a conversation, not two monologues. This drives an
/// interleaved four-turn exchange — me, remote A, me, remote B — through the
/// pipeline and checks the properties that actually decide whether a note is
/// usable: turns in the right order, each turn's words attributed to the track
/// they came from, and the two remote voices told apart.
final class MeetingConversationTests: XCTestCase {
    private struct Turn {
        let track: Track
        let voice: String?
        let text: String
        /// A word that appears in no other turn — the marker we trace.
        let keyword: String

        enum Track { case mine, remote }
    }

    /// Turns are long enough for the diarizer to build a usable embedding.
    /// Measured: below roughly five seconds of speech per person it collapses
    /// even a British male and an American female into one cluster — an
    /// inherent limit of the model, not of the merge (see CLAUDE.md).
    private static let turns: [Turn] = [
        Turn(track: .mine, voice: nil,
             text: "Good morning everyone, let us start today with the quarterly revenue and how the regions did.",
             keyword: "revenue"),
        Turn(track: .remote, voice: "Daniel",
             text: "Sure, the northern region grew by eleven percent last month, and the southern one held steady despite the season.",
             keyword: "northern"),
        Turn(track: .mine, voice: nil,
             text: "That is encouraging to hear. What about the hiring budget for the platform team this quarter?",
             keyword: "hiring"),
        Turn(track: .remote, voice: "Samantha",
             text: "The budget is unfortunately still frozen until the workshop in Hamburg, which was moved to the end of October.",
             keyword: "hamburg"),
        Turn(track: .remote, voice: "Daniel",
             text: "To add to that, the migration to the new database finished last weekend without any downtime at all.",
             keyword: "migration"),
        Turn(track: .remote, voice: "Samantha",
             text: "And the customer workshop feedback was excellent, so we should repeat the format in the coming spring.",
             keyword: "feedback"),
    ]

    private func speak(_ text: String, voice: String?) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-conv-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = (voice.map { ["-v", $0] } ?? []) + ["-r", "160", "-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else {
            throw XCTSkip("`say` mit Stimme \(voice ?? "Standard") nicht verfügbar")
        }
        return try AudioConverter().resampleAudioFile(path: url.path)
    }

    func testInterleavedConversationKeepsOrderAndAttribution() async throws {
        let sampleRate = 16_000
        let pause = [Float](repeating: 0, count: sampleRate / 2)

        // Build both tracks in lockstep: while one side speaks, the other is
        // silent — exactly how the mic and the system tap see a call.
        var micTrack: [Float] = []
        var systemTrack: [Float] = []
        for turn in Self.turns {
            let audio = try speak(turn.text, voice: turn.voice)
            let silence = [Float](repeating: 0, count: audio.count)
            micTrack += (turn.track == .mine ? audio : silence) + pause
            systemTrack += (turn.track == .remote ? audio : silence) + pause
        }

        let transcriber = ParakeetTranscriber()
        try await transcriber.prepare()
        let segments = try await MeetingPipeline.process(
            micSamples: micTrack,
            systemSamples: systemTrack,
            transcriber: transcriber
        )

        for segment in segments {
            print(String(format: "CONVERSATION_PROBE %.1f–%.1f s [%@] %@",
                         segment.start, segment.end, segment.speaker ?? "?", segment.text))
        }

        // 1. Every turn survived, and its marker is where it belongs: mic turns
        //    on "Ich", remote turns on a "Sprecher n" — never crossed over.
        for turn in Self.turns {
            let carriers = segments.filter { $0.text.lowercased().contains(turn.keyword) }
            XCTAssertFalse(carriers.isEmpty, "\"\(turn.keyword)\" fehlt im Transkript")
            for carrier in carriers {
                let speaker = carrier.speaker ?? ""
                switch turn.track {
                case .mine:
                    XCTAssertEqual(speaker, "Ich", "\"\(turn.keyword)\" wurde der Gegenseite zugeschrieben")
                case .remote:
                    XCTAssertTrue(
                        speaker.hasPrefix("Sprecher"),
                        "\"\(turn.keyword)\" wurde mir zugeschrieben statt der Gegenseite"
                    )
                }
            }
        }

        // 2. The conversation reads in the order it happened. Comparing the
        //    marker positions catches a merge that sorts by the wrong track's
        //    timeline — the failure mode the wall-clock gap padding exists for.
        let joined = segments.map(\.text.localizedLowercase).joined(separator: " ⏵ ")
        let positions = Self.turns.compactMap { joined.range(of: $0.keyword)?.lowerBound }
        XCTAssertEqual(positions.count, Self.turns.count, "Marker unvollständig: \(joined)")
        XCTAssertEqual(positions, positions.sorted(), "Redebeiträge stehen in falscher Reihenfolge: \(joined)")

        // 3. The two remote voices must not be collapsed into one speaker —
        //    a note where everyone is "Sprecher 1" cannot be read back.
        let remoteSpeakers = Set(segments.compactMap(\.speaker).filter { $0.hasPrefix("Sprecher") })
        XCTAssertGreaterThanOrEqual(
            remoteSpeakers.count, 2,
            "Diarisierung hat beide Gegenüber zu einem Sprecher verschmolzen: \(remoteSpeakers)"
        )
    }
}
