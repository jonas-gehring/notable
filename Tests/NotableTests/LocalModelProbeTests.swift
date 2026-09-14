import XCTest
@testable import Notable

/// Spec 32, Stufe 0 — **measure before building**. Skipped unless asked:
///
///     TEST_RUNNER_NOTABLE_LOCAL_MODEL=1 xcodebuild … test \
///         -only-testing:NotableTests/LocalModelProbeTests
///
/// Sends the last forty dictations from the local database (the rule-polished
/// text, never anything that left the device) and a fixed hand-made set through
/// the on-device model, and prints per item: words, milliseconds, accepted or
/// rejected, and input next to output. At the end, median and p95 per length
/// bucket. It asserts nothing — the numbers go into Spec 32 §8, and the
/// decision in §7.1 is taken from them.
///
/// Everything printed stays in the local test log.
final class LocalModelProbeTests: XCTestCase {
    /// Self-corrections, missing punctuation, spoken lists, names, numbers — the
    /// cases the rules cannot do and the ones where a model is most tempted to
    /// invent.
    static let handmade: [String] = [
        "wir treffen uns um zwei nein um drei im büro",
        "schick das bitte an max ich meine an moritz",
        "der termin ist am dienstag beziehungsweise am mittwoch",
        "das budget liegt bei 5000 euro korrektur 6000 euro",
        "ich brauche erstens milch zweitens brot und drittens eier",
        "hallo anna ich wollte kurz fragen ob du morgen zeit hast wir müssten über das projekt sprechen",
        "also ich denke ähm dass wir das so machen können aber ich bin mir nicht ganz sicher",
        "kannst du mir die unterlagen bis freitag schicken danke",
        "die präsentation hat drei teile einleitung analyse und fazit",
        "wir haben 12 prozent mehr umsatz als letztes jahr",
        "bitte ruf herrn müller zurück er hat wegen des vertrags angerufen",
        "ich ich wollte nur sagen dass das gut geklappt hat",
        "das meeting wurde auf nächste woche verschoben nein auf übernächste woche",
        "notiz an mich selbst stichpunkte für morgen kunde anrufen angebot schreiben rechnung prüfen",
        "lieber thomas vielen dank für deine nachricht ich melde mich nächste woche viele grüße jonas",
        "we should meet at two actually make that three",
        "send it to sarah i mean to sam",
        "the first thing is the budget the second thing is the timeline",
        "um so i think we can ship this on friday if nothing breaks",
        "can you review the pull request before lunch thanks",
        "ok",
        "ja passt",
        "das ist gut dann machen wir das so",
        "der server läuft auf port 8080 und die datenbank auf 5432",
        "am dritten märz um halb drei beim kunden in hamburg",
        "wir brauchen noch jemanden für das design vielleicht lisa oder tom",
        "ich finde die idee gut aber die umsetzung dauert zu lange",
        "erinner mich daran die miete zu überweisen",
        "das ist eine sehr sehr wichtige frage",
        "quasi haben wir das problem sozusagen schon gelöst",
    ]

    func testProbeLatencyAndQuality() async throws {
        guard ProcessInfo.processInfo.environment["NOTABLE_LOCAL_MODEL"] != nil else {
            throw XCTSkip("Nur auf Wunsch: TEST_RUNNER_NOTABLE_LOCAL_MODEL=1")
        }
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("Braucht macOS 26") }
        let availability = LocalModelAvailability.current
        guard availability.isAvailable else {
            throw XCTSkip("Lokales Modell nicht verfügbar: \(availability)")
        }

        let archive = ((try? await RecordingStore.shared.recentDictations(limit: 40)) ?? [])
            .map { $0.rawText ?? $0.text }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let inputs = archive.map { ("archiv", $0) } + Self.handmade.map { ("set", $0) }

        // A generous deadline: this measures the model, not the 4 s cut-off.
        let polisher = LocalPolisher(deadline: .seconds(60))
        let warmStart = ContinuousClock.now
        await polisher.prewarm()
        print("LOCAL_POLISH_PROBE prewarm_ms=\(Self.millis(since: warmStart)) items=\(inputs.count)")

        var samples: [(words: Int, ms: Int)] = []
        var accepted = 0
        for (source, input) in inputs {
            let words = LocalPolish.wordCount(input)
            let result = await polisher.polish(input, category: .prose)
            if let ms = result.milliseconds { samples.append((words, ms)) }
            if result.didPolish { accepted += 1 }
            print("""
                LOCAL_POLISH_PROBE source=\(source) words=\(words) ms=\(result.milliseconds ?? -1) \
                accepted=\(result.didPolish) failure=\(result.failure ?? "-")
                  IN : \(input.replacingOccurrences(of: "\n", with: " ⏎ "))
                  OUT: \(result.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                """)
        }

        for (label, range) in [("<25", 0 ..< 25), ("25-60", 25 ..< 61), (">60", 61 ..< Int.max)] {
            let bucket = samples.filter { range.contains($0.words) }.map(\.ms).sorted()
            guard !bucket.isEmpty else { continue }
            let median = bucket[bucket.count / 2]
            let p95 = bucket[min(bucket.count - 1, Int(Double(bucket.count) * 0.95))]
            print("LOCAL_POLISH_PROBE bucket=\(label) n=\(bucket.count) median_ms=\(median) p95_ms=\(p95)")
        }
        print("LOCAL_POLISH_PROBE accepted=\(accepted)/\(inputs.count)")
        #else
        throw XCTSkip("FoundationModels ist in diesem SDK nicht verfügbar")
        #endif
    }

    private static func millis(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now)
        return Int(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
    }
}
