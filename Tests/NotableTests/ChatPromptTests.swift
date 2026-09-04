import XCTest

final class ChatPromptTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_780_000_000)

    private func segment(_ speaker: String?, _ start: TimeInterval, _ text: String) -> ChatTranscriptSegment {
        ChatTranscriptSegment(speaker: speaker, start: start, text: text)
    }

    private func context(
        segments: [ChatTranscriptSegment],
        notes: String? = nil,
        summary: String? = nil,
        title: String? = "Weekly Sync"
    ) -> ChatContext {
        ChatContext(
            meetingTitle: title,
            date: date,
            segments: segments,
            userNotes: notes,
            summary: summary
        )
    }

    // MARK: - History serialization

    func testHistorySerializesInOrder() {
        let ctx = context(segments: [segment("Ich", 0, "Hallo zusammen.")])
        let history = [
            ChatTurn(role: .user, text: "Was war das Thema?"),
            ChatTurn(role: .assistant, text: "Das Budget."),
            ChatTurn(role: .user, text: "Und die Frist?"),
            ChatTurn(role: .assistant, text: "Freitag."),
        ]
        let prompt = ChatPrompt.user(
            context: ctx,
            history: history,
            question: "Wer ist verantwortlich?"
        )

        // Frage:/Antwort: labels, and each turn's text present.
        XCTAssertTrue(prompt.contains("Frage: Was war das Thema?"))
        XCTAssertTrue(prompt.contains("Antwort: Das Budget."))
        XCTAssertTrue(prompt.contains("Frage: Und die Frist?"))
        XCTAssertTrue(prompt.contains("Antwort: Freitag."))

        // Chronological order preserved.
        let order = [
            "Was war das Thema?",
            "Das Budget.",
            "Und die Frist?",
            "Freitag.",
        ].map { prompt.range(of: $0)!.lowerBound }
        XCTAssertEqual(order, order.sorted(), "Verlauf muss in Reihenfolge serialisiert werden.")

        // New question comes after the history.
        let newQ = prompt.range(of: "Wer ist verantwortlich?")!.lowerBound
        XCTAssertTrue(newQ > order.last!, "Neue Frage muss nach dem Verlauf stehen.")
    }

    // MARK: - relevantSegments

    func testRelevantSegmentsPicksHitsPlusNeighboursChronologicalDeduped() {
        let segments = [
            segment("Ich", 0, "Wir sprechen über das Budget."),   // 0 hit
            segment("Sprecher 1", 10, "Nur Füllmaterial hier."),  // 1 neighbour of 0 and 2
            segment("Ich", 20, "Und nochmal das Budget genau."),  // 2 hit
            segment("Sprecher 1", 30, "Weit weg und irrelevant."),// 3 neighbour of 2
            segment("Ich", 40, "Ganz anderes Randthema."),        // 4 excluded
        ]
        let picked = ChatPrompt.relevantSegments(segments, for: "Was zum Budget?")

        // Hits 0 and 2, plus neighbours 1 and 3 -> {0,1,2,3}, de-duplicated.
        XCTAssertEqual(picked.map(\.start), [0, 10, 20, 30])
        // Chronological.
        XCTAssertEqual(picked.map(\.start), picked.map(\.start).sorted())
        // Far segment excluded.
        XCTAssertFalse(picked.contains { $0.text.contains("Randthema") })
    }

    func testRelevantSegmentsIgnoresShortAndEmptyKeywords() {
        let segments = [
            segment("Ich", 0, "Das ist ein Satz."),
            segment("Ich", 10, "Noch ein Satz."),
        ]
        // Only sub-4-char words -> no keywords -> no matches.
        XCTAssertTrue(ChatPrompt.relevantSegments(segments, for: "wer wo?").isEmpty)
        XCTAssertTrue(ChatPrompt.relevantSegments(segments, for: "").isEmpty)
    }

    // MARK: - Threshold: full vs. excerpt

    func testBelowThresholdIncludesFullTranscript() {
        let segments = [
            segment("Ich", 0, "Wir sprechen über das Budget."),
            segment("Sprecher 1", 30, "Ein KATZENXYZ Randthema weit weg."),
        ]
        let prompt = ChatPrompt.user(
            context: context(segments: segments, summary: "OVERVIEWMARKER"),
            history: [],
            question: "Was zum Budget?"
        )

        XCTAssertTrue(prompt.contains("Transkript:"))
        XCTAssertTrue(prompt.contains("Budget"))
        // Full transcript => the far-away segment is present.
        XCTAssertTrue(prompt.contains("KATZENXYZ"))
        // No fallback markers.
        XCTAssertFalse(prompt.contains("AUSZUG"))
        XCTAssertFalse(prompt.contains("OVERVIEWMARKER"))
    }

    func testAboveThresholdExcludesFarSegmentsAndIncludesSummary() {
        let segments = [
            segment("Ich", 0, "Wir sprechen über das Budget."),      // hit
            segment("Sprecher 1", 10, "Direkter Nachbar bleibt."),   // neighbour
            segment("Ich", 20, "Ein KATZENXYZ Randthema weit weg."), // far, excluded
            segment("Sprecher 1", 30, "Noch mehr FROSCHABC Füllung."),// far, excluded
        ]
        let prompt = ChatPrompt.user(
            context: context(segments: segments, summary: "OVERVIEWMARKER"),
            history: [],
            question: "Was zum Budget?",
            maxTranscriptChars: 30 // force fallback
        )

        XCTAssertTrue(prompt.contains("AUSZUG"), "Fallback muss klar markiert sein.")
        XCTAssertTrue(prompt.contains("OVERVIEWMARKER"), "Summary muss als Übersicht rein.")
        XCTAssertTrue(prompt.contains("Budget"))
        // Far-away, non-neighbour segments excluded.
        XCTAssertFalse(prompt.contains("KATZENXYZ"))
        XCTAssertFalse(prompt.contains("FROSCHABC"))
    }

    // MARK: - User notes

    func testUserNotesAppearWhenPresent() {
        let ctx = context(
            segments: [segment("Ich", 0, "Hallo.")],
            notes: "MEINENOTIZ: Release am Montag."
        )
        let prompt = ChatPrompt.user(context: ctx, history: [], question: "Wann?")
        XCTAssertTrue(prompt.contains("Eigene Notizen des Nutzers"))
        XCTAssertTrue(prompt.contains("MEINENOTIZ: Release am Montag."))
    }

    func testUserNotesAbsentWhenNil() {
        let ctx = context(segments: [segment("Ich", 0, "Hallo.")], notes: nil)
        let prompt = ChatPrompt.user(context: ctx, history: [], question: "Wann?")
        XCTAssertFalse(prompt.contains("Eigene Notizen des Nutzers"))
    }

    // MARK: - Header

    func testHeaderCarriesTitle() {
        let prompt = ChatPrompt.user(
            context: context(segments: [segment("Ich", 0, "Hallo.")]),
            history: [],
            question: "Frage?"
        )
        XCTAssertTrue(prompt.contains("Meeting: Weekly Sync am"))
    }

    // MARK: - Review 2026-09-03

    /// The fallback exists for the context window, so it has to have a ceiling.
    func testExcerptStaysInsideItsCharacterBudget() {
        let segments = (0..<400).map { index in
            ChatTranscriptSegment(
                speaker: "Sprecher 1",
                start: Double(index),
                text: "Wir haben über das Budget gesprochen und welche Entscheidungen getroffen wurden \(index)."
            )
        }
        let picked = ChatPrompt.relevantSegments(
            segments, for: "Welche Entscheidungen wurden zum Budget getroffen?", characterBudget: 2_000
        )
        let size = picked.reduce(0) { $0 + $1.text.count }
        XCTAssertLessThanOrEqual(size, 2_000)
        XCTAssertFalse(picked.isEmpty, "Ein Budget darf den Auszug nicht ganz leeren")
    }

    /// Stop words are not keywords — otherwise "welche/wurden/haben" match
    /// every segment and the "excerpt" is the whole transcript.
    func testStopWordsAreNotKeywords() {
        let words = ChatPrompt.significantWords("Welche Entscheidungen wurden getroffen?")
        XCTAssertTrue(words.contains("entscheidungen"))
        for stopWord in ["welche", "wurden"] {
            XCTAssertFalse(words.contains(stopWord), "\(stopWord) darf kein Schlüsselwort sein")
        }
    }
}
