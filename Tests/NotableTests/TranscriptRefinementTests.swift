import XCTest

/// The AI pass over a meeting transcript. The model is replaced by a closure,
/// so what is tested is everything around it: which of its lines count as a
/// correction, and that nothing it does can cost the recognised text.
final class TranscriptRefinementTests: XCTestCase {
    private typealias Line = TranscriptRefinement.Line

    private func check(_ original: String, _ refined: String, vocabulary: [String] = []) -> RefinementGuard.Verdict {
        RefinementGuard.check(original: original, refined: refined, vocabulary: RefinementGuard.vocabularyKeys(vocabulary))
    }

    // MARK: - Was als Korrektur durchgeht

    func testPunctuationAndCasingAreFree() {
        XCTAssertEqual(check("ja genau das machen wir", "Ja, genau, das machen wir."), .accepted)
    }

    func testANameFromTheVocabularyReplacesWhatWasHeard() {
        XCTAssertEqual(check("Ich habe mit Jana Schulze gesprochen", "Ich habe mit Jana Schultze gesprochen",
                             vocabulary: ["Jana Schultze"]), .accepted)
    }

    /// Two misheard pieces written as the one term they were.
    func testTwoWordsJoinIntoTheTerm() {
        XCTAssertEqual(check("wir deployen das auf cuber netes", "wir deployen das auf Kubernetes"), .accepted)
        XCTAssertEqual(check("wir nutzen Mail Chimp dafür", "wir nutzen Mailchimp dafür"), .accepted)
    }

    /// The hyphen splits the word in two — the reverse direction of a join.
    func testACompoundMaySplitAtAHyphen() {
        XCTAssertEqual(check("Das ist ein Projektmanagementtool", "Das ist ein Projektmanagement-Tool"), .accepted)
    }

    func testAMisheardWordCloseInSpellingIsACorrection() {
        XCTAssertEqual(check("das lauft seid gestern", "das läuft seit gestern"), .accepted)
    }

    func testAnUnchangedLineIsReportedAsSuch() {
        XCTAssertEqual(check("Gut.", " Gut. "), .unchanged)
    }

    // MARK: - Was nie durchgeht

    func testANegationIsNeverAddedOrDropped() {
        XCTAssertEqual(check("wir machen das nicht", "wir machen das"), .rejected(.negation))
        XCTAssertEqual(check("wir machen das", "wir machen das nicht"), .rejected(.negation))
        // One letter apart, and the opposite statement.
        XCTAssertEqual(check("wir haben keine Zeit", "wir haben eine Zeit"), .rejected(.negation))
    }

    func testNumbersAreNeverTouched() {
        XCTAssertEqual(check("das kostet 300 Euro", "das kostet 400 Euro"), .rejected(.numbers))
        XCTAssertEqual(check("das kostet drei hundert Euro", "das kostet 300 Euro"), .rejected(.numbers))
    }

    /// The vocabulary does not make any name a correction: "Thomas" was not
    /// misheard as "Jana", it is somebody else.
    func testANameIsNotSwappedForAnUnrelatedOne() {
        XCTAssertEqual(check("Thomas hat das gesagt", "Jana hat das gesagt", vocabulary: ["Jana"]), .rejected(.unexplained))
        XCTAssertEqual(check("Thomas hat das gesagt", "Moritz hat das gesagt"), .rejected(.unexplained))
    }

    func testAnAddedWordIsNotACorrection() {
        XCTAssertEqual(check("ich schicke dir die Unterlagen", "ich schicke dir die Unterlagen morgen"), .rejected(.unexplained))
    }

    /// "lief" and "läuft" are two tenses, not one word misheard.
    func testAChangedTenseIsNotACorrection() {
        XCTAssertEqual(check("Die Fakturierung lief gut", "Die Fakturierung läuft gut"), .rejected(.unexplained))
    }

    /// Up to three letters, one letter is a different word.
    func testShortWordsMustMatchExactly() {
        XCTAssertEqual(check("ich bin im Büro", "ich bin in Büro"), .rejected(.unexplained))
    }

    func testARewriteIsRejected() {
        XCTAssertEqual(
            check("das war ein guter Termin und wir sehen uns nächste Woche wieder", "Danke für den Termin, bis nächste Woche."),
            .rejected(.tooManyChanges)
        )
    }

    func testAnEmptyAnswerIsRejected() {
        XCTAssertEqual(check("Ja.", ""), .rejected(.empty))
    }

    // MARK: - Antwort lesen

    func testTheAnswerIsReadByNumber() {
        let parsed = TranscriptRefinement.parse("""
        ```
        [1] Erste Zeile.
        [2] Zweite Zeile,
        die umgebrochen wurde.
        [2] Doppelt.
        ```
        """)
        XCTAssertEqual(parsed, [0: "Erste Zeile.", 1: "Zweite Zeile, die umgebrochen wurde."])
    }

    func testTextBeforeTheFirstNumberIsIgnored() {
        XCTAssertEqual(TranscriptRefinement.parse("Hier ist das Ergebnis:\n[3] Gut."), [2: "Gut."])
    }

    func testAnEchoedSpeakerIsStripped() {
        XCTAssertEqual(TranscriptRefinement.strippingSpeaker("Jana: Gut so.", speaker: "Jana"), "Gut so.")
        XCTAssertEqual(TranscriptRefinement.strippingSpeaker("Gut so.", speaker: "Jana"), "Gut so.")
    }

    // MARK: - Abschnitte und Begriffe

    func testChunksNeverSplitALine() {
        let lines = [
            Line(speaker: "Ich", text: "eins zwei drei"),
            Line(speaker: "Ich", text: "vier fünf"),
            Line(speaker: "Ich", text: "sechs sieben acht neun zehn elf"),
            Line(speaker: "Ich", text: "zwölf"),
        ]
        XCTAssertEqual(TranscriptRefinement.chunks(lines, wordsPerChunk: 5), [0..<2, 2..<3, 3..<4])
        XCTAssertEqual(TranscriptRefinement.chunks([], wordsPerChunk: 5), [])
    }

    func testTheVocabularyDropsLabelsAddressesAndDuplicates() {
        let vocabulary = TranscriptRefinement.vocabulary(
            names: ["Jana Schultze", "Ich", "Sprecher 2", "jana schultze", "max@example.com", " Moritz "],
            dictionary: ["Kubernetes"]
        )
        XCTAssertEqual(vocabulary, ["Jana Schultze", "Moritz", "Kubernetes"])
        XCTAssertEqual(TranscriptRefinement.vocabulary(names: ["A", "B", "C"], dictionary: [], limit: 2), ["A", "B"])
    }

    func testThePromptNumbersAcrossTheWholeMeeting() {
        let lines = [Line(speaker: "Ich", text: "eins"), Line(speaker: "Jana", text: "zwei")]
        let prompt = TranscriptRefinement.userPrompt(lines: lines, range: 1..<2, vocabulary: [], title: "Planung")
        XCTAssertTrue(prompt.contains("[2] Jana: zwei"))
        XCTAssertFalse(prompt.contains("[1]"))
        XCTAssertTrue(prompt.contains("Titel: Planung"))
        XCTAssertTrue(prompt.contains("Begriffsliste: keine"))
    }

    // MARK: - Der ganze Lauf

    private struct ProviderDown: LocalizedError {
        var errorDescription: String? { "Anbieter nicht erreichbar" }
    }

    /// A fake model: answers every numbered line of the prompt with `transform`
    /// applied to its text.
    private func model(_ transform: @escaping @Sendable (String) -> String) -> TranscriptRefinement.Complete {
        { _, user in
            var answer: [String] = []
            for line in user.split(separator: "\n") where line.hasPrefix("[") {
                guard let close = line.firstIndex(of: "]") else { continue }
                let rest = line[line.index(after: close)...].drop { $0 == " " }
                guard let colon = rest.range(of: ": ") else { continue }
                answer.append("\(line[...close]) \(transform(String(rest[colon.upperBound...])))")
            }
            return Completion(text: answer.joined(separator: "\n"), usage: SummarizationUsage(inputTokens: 10, outputTokens: 5))
        }
    }

    func testAcceptedLinesReplaceTheTextAndTheRestStays() async {
        let lines = [
            Line(speaker: "Ich", text: "ich habe mit jana schulze gesprochen"),
            Line(speaker: "Jana Schultze", text: "das kostet 300 Euro"),
            Line(speaker: "Ich", text: "gut"),
        ]
        let result = await TranscriptRefinement.refine(
            lines: lines, vocabulary: ["Jana Schultze"], title: nil,
            complete: model { text in
                text.replacingOccurrences(of: "jana schulze", with: "Jana Schultze")
                    .replacingOccurrences(of: "300", with: "400")
                    .replacingOccurrences(of: "gut", with: "Gut.")
            }
        )
        XCTAssertEqual(result.texts, ["ich habe mit Jana Schultze gesprochen", "das kostet 300 Euro", "Gut."])
        XCTAssertEqual(result.changed, 2)
        XCTAssertEqual(result.rejected, 1)
        XCTAssertEqual(result.usages.count, 1)
    }

    func testAFailingProviderLeavesEveryLine() async {
        let lines = (0..<6).map { Line(speaker: "Ich", text: "Zeile \($0) mit ein paar Wörtern") }
        let result = await TranscriptRefinement.refine(
            lines: lines, vocabulary: [], title: nil, wordsPerChunk: 6,
            complete: { _, _ in throw ProviderDown() }
        )
        XCTAssertEqual(result.texts, lines.map(\.text))
        XCTAssertEqual(result.chunks, 6)
        XCTAssertEqual(result.failedChunks, 6)
        XCTAssertEqual(result.firstError, "Anbieter nicht erreichbar")
        XCTAssertTrue(result.summary.contains("fehlgeschlagen 6"))
    }

    /// An answer whose lines are mostly not corrections is a model that did
    /// something else — none of it is used, not even the lines that passed.
    func testAChunkThatMostlyFailsIsDiscardedWhole() async {
        let lines = [
            Line(speaker: "Ich", text: "das machen wir"),
            Line(speaker: "Ich", text: "das machen wir morgen"),
            Line(speaker: "Ich", text: "ja genau"),
        ]
        let result = await TranscriptRefinement.refine(
            lines: lines, vocabulary: [], title: nil,
            complete: model { text in text == "ja genau" ? "Ja, genau." : "Das machen wir nicht." }
        )
        XCTAssertEqual(result.texts, lines.map(\.text))
        XCTAssertEqual(result.discardedChunks, 1)
        XCTAssertEqual(result.changed, 0)
    }

    func testALineMissingFromTheAnswerKeepsItsText() async {
        let lines = [Line(speaker: "Ich", text: "eins"), Line(speaker: "Ich", text: "zwei")]
        let result = await TranscriptRefinement.refine(
            lines: lines, vocabulary: [], title: nil,
            complete: { _, _ in Completion(text: "[1] Eins.", usage: nil) }
        )
        XCTAssertEqual(result.texts, ["Eins.", "zwei"])
        XCTAssertEqual(result.missing, 1)
    }

    /// Every chunk is answered with its own numbers, whatever order the
    /// parallel calls come back in.
    func testChunksComeBackInPlace() async {
        let lines = (1...7).map { Line(speaker: "Ich", text: "zeile nummer \($0)") }
        let result = await TranscriptRefinement.refine(
            lines: lines, vocabulary: [], title: nil, wordsPerChunk: 6,
            complete: model { "Z" + $0.dropFirst() }
        )
        XCTAssertEqual(result.chunks, 4)
        XCTAssertEqual(result.texts, (1...7).map { "Zeile nummer \($0)" })
        XCTAssertEqual(result.usages.count, 4)
    }
}
