import XCTest

/// Whether another engine transcribes meetings better than Parakeet v3 is a
/// measurement (Spec 39 §3.4, plan of 2026-10-21), and this is it. Every
/// archived session goes through the whole pipeline as it stands today (VAD,
/// diarization, cleanup) with the engine named in the environment. The result
/// lands as a Markdown note in a folder of its own on this Mac, in the format
/// `scripts/benchmark` reads, so two engines can be measured against the same
/// Wispr export. What is printed are numbers only.
///
/// `MeetingReplayTests` replays the diarization alone; this one replays
/// everything, which takes about as long as transcribing the meetings did.
///
/// Skipped unless asked for — it reads the archive of whoever runs it:
///
///     TEST_RUNNER_NOTABLE_REPLAY=1 \
///     TEST_RUNNER_NOTABLE_REPLAY_ENGINE=whisper:large-v3-v20240930_turbo \
///     TEST_RUNNER_NOTABLE_REPLAY_SESSIONS=1C65,B6 \
///     xcodebuild … test -only-testing:NotableTests/MeetingPipelineReplayTests
///
/// - `NOTABLE_REPLAY_ENGINE`: `parakeet` (default) or `whisper:<model>`, the
///   model as named in `argmaxinc/whisperkit-coreml`. A Whisper model is
///   downloaded on first use, into the same folder the app uses.
/// - `NOTABLE_REPLAY_LANGUAGES`: `de` pins Whisper to German, `de,en` lets it
///   detect per segment (the default, as in the app).
/// - `NOTABLE_REPLAY_SESSIONS`: only sessions whose folder starts with one of
///   these prefixes.
/// - `NOTABLE_REPLAY_OUT`: where the notes go. Default
///   `~/Library/Application Support/Notable/replay/<engine>/`. The notes hold
///   the full transcripts; delete the folder once the numbers are taken.
final class MeetingPipelineReplayTests: XCTestCase {
    func testReplayWholeMeetings() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NOTABLE_REPLAY"] != nil else {
            throw XCTSkip("NOTABLE_REPLAY nicht gesetzt — liest das echte Archiv")
        }
        let engine = try ReplayEngine(environment["NOTABLE_REPLAY_ENGINE"] ?? "parakeet")

        // Whisper reads the spoken languages from the defaults, and this
        // process has its own. Set for the run, removed afterwards.
        if let languages = environment["NOTABLE_REPLAY_LANGUAGES"] {
            SpokenLanguages.save(languages.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        defer { UserDefaults.standard.removeObject(forKey: SpokenLanguages.storageKey) }

        let output = Self.outputFolder(environment).appendingPathComponent(engine.name, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let archive = ModelInventory.applicationRoot.appendingPathComponent("spool-archive", isDirectory: true)
        let sessions = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
        let prefixes = (environment["NOTABLE_REPLAY_SESSIONS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        let transcriber = try await engine.make()
        var totalAudio: TimeInterval = 0
        var totalCompute: TimeInterval = 0
        var replayed = 0
        print("REPLAY Engine \(engine.name) · Sprachen \(SpokenLanguages.load().joined(separator: ","))")
        for directory in sessions.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where prefixes.isEmpty || prefixes.contains(where: { directory.lastPathComponent.hasPrefix($0) }) {
            let session = SpoolStore.Session(directory: directory)
            // One track at a time would be kinder to memory, but the pipeline
            // needs both: the echo filter compares them.
            let mic = session.recordedURL(.mic).map(SpoolAudio.read) ?? []
            let system = session.recordedURL(.system).map(SpoolAudio.read) ?? []
            let audio = Double(max(mic.count, system.count)) / Double(PCMDownsampler.targetSampleRate)
            guard audio >= 30 else { continue }

            let clock = ContinuousClock()
            let started = clock.now
            let outcome = try await MeetingPipeline.processDetailed(
                micSamples: mic, systemSamples: system, transcriber: transcriber
            )
            let compute = Self.seconds(clock.now - started)
            totalAudio += audio
            totalCompute += compute
            replayed += 1

            let id = directory.lastPathComponent
            let statistics = ReplayStatistics(outcome.segments)
            print("""
                REPLAY \(id.prefix(8)): \(Self.minutes(audio)) Audio · \(Self.minutes(compute)) Rechenzeit \
                (\(String(format: "%.2f", compute / audio))× Echtzeit) · \(statistics.summary) · \(outcome.report.summary)
                """)

            let meta = (try? Data(contentsOf: session.metaURL))
                .flatMap { try? JSONDecoder().decode(SpoolStore.Meta.self, from: $0) }
            let note = MarkdownProjector.Note(
                title: "Replay \(id.prefix(8)) · \(engine.name)",
                date: meta?.startedAt ?? Date(timeIntervalSince1970: 0),
                calendarEventTitle: nil,
                segments: outcome.segments.map { ($0.speaker, $0.text) },
                summary: nil,
                startTimes: outcome.segments.map(\.start)
            )
            try MarkdownProjector.render(note)
                .write(to: output.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
        }
        if replayed > 0 {
            print("""
                REPLAY gesamt: \(replayed) Meetings · \(Self.minutes(totalAudio)) Audio · \(Self.minutes(totalCompute)) Rechenzeit \
                (\(String(format: "%.2f", totalCompute / totalAudio))× Echtzeit) · Notizen in \(output.path)
                """)
        } else {
            print("REPLAY: keine Sitzung im Archiv passt (mindestens 30 s Audio, Präfixe \(prefixes))")
        }
    }

    private static func outputFolder(_ environment: [String: String]) -> URL {
        if let path = environment["NOTABLE_REPLAY_OUT"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return ModelInventory.applicationRoot.appendingPathComponent("replay", isDirectory: true)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func minutes(_ seconds: TimeInterval) -> String {
        String(format: "%.1f min", seconds / 60)
    }

    // MARK: - Pure parts

    func testEngineNames() throws {
        XCTAssertEqual(try ReplayEngine("parakeet").name, "parakeet-v3")
        XCTAssertEqual(try ReplayEngine("whisper:large-v3-v20240930_turbo").name, "whisper-large-v3-v20240930_turbo")
        XCTAssertThrowsError(try ReplayEngine("whisper:"))
        XCTAssertThrowsError(try ReplayEngine("wav2vec"))
    }

    func testStatisticsCountWordsPerSpeaker() {
        let statistics = ReplayStatistics([
            MeetingTranscriptSegment(speaker: "Ich", start: 0, end: 1, text: "Hallo zusammen, kurz zum Stand."),
            MeetingTranscriptSegment(speaker: "Sprecher 1", start: 1, end: 2, text: "Gut."),
            MeetingTranscriptSegment(speaker: "Sprecher 2", start: 2, end: 3, text: "Ja, passt."),
            MeetingTranscriptSegment(speaker: "Sprecher ?", start: 3, end: 4, text: "Mhm."),
        ])
        XCTAssertEqual(statistics.segments, 4)
        XCTAssertEqual(statistics.words, 9)
        XCTAssertEqual(statistics.ownWords, 5)
        XCTAssertEqual(statistics.remoteSpeakers, 2)
        XCTAssertEqual(statistics.unknownWords, 1)
        XCTAssertEqual(statistics.summary, "4 Segmente · 9 Wörter · Ich 56 % · 2 Stimmen · Sprecher ? 11 % · Echo 0 %")
    }

    /// The echo measure of `scripts/benchmark`: a segment that mostly repeats
    /// a nearby segment of another speaker.
    func testEchoShareFindsARepeatedSegment() {
        let remote = "Die nördliche Region ist im letzten Monat um elf Prozent gewachsen."
        let statistics = ReplayStatistics([
            MeetingTranscriptSegment(speaker: "Sprecher 1", start: 0, end: 5, text: remote),
            MeetingTranscriptSegment(speaker: "Ich", start: 0.2, end: 5, text: remote),
            MeetingTranscriptSegment(speaker: "Ich", start: 6, end: 8, text: "Das freut mich sehr zu hören."),
        ])
        // Both copies are 11 words, the answer 6: 22 of 28 words sit in a repeat.
        XCTAssertEqual(statistics.echoShare, 22.0 / 28.0, accuracy: 0.001)
    }
}

/// Which engine a replay runs.
struct ReplayEngine {
    let name: String
    private let whisperModel: String?

    struct Unknown: Error, CustomStringConvertible {
        let raw: String
        var description: String { "NOTABLE_REPLAY_ENGINE=\(raw): erwartet parakeet oder whisper:<Modell>" }
    }

    init(_ raw: String) throws {
        if raw == "parakeet" {
            name = "parakeet-v3"
            whisperModel = nil
        } else if raw.hasPrefix("whisper:"), raw.count > "whisper:".count {
            let model = String(raw.dropFirst("whisper:".count))
            name = "whisper-\(model)"
            whisperModel = model
        } else {
            throw Unknown(raw: raw)
        }
    }

    func make() async throws -> any TranscriptionEngine {
        if let whisperModel {
            let whisper = WhisperTranscriber(modelName: whisperModel)
            try await whisper.prepare()
            return whisper
        }
        let parakeet = ParakeetTranscriber()
        try await parakeet.prepare()
        return parakeet
    }
}

/// The numbers printed per meeting. Words are counted the way `EchoFilter`
/// and `scripts/benchmark` count them, so the three agree.
struct ReplayStatistics {
    var segments = 0
    var words = 0
    var ownWords = 0
    var unknownWords = 0
    var remoteSpeakers = 0
    /// Share of the words in segments that mostly repeat a segment of another
    /// speaker up to six segments away (`echo_share` in the benchmark).
    var echoShare = 0.0

    init(_ transcript: [MeetingTranscriptSegment]) {
        segments = transcript.count
        var remote = Set<String>()
        let tokens = transcript.map { EchoFilter.words($0.text) }
        let grams = tokens.map(EchoFilter.triples)
        var repeated = 0
        for (index, segment) in transcript.enumerated() {
            let count = tokens[index].count
            words += count
            if segment.speaker == SpeakerNameResolver.micSpeakerLabel {
                ownWords += count
            } else if segment.speaker == SpeakerNameResolver.unknownSpeakerLabel {
                unknownWords += count
            } else if let speaker = segment.speaker {
                remote.insert(speaker)
            }
            guard grams[index].count >= 3 else { continue }
            let neighbours = max(0, index - 6)..<min(transcript.count, index + 7)
            let best = neighbours
                .filter { $0 != index && transcript[$0].speaker != segment.speaker && !grams[$0].isEmpty }
                .map { Double(grams[index].intersection(grams[$0]).count) / Double(grams[index].count) }
                .max() ?? 0
            if best >= 0.5 { repeated += count }
        }
        remoteSpeakers = remote.count
        echoShare = words > 0 ? Double(repeated) / Double(words) : 0
    }

    var summary: String {
        func percent(_ part: Int) -> String {
            words > 0 ? "\(Int((Double(part) / Double(words) * 100).rounded())) %" : "–"
        }
        return "\(segments) Segmente · \(words) Wörter · Ich \(percent(ownWords)) · \(remoteSpeakers) Stimmen"
            + " · Sprecher ? \(percent(unknownWords)) · Echo \(Int((echoShare * 100).rounded())) %"
    }
}
