import FluidAudio
import XCTest

/// Lautsprecher-Bleed: Wer *ohne Kopfhörer* in einem Call sitzt, hört die
/// Gegenseite aus den Laptop-Lautsprechern — und das Mikrofon hört sie mit.
/// `AudioRecorder` hängt einen rohen Tap an `AVAudioEngine.inputNode`
/// (AudioRecorder.swift:34) ohne Voice-Processing/AEC, der System-Tap nimmt
/// dieselbe Ausgabe ohnehin ab (`CATapDescription(stereoGlobalTapButExcludeProcesses: [])`,
/// SystemAudioTap.swift:63). Beide Spuren tragen dann dieselbe fremde Äußerung.
///
/// Diese Suite baut genau das nach — Mikrofonspur = eigene Sprache **plus**
/// gedämpfte, verzögerte, verrauschte Kopie der Systemspur — und schickt es
/// durch `MeetingPipeline.process`. Erwartetes (Fehl-)Verhalten: die Sätze der
/// Gegenseite tauchen ein zweites Mal auf, zugeschrieben an 'Ich'.
final class EchoBleedTests: XCTestCase {

    // MARK: - Szenario

    private struct Turn {
        enum Track { case mine, remote }
        let track: Track
        let voice: String?
        let text: String
        /// Wort, das in keinem anderen Turn vorkommt — der Marker, den wir verfolgen.
        let keyword: String
    }

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
    ]

    /// Die Marker der Gegenseite. Tauchen sie auf 'Ich' auf, ist der Bug da.
    private static var remoteKeywords: [String] {
        turns.filter { $0.track == .remote }.map(\.keyword)
    }
    private static var myKeywords: [String] {
        turns.filter { $0.track == .mine }.map(\.keyword)
    }

    // MARK: - Akustik

    /// Dämpfung des Lautsprecher-Rückwegs. −11 dB ist konservativ: ein MacBook
    /// bei halber Lautstärke, 50 cm vom eingebauten Mikrofon, liegt eher darüber.
    private static let bleedGain: Float = 0.28
    /// Laufzeit Lautsprecher → Mikrofon plus Puffer-Versatz der beiden Ketten.
    private static let bleedDelay: TimeInterval = 0.08
    private static let sampleRate = 16_000

    /// Genau das, was Lautsprecher-Bleed physikalisch ist: gedämpft, verzögert,
    /// bandbegrenzt (Gehäuse + Raum), leicht verrauscht.
    private func bleed(of system: [Float], into mic: inout [Float]) {
        let delaySamples = Int(Self.bleedDelay * Double(Self.sampleRate))
        if mic.count < system.count + delaySamples {
            mic += [Float](repeating: 0, count: system.count + delaySamples - mic.count)
        }
        var generator = SystemRandomNumberGenerator()
        var lowpass: Float = 0
        for index in 0..<system.count {
            // Ein-Pol-Tiefpass ~ Lautsprecher-/Raumcharakteristik.
            lowpass += 0.45 * (system[index] - lowpass)
            let noise = Float.random(in: -0.0015...0.0015, using: &generator)
            mic[index + delaySamples] += Self.bleedGain * lowpass + noise
        }
    }

    private func speak(_ text: String, voice: String?) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-bleed-\(UUID().uuidString).aiff")
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

    /// Baut beide Spuren im Gleichtakt (wie MeetingConversationTests) und
    /// mischt anschließend den Lautsprecher-Rückweg in die Mikrofonspur.
    private func buildTracks(withBleed: Bool) throws -> (mic: [Float], system: [Float]) {
        let pause = [Float](repeating: 0, count: Self.sampleRate / 2)
        var mic: [Float] = []
        var system: [Float] = []
        for turn in Self.turns {
            let audio = try speak(turn.text, voice: turn.voice)
            let silence = [Float](repeating: 0, count: audio.count)
            mic += (turn.track == .mine ? audio : silence) + pause
            system += (turn.track == .remote ? audio : silence) + pause
        }
        if withBleed { bleed(of: system, into: &mic) }
        return (mic, system)
    }

    private func run(_ tracks: (mic: [Float], system: [Float])) async throws -> [MeetingTranscriptSegment] {
        let transcriber = ParakeetTranscriber()
        try await transcriber.prepare()
        return try await MeetingPipeline.process(
            micSamples: tracks.mic,
            systemSamples: tracks.system,
            transcriber: transcriber
        )
    }

    private func dump(_ label: String, _ segments: [MeetingTranscriptSegment]) {
        for segment in segments {
            print(String(format: "%@ %.1f–%.1f s [%@] %@",
                         label, segment.start, segment.end, segment.speaker ?? "?", segment.text))
        }
    }

    private func carriers(
        of keyword: String, on speaker: String, in segments: [MeetingTranscriptSegment]
    ) -> [MeetingTranscriptSegment] {
        segments.filter { $0.speaker == speaker && $0.text.lowercased().contains(keyword) }
    }

    // MARK: - 1. Der Bug

    /// Ohne Kopfhörer: die Worte der Gegenseite erscheinen ein zweites Mal,
    /// zugeschrieben an 'Ich'. Eine Notiz, in der ich sage, was mein Gegenüber
    /// gesagt hat, ist schlimmer als eine fehlende Notiz.
    func testSpeakerBleedPutsRemoteWordsIntoMyMouth() async throws {
        let segments = try await run(buildTracks(withBleed: true))
        dump("BLEED_PROBE", segments)

        let phantoms = Self.remoteKeywords.flatMap { carriers(of: $0, on: "Ich", in: segments) }
        print("BLEED_PROBE phantom segments on \"Ich\": \(phantoms.count) → \(phantoms.map(\.text))")

        // Die Gegenmaßnahme sitzt eine Ebene HÖHER: der Meeting-Recorder schaltet
        // jetzt Voice-Processing/AEC ein (AudioRecorder.voiceProcessing,
        // MeetingController.start), damit der Bleed gar nicht erst in die
        // Mikrofonspur gelangt. Headless lässt sich das nicht prüfen — VPIO
        // filtert das, was das *Gerät* gerade abspielt, nicht Samples, die wir
        // künstlich hineinmischen.
        //
        // Dieser Test hält deshalb fest, was passiert, WENN doch Bleed durchkommt
        // (VPIO nicht verfügbar, Restecho, exotische Route): die Pipeline schreibt
        // dem Nutzer die Worte der Gegenseite in den Mund. Er bleibt die
        // Begründung dafür, dass die AEC-Schicht existieren muss.
        XCTExpectFailure(
            "Bekannt: Bleed, der bis in die Mikrofonspur durchkommt, dupliziert die " +
            "Gegenseite auf 'Ich' — das Echo füllt zudem die Pausen, sodass die VAD " +
            "es mit der eigenen Rede verschmilzt (MeetingPipeline.swift:86). Verhindert " +
            "wird das upstream durch AEC (AudioRecorder.voiceProcessing), nicht hier."
        ) {
            for keyword in Self.remoteKeywords {
                XCTAssertTrue(
                    carriers(of: keyword, on: "Ich", in: segments).isEmpty,
                    "'\(keyword)' (Gegenseite) wurde 'Ich' zugeschrieben"
                )
            }
        }

        // Meine eigenen Worte müssen natürlich weiterhin auf 'Ich' stehen —
        // sonst misst der Test etwas anderes als den Bleed.
        for keyword in Self.myKeywords {
            XCTAssertFalse(
                carriers(of: keyword, on: "Ich", in: segments).isEmpty,
                "Eigener Marker '\(keyword)' fehlt auf 'Ich' — Szenario kaputt, nicht der Bug"
            )
        }
    }

    /// Kontrollgruppe: dieselben Turns, aber mit Kopfhörer (kein Bleed).
    /// Wenn hier nichts Fremdes auf 'Ich' landet, liegt es oben wirklich am Bleed.
    func testWithHeadphonesNothingRemoteLandsOnIch() async throws {
        let segments = try await run(buildTracks(withBleed: false))
        dump("CLEAN_PROBE", segments)

        for keyword in Self.remoteKeywords {
            XCTAssertTrue(
                carriers(of: keyword, on: "Ich", in: segments).isEmpty,
                "Ohne Bleed darf '\(keyword)' nicht auf 'Ich' stehen"
            )
        }
    }

    // MARK: - 2. Warum Gegenmaßnahme (b) — Post-hoc-Dedup — NICHT reicht

    /// Der eigentliche Befund, und er ist schlimmer als „ein Geistersegment zu
    /// viel": Das Echo füllt die Pausen der Mikrofonspur, also sieht der VAD
    /// (MeetingPipeline.swift:86) keine Sprechpause mehr und **verschmilzt** die
    /// fremde Äußerung mit meiner darauffolgenden zu EINEM Segment:
    ///
    ///     [Ich] 5.3–17.0 s  "Sure, the northern region grew by 11% …
    ///                        That is encouraging to hear. What about the hiring budget …"
    ///
    /// Damit ist jede Dedup auf *Segment*-Ebene chancenlos: das Segment ist
    /// halb Geist, halb echt. Dieser Test hält beide Hörner des Dilemmas fest.
    func testSegmentLevelDedupCannotFixThisBecauseVADFusesEchoWithMySpeech() async throws {
        let segments = try await run(buildTracks(withBleed: true))
        dump("FUSION_PROBE", segments)

        // Horn 0 — die Fusion selbst: ein Mikrofonsegment trägt Wörter der
        // Gegenseite UND meine eigenen. Genau daran zerbricht (b).
        let fused = segments.filter { segment in
            guard segment.speaker == "Ich" else { return false }
            let text = segment.text.lowercased()
            return Self.remoteKeywords.contains(where: text.contains)
                && Self.myKeywords.contains(where: text.contains)
        }
        print("FUSION_PROBE verschmolzene Segmente: \(fused.count) → \(fused.map(\.text))")
        XCTAssertFalse(
            fused.isEmpty,
            "Erwartet: VAD verschmilzt Echo + eigene Rede zu einem 'Ich'-Segment"
        )

        // Horn 1 — konservative Dedup (Zeit-Overlap UND Textähnlichkeit):
        // lässt das verschmolzene Segment stehen, der Geist bleibt in der Notiz.
        let conservative = Self.dedup(segments, requireSimilarText: true)
        let survivingPhantoms = Self.remoteKeywords.flatMap { carriers(of: $0, on: "Ich", in: conservative) }
        XCTAssertFalse(
            survivingPhantoms.isEmpty,
            "Konservative Dedup hätte den Geist entfernt — dann wäre (b) doch tragfähig"
        )

        // Horn 2 — aggressive Dedup (nur Zeit-Overlap): killt den Geist, aber
        // reißt meinen eigenen Redebeitrag mit raus, weil er im selben Segment
        // steckt. Datenverlust statt Falschaussage — auch keine Lösung.
        let aggressive = Self.dedup(segments, requireSimilarText: false)
        let lostOwnWords = Self.myKeywords.filter { carriers(of: $0, on: "Ich", in: aggressive).isEmpty }
        XCTAssertFalse(
            lostOwnWords.isEmpty,
            "Aggressive Dedup hätte meine eigene Rede verschont — dann wäre (b) doch tragfähig"
        )
        print("FUSION_PROBE aggressive Dedup verliert eigene Marker: \(lostOwnWords)")

        // Fazit, das der Test beweist: der Fix muss VOR den VAD, ins Signal
        // (AEC auf der Mikrofonspur) — nicht hinter die Segmentierung.
    }

    /// Prototyp der Gegenmaßnahme (b), nur im Test. `requireSimilarText: true`
    /// = konservativ (Overlap + Jaccard), `false` = aggressiv (nur Overlap).
    static func dedup(
        _ segments: [MeetingTranscriptSegment], requireSimilarText: Bool
    ) -> [MeetingTranscriptSegment] {
        let system = segments.filter { $0.speaker != "Ich" }
        return segments.filter { segment in
            guard segment.speaker == "Ich" else { return true }
            let duration = max(segment.end - segment.start, 0.001)
            return !system.contains { other in
                let overlap = min(segment.end, other.end) - max(segment.start, other.start)
                guard overlap / duration >= 0.5 else { return false }
                return requireSimilarText ? similarity(segment.text, other.text) >= 0.6 : true
            }
        }
    }

    /// Jaccard über Wortmengen — robust gegen die ASR-Fehler, die das gedämpfte
    /// Echo zwangsläufig erzeugt (exakter Textvergleich wäre zu spröde).
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        func tokens(_ text: String) -> Set<String> {
            Set(text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 })
        }
        let a = tokens(lhs), b = tokens(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}
