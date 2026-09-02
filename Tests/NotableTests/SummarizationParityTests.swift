import XCTest

/// Realistisches Meeting-Transkript in der Form, die `MeetingPipeline`
/// erzeugt: "Ich:" für die Mikrofonspur, "Sprecher n:" für die diarisierte
/// Systemspur, ASR-typisches Rauschen (Füllwörter, fehlende Satzzeichen,
/// Dopplungen, "[unverständlich]"). Programmatisch aufgebaut: variierte
/// Themenblöcke werden so oft wiederholt, bis die Ziel-Zeichenzahl steht
/// (~60 Minuten Gespräch, ~12k-18k Tokens).
///
/// Drei markante Fakten sind bewusst gepflanzt — je einer am Anfang, in der
/// Mitte und am Ende, damit die Tests prüfen können, ob die Zusammenfassung
/// wirklich das ganze Transkript abdeckt und nicht nur den Anfang:
///   1. Entscheidung: Postgres statt MongoDB  (früh)
///   2. Action Item: Anna liefert das Lastenheft bis zum 14. März  (Mitte)
///   3. Zahl: freigegebenes Budget von 47.500 Euro  (spät)
enum MeetingTranscriptFixture {

    /// Gepflanzte Fakten inkl. akzeptierter Schreibweisen in der Antwort.
    static let plantedFacts: [(name: String, variants: [String])] = [
        ("Entscheidung Postgres statt MongoDB", ["postgre"]),
        ("Action Item Lastenheft (Anna, 14. März)", ["lastenheft"]),
        ("Budget 47.500 Euro", ["47.500", "47500", "47 500"]),
    ]

    static func longGermanMeeting(minimumCharacters: Int = 56_000) -> String {
        var lines: [String] = [
            "Ich: So, ich starte die Aufnahme. Willkommen zur Quartalsplanung Projekt Nordlicht.",
            "Sprecher 1: Ähm, kurz zur Agenda, wir haben heute Architektur, Migration, Budget und Personal.",
            "Sprecher 2: Bei mir hakt das Bild, aber der Ton geht. Ich schalte die Kamera aus.",
            "Ich: Kein Problem. Fangen wir mit der Architektur an.",
        ]

        // --- Gepflanzter Fakt 1: Entscheidung, früh im Transkript. ---
        lines += [
            "Sprecher 1: Wir müssen uns heute festlegen, ob die Datenhaltung auf Postgres oder auf MongoDB läuft.",
            "Sprecher 2: Also, ähm, MongoDB wäre schneller aufgesetzt, aber wir brauchen echte Transaktionen über mehrere Tabellen.",
            "Ich: Genau das ist der Punkt. Ohne Transaktionen bauen wir uns die Konsistenzprobleme selber ein.",
            "Sprecher 3: Und das Reporting-Team arbeitet ohnehin schon mit SQL, das spart uns eine Lernkurve.",
            "Sprecher 1: Gut, dann halten wir das fest: Entscheidung, wir setzen auf Postgres und nicht auf MongoDB.",
            "Ich: Beschlossen. Postgres ist gesetzt, MongoDB ist damit raus.",
            "Sprecher 2: Ich dokumentiere die Entscheidung im Architektur-Entscheidungsprotokoll, ADR sieben.",
        ]

        var round = 0
        while lines.joined(separator: "\n").count < minimumCharacters {
            lines += block(round: round)

            // --- Gepflanzter Fakt 2: Action Item, in der Mitte. ---
            if round == 2 {
                lines += [
                    "Sprecher 1: Bevor wir weitermachen, ich brauche für die Migration ein sauberes Lastenheft.",
                    "Ich: Anna, kannst du das übernehmen?",
                    "Sprecher 1: Ja. Ich, also Anna, erstelle das Lastenheft für die Migration und liefere es bis zum vierzehnten März.",
                    "Ich: Action Item: Anna schreibt das Lastenheft, Deadline vierzehnter März.",
                    "Sprecher 3: Ich liefere Anna bis dahin die Mengengerüste zu, äh, zu den Altdatenbeständen.",
                ]
            }
            round += 1
        }

        // --- Gepflanzter Fakt 3: Zahl/Budget, spät im Transkript. ---
        lines += [
            "Sprecher 2: Letzter Punkt, das Budget. Ich hatte 52.000 Euro beantragt.",
            "Ich: Der Bereichsleiter hat gekürzt. Freigegeben sind 47.500 Euro für das Gesamtprojekt.",
            "Sprecher 1: 47.500 Euro, okay, das reicht, wenn wir das Lasttest-Werkzeug mieten statt kaufen.",
            "Sprecher 3: Dann fällt die zweite Lizenz weg, das sind ähm rund 4.000 Euro weniger.",
            "Ich: Entscheidung: Budgetrahmen 47.500 Euro, die zweite Lizenz wird gestrichen.",
            "Sprecher 2: Offene Frage bleibt, ob wir den externen Berater im dritten Quartal noch bezahlen können.",
            "Sprecher 1: Das klären Markus und ich nächste Woche mit dem Einkauf.",
            "Ich: Gut, dann sind wir durch. Ich stoppe die Aufnahme.",
        ]

        return lines.joined(separator: "\n")
    }

    /// Ein Themenblock, dessen Zahlen und Formulierungen mit der Runde
    /// variieren — sonst wäre das Transkript reine Wiederholung und das
    /// Modell hätte es zu leicht.
    private static func block(round r: Int) -> [String] {
        let sprint = 12 + r
        let bugs = 17 + r * 3
        let latenz = 240 + r * 35
        let nutzer = 1_200 + r * 450
        let themen = [
            "Deployment-Pipeline", "Fehlerbudget", "Onboarding der Werkstudenten",
            "Schnittstelle zum CRM", "Lasttests", "Datenschutzfolgenabschätzung",
            "Rollout in der Region Nord", "Monitoring und Alarmierung",
        ]
        let thema = themen[r % themen.count]

        return [
            "Ich: Nächster Punkt, \(thema). Wo stehen wir da im Sprint \(sprint)?",
            "Sprecher 1: Also ähm, wir haben \(bugs) offene Tickets, davon sind sieben kritisch eingestuft.",
            "Sprecher 2: Die kritischen hängen fast alle am selben Modul, das ist, äh, das ist der alte Import-Job.",
            "Sprecher 3: Ich habe gestern gemessen, die Antwortzeit liegt im Schnitt bei \(latenz) Millisekunden.",
            "Ich: Das ist zu langsam. Unser Zielwert war unter zweihundert Millisekunden.",
            "Sprecher 1: Wir könnten den Import-Job asynchron machen, dann fällt die Wartezeit aus dem Request raus.",
            "Sprecher 2: Genau, genau, das hatten wir schon mal diskutiert, aber dann brauchen wir eine Warteschlange.",
            "Sprecher 3: [unverständlich] und das erhöht wieder die Betriebskomplexität.",
            "Ich: Wir nehmen das als offene Frage mit, ich will das nicht heute im Vorbeigehen entscheiden.",
            "Sprecher 1: Zum Thema \(thema) noch, wir haben aktuell \(nutzer) aktive Nutzer in der Beta.",
            "Sprecher 2: Die Rückmeldungen sind gut, drei Beschwerden über die Suche, sonst nichts Auffälliges.",
            "Sprecher 3: Die Suche ist langsam weil sie über die alte Volltextlösung läuft, das wissen wir.",
            "Ich: Okay. Markus, du schaust dir die Suche an, aber erst nach den kritischen Tickets.",
            "Sprecher 2: Verstanden, ich priorisiere die kritischen Tickets, danach die Suche.",
            "Sprecher 1: Ähm, kurze Zwischenfrage, wer übernimmt eigentlich die Freigabe für den Rollout?",
            "Ich: Die Freigabe mache ich, aber ich brauche vorher das Testprotokoll von Priya.",
            "Sprecher 3: Kriegst du. Ich, ähm, ich stelle das Testprotokoll bis Ende der Woche zusammen.",
            "Sprecher 1: Dann noch der Punkt Dokumentation, die ist auf dem Stand von Sprint \(sprint - 4).",
            "Sprecher 2: Ich weiß, ich weiß. Ich ziehe die Dokumentation nach, sobald der Import-Job steht.",
            "Ich: Gut. Halten wir fest, \(thema) bleibt im Blick, aber es blockiert uns nicht.",
            "Sprecher 3: Eine Sache noch, das Budget für die Lasttests, äh, das war noch nicht final.",
            "Sprecher 1: Kommt am Ende, das haben wir als eigenen Tagesordnungspunkt.",
        ]
    }
}

/// Misst, ob Zusammenfassung für ein *echtes* Meeting funktioniert — nicht
/// nur für Spielzeug-Eingaben. Beide Provider bekommen dasselbe Transkript.
/// Netzwerk/CLI nötig: fehlt eine Voraussetzung, wird sauber übersprungen.
final class SummarizationParityTests: XCTestCase {

    private static let context = MeetingContext(
        title: "Projekt Nordlicht — Quartalsplanung",
        date: Date(timeIntervalSince1970: 1_780_000_000),
        durationSeconds: 3600
    )

    // MARK: - Claude Code CLI (Abo)

    func testCLIProviderSummarizesLongMeeting() async throws {
        let provider = ClaudeCodeCLIProvider()
        let availability = await provider.availability()
        try XCTSkipIf(
            availability != .available,
            "Claude Code CLI nicht installiert — Test übersprungen."
        )
        try await runProbe(provider: provider, label: "claude-code-cli")
    }

    // MARK: - Anthropic API

    func testAnthropicAPIProviderSummarizesLongMeeting() async throws {
        let provider = AnthropicAPIProvider()
        let availability = await provider.availability()
        // Zwei mögliche Gründe: gar kein Key hinterlegt, oder der Eintrag ist
        // aus dem Test-Bundle (andere Bundle-ID als die App) nicht lesbar.
        if case .unavailable(let reason) = availability {
            throw XCTSkip("Anthropic-API-Key nicht erreichbar (\(reason)) — Hälfte übersprungen. "
                + "Key in den Einstellungen hinterlegen, dann liefert dieser Test die Vergleichszahlen.")
        }
        try await runProbe(provider: provider, label: "anthropic-api")
    }

    // MARK: - Gemeinsame Messung

    private func runProbe(provider: any SummarizationProvider, label: String) async throws {
        let transcript = MeetingTranscriptFixture.longGermanMeeting()
        let lines = transcript.split(separator: "\n").count
        // Grobe Token-Schätzung: Deutsch ~3,6 Zeichen/Token.
        let approxTokens = transcript.count / 4

        print("SUMMARY_PROBE provider=\(label) input_chars=\(transcript.count) input_lines=\(lines) approx_input_tokens=\(approxTokens)")
        XCTAssertGreaterThan(transcript.count, 50_000, "Fixture zu klein für ein 60-Minuten-Meeting")

        let start = Date()
        let summary: Summary
        do {
            summary = try await provider.summarize(transcript: transcript, context: Self.context)
        } catch {
            print("SUMMARY_PROBE provider=\(label) FAILED after \(String(format: "%.1f", Date().timeIntervalSince(start)))s error=\(error.localizedDescription)")
            throw error
        }
        let elapsed = Date().timeIntervalSince(start)

        let markdown = summary.markdown
        print("SUMMARY_PROBE provider=\(label) elapsed_s=\(String(format: "%.1f", elapsed)) output_chars=\(markdown.count) approx_output_tokens=\(markdown.count / 4)")

        XCTAssertFalse(markdown.isEmpty, "Leere Zusammenfassung")
        XCTAssertEqual(summary.providerID, provider.id)

        // Struktur aus SummarizationPrompt.system. Die TITLE/TLDR-Kopfzeilen
        // sind bereits von SummaryParser abgetrennt — markdown ist der Body.
        for section in ["## Zusammenfassung", "## Entscheidungen", "## Action Items", "## Themen"] {
            XCTAssertTrue(
                markdown.contains(section),
                "Abschnitt \(section) fehlt bei \(label). Antwort:\n\(markdown)"
            )
        }
        // Der Body darf die maschinellen Kopfzeilen nicht mehr enthalten.
        XCTAssertFalse(
            markdown.hasPrefix("TITLE:") || markdown.contains("\nTLDR:"),
            "TITLE/TLDR-Kopfzeilen wurden nicht aus dem Body entfernt: \(markdown.prefix(120))"
        )
        // Titel/Untertitel wurden aus den Kopfzeilen geparst.
        XCTAssertNotNil(summary.title, "Kein Titel aus den Kopfzeilen geparst bei \(label).")
        XCTAssertNotNil(summary.subtitle, "Kein Untertitel aus den Kopfzeilen geparst bei \(label).")

        // Inhaltliche Deckung: die gepflanzten Fakten müssen überleben.
        let haystack = markdown.lowercased()
        var found: [String] = []
        var missing: [String] = []
        for fact in MeetingTranscriptFixture.plantedFacts {
            if fact.variants.contains(where: { haystack.contains($0.lowercased()) }) {
                found.append(fact.name)
            } else {
                missing.append(fact.name)
            }
        }
        print("SUMMARY_PROBE provider=\(label) planted_facts_found=\(found.count)/\(MeetingTranscriptFixture.plantedFacts.count) missing=\(missing)")

        XCTAssertGreaterThanOrEqual(
            found.count, 2,
            "Zu wenige gepflanzte Fakten überlebten bei \(label). Gefunden: \(found), fehlend: \(missing).\nAntwort:\n\(markdown)"
        )
        // Deutsche Antwort, kein englischer Ausrutscher.
        XCTAssertFalse(
            haystack.contains("## summary") || haystack.contains("## decisions"),
            "Antwort ist nicht deutsch: \(markdown.prefix(200))"
        )

        print("SUMMARY_PROBE provider=\(label) markdown_begin\n\(markdown)\nSUMMARY_PROBE provider=\(label) markdown_end")
    }
}
