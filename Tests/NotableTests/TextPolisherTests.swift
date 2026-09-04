import XCTest

final class TextPolisherTests: XCTestCase {
    func testRemovesGermanFillersButKeepsGermanWords() {
        let polished = TextPolisher.polish(
            "ähm das ist äh ein Test, um es kurz zu zeigen.",
            options: .init(removeFillers: true, applyITN: false)
        )
        XCTAssertFalse(polished.lowercased().contains("ähm"))
        XCTAssertFalse(polished.lowercased().contains("äh "))
        XCTAssertTrue(polished.contains("um es kurz zu zeigen"), "„um“ ist Deutsch und muss bleiben: \(polished)")
        XCTAssertTrue(polished.hasPrefix("Das"), "Satzanfang groß: \(polished)")
    }

    /// The filler pattern used to swallow a trailing `[,.]`, which cost the
    /// sentence boundary that `ParagraphFormatter` counts and that every
    /// "command after punctuation" rule downstream depends on.
    func testFillerRemovalKeepsSentenceFinalPunctuation() {
        let polished = TextPolisher.polish(
            "Das ist gut äh. Dann machen wir weiter.",
            options: .init(removeFillers: true, applyITN: false, paragraphs: false, structureCommands: false)
        )
        XCTAssertFalse(polished.lowercased().contains("äh"), polished)
        XCTAssertTrue(polished.contains("gut."), "Punkt hinter dem Füllwort muss bleiben: \(polished)")
        XCTAssertTrue(polished.contains("gut. Dann"), polished)
    }

    /// A comma is the filler's own punctuation and goes with it — the sentence
    /// had no comma there before the "ähm" was spoken.
    func testFillerRemovalTakesItsOwnComma() {
        let polished = TextPolisher.polish(
            "Wir treffen uns ähm, morgen früh.",
            options: .init(removeFillers: true, applyITN: false, paragraphs: false, structureCommands: false)
        )
        XCTAssertFalse(polished.contains("ähm"), polished)
        XCTAssertFalse(polished.contains(",,"), polished)
        XCTAssertTrue(polished.contains("uns morgen früh."), polished)
    }

    func testRemovesEnglishFillersInEnglishText() {
        let polished = TextPolisher.polish(
            "Um, I think this is uh really great and er quite useful for everyone here.",
            options: .init(removeFillers: true, applyITN: false)
        )
        XCTAssertFalse(polished.lowercased().contains("um,"))
        XCTAssertFalse(polished.lowercased().contains(" uh "))
        XCTAssertTrue(polished.contains("really great"))
    }

    func testDictionaryReplacesWholeWordsOnly() {
        let polished = TextPolisher.polish(
            "hanna sprach mit hannaford über hanna.",
            options: .init(removeFillers: false, applyITN: false, dictionary: ["hanna": "Hanna Weber"])
        )
        XCTAssertTrue(polished.contains("Hanna Weber sprach"))
        XCTAssertTrue(polished.contains("hannaford"), "Teilwörter dürfen nicht ersetzt werden: \(polished)")
        XCTAssertTrue(polished.contains("über Hanna Weber."))
    }

    func testTidyCollapsesWhitespaceAndPunctuationGaps() {
        let polished = TextPolisher.polish(
            "das  ist   ein Test , wirklich .",
            options: .init(removeFillers: false, applyITN: false)
        )
        XCTAssertEqual(polished, "Das ist ein Test, wirklich.")
    }

    func testITNIsSkippedForGermanText() {
        let polished = TextPolisher.polish(
            "das kostet zweihundert Euro und ist morgen fertig.",
            options: .init(removeFillers: false, applyITN: true)
        )
        XCTAssertTrue(polished.contains("zweihundert"), "Deutsche Zahlwörter dürfen nicht angefasst werden")
    }

    // MARK: - Pure-Swift English ITN

    /// Was skipped while FluidAudio's native ITN was unavailable; now covers the pure-Swift path.
    func testITNFormatsEnglishNumbersAndCurrency() {
        let polished = TextPolisher.polish(
            "the project costs two hundred fifty dollars in total this year.",
            options: .init(removeFillers: false, applyITN: true)
        )
        XCTAssertTrue(polished.contains("$250"), "ITN-Ausgabe: \(polished)")
    }

    func testITNCompoundCardinals() {
        XCTAssertEqual(itn("i counted twenty five sheep near the barn"), "I counted 25 sheep near the barn")
        XCTAssertEqual(itn("we processed one thousand two hundred items today"), "We processed 1200 items today")
    }

    func testITNLeavesBareSmallNumbersAsWords() {
        // Bare "one".."nine" are common prose and must not become digits.
        let polished = itn("i think that is a good one for the team")
        XCTAssertTrue(polished.contains("good one for"), "Bare 'one' darf nicht zu '1' werden: \(polished)")
    }

    func testITNOrdinals() {
        XCTAssertEqual(itn("take the third door on the left"), "Take the 3rd door on the left")
        XCTAssertEqual(itn("she came in twenty first place overall"), "She came in 21st place overall")
    }

    func testITNKeepsAFractionOrdinalAsWord() {
        // "a second" / "an eighth" read as fractions/nouns, not ordinals.
        let polished = itn("give me a second to think about it")
        XCTAssertTrue(polished.contains("a second to"), "„a second“ darf bleiben: \(polished)")
    }

    func testITNPercentAndPointDecimal() {
        XCTAssertEqual(itn("about fifty percent agreed with the plan"), "About 50% agreed with the plan")
        XCTAssertEqual(itn("the ratio is three point one four here"), "The ratio is 3.14 here")
    }

    func testITNCurrencyWithCents() {
        XCTAssertEqual(itn("it was five dollars and fifty cents total"), "It was $5.50 total")
    }

    func testITNTime() {
        XCTAssertEqual(itn("the call starts at two thirty pm sharp"), "The call starts at 2:30 p.m. sharp")
    }

    func testITNDate() {
        XCTAssertEqual(itn("the deadline is january fifth for everyone"), "The deadline is January 5 for everyone")
    }

    func testITNDoesNotMangleYearSequences() {
        // Adjacent number runs (year/sequence reads) are left alone rather than mis-joined.
        let polished = itn("i was born in nineteen eighty four in berlin")
        XCTAssertTrue(polished.contains("nineteen eighty four"), "Jahr darf nicht verstümmelt werden: \(polished)")
    }

    private func itn(_ text: String) -> String {
        TextPolisher.polish(text, options: .init(removeFillers: false, applyITN: true))
    }

    // MARK: - Fuzzy personal dictionary

    func testFuzzyDictionaryCorrectsNearMissSpelling() {
        // "hofmann" is edit-distance 1 from key "Hoffmann" (len 8 → score = 0.875 ≥ 0.85).
        let polished = TextPolisher.polish(
            "i met hofmann at the office yesterday.",
            options: .init(removeFillers: false, applyITN: false,
                           dictionary: ["Hoffmann": "Hoffmann GmbH"])
        )
        XCTAssertTrue(polished.contains("Hoffmann GmbH"), "Fuzzy-Korrektur fehlt: \(polished)")
    }

    func testFuzzyDictionaryStillHandlesExactMatch() {
        let polished = TextPolisher.polish(
            "the hoffmann report is ready.",
            options: .init(removeFillers: false, applyITN: false,
                           dictionary: ["Hoffmann": "Hoffmann GmbH"])
        )
        XCTAssertTrue(polished.contains("Hoffmann GmbH report"), "Exakte Ersetzung muss weiter greifen: \(polished)")
    }

    func testFuzzyDictionaryLeavesUnrelatedWordsAlone() {
        let polished = TextPolisher.polish(
            "the meeting about parking was long.",
            options: .init(removeFillers: false, applyITN: false,
                           dictionary: ["Hoffmann": "Hoffmann GmbH", "Kubernetes": "Kubernetes"])
        )
        XCTAssertTrue(polished.contains("meeting about parking"), "Unbeteiligte Wörter dürfen nicht angefasst werden: \(polished)")
    }

    func testFuzzyDictionaryIgnoresShortKeys() {
        // Short keys (< 4 chars) are too risky for fuzzy matching.
        let polished = TextPolisher.polish(
            "the jan report landed.",
            options: .init(removeFillers: false, applyITN: false, dictionary: ["Jon": "Jonathan"])
        )
        XCTAssertTrue(polished.contains("jan report"), "Kurze Schlüssel dürfen nicht fuzzy greifen: \(polished)")
    }

    func testFuzzyMatcherCanBeDisabled() {
        let polished = TextPolisher.polish(
            "i met gehrig at the office.",
            options: .init(removeFillers: false, applyITN: false, applyFuzzyDictionary: false,
                           dictionary: ["Hoffmann": "Hoffmann GmbH"])
        )
        XCTAssertTrue(polished.contains("gehrig"), "Ohne Fuzzy darf nichts korrigiert werden: \(polished)")
    }

    // MARK: - Auto-learn scaffolding (record-only)

    func testAutoLearnRecordsButDoesNotAutoApply() {
        let suiteName = "TextPolisherTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suiteName)!
        defer { store.removePersistentDomain(forName: suiteName) }

        PersonalDictionary.recordCorrection(heard: "kubernetis", corrected: "Kubernetes", store: store)
        XCTAssertTrue(PersonalDictionary.learnedSuggestions(store: store).isEmpty, "Ein einzelnes Vorkommen ergibt noch keinen Vorschlag")

        PersonalDictionary.recordCorrection(heard: "kubernetis", corrected: "Kubernetes", store: store)
        XCTAssertEqual(PersonalDictionary.learnedSuggestions(store: store)["kubernetis"], "Kubernetes")
    }

    // MARK: - ITN crash regression

    /// Regression: a month word as the final token made matchDate call
    /// ordinalValue(i+1) with i+1 == tokens.count, indexing past the end and
    /// crashing the whole transcription path (dictation + meeting pipeline).
    // MARK: - Review 2026-09-03

    /// `tidy` used to uppercase the first character unconditionally.
    func testCamelCaseFirstWordSurvivesCapitalization() {
        var options = TextPolisher.Options()
        options.applyITN = false
        XCTAssertEqual(TextPolisher.polish("iPhone ist gut", options: options), "iPhone ist gut")
        XCTAssertEqual(TextPolisher.polish("macOS läuft", options: options), "macOS läuft")
        // A genuinely lowercase opening still gets capitalized.
        XCTAssertEqual(TextPolisher.polish("das ist gut", options: options), "Das ist gut")
    }

    /// Sentence-final punctuation belongs to the sentence, not to the filler.
    func testFillerRemovalKeepsSentencePunctuation() {
        var options = TextPolisher.Options()
        options.applyITN = false
        XCTAssertEqual(
            TextPolisher.polish("Das ist gut äh. Dann weiter.", options: options),
            "Das ist gut. Dann weiter."
        )
        // Its own comma still goes with it.
        XCTAssertEqual(
            TextPolisher.polish("Das ist ähm, gut.", options: options),
            "Das ist gut."
        )
    }

    /// English ITN must not rewrite ordinal idioms into numbers.
    func testOrdinalIdiomsAreNotNumbered() {
        var options = TextPolisher.Options()
        options.spokenLanguages = ["en"]
        for phrase in [
            "first of all we should talk",
            "at first it looked fine",
            "she had second thoughts about it",
            "this is a third party service",
        ] {
            let polished = TextPolisher.polish(phrase, options: options)
            XCTAssertFalse(polished.contains("1st"), polished)
            XCTAssertFalse(polished.contains("2nd"), polished)
            XCTAssertFalse(polished.contains("3rd"), polished)
        }
    }

    /// A compound ordinal is a number in every context and stays converted.
    func testCompoundOrdinalStillBecomesANumber() {
        var options = TextPolisher.Options()
        options.spokenLanguages = ["en"]
        XCTAssertTrue(TextPolisher.polish("the twenty first attempt", options: options).contains("21st"))
    }

    /// The minimum key length has to be reachable: below 7 characters the
    /// similarity threshold rejects every single-edit match anyway.
    func testFuzzyMinimumKeyLengthMatchesTheSimilarityThreshold() {
        let shortest = FuzzyDictionary.minKeyLength
        let similarity = 1 - 1 / Double(shortest)
        XCTAssertGreaterThanOrEqual(similarity, FuzzyDictionary.threshold,
                                    "Ein Ein-Edit-Treffer der Mindestlänge muss die Schwelle erreichen können")
        let below = 1 - 1 / Double(shortest - 1)
        XCTAssertLessThan(below, FuzzyDictionary.threshold,
                          "Ein Zeichen kürzer darf die Schwelle nicht mehr erreichen — sonst ist die Konstante wirkungslos")
    }

    func testITNTrailingMonthDoesNotCrash() {
        XCTAssertEqual(EnglishITN.normalize("we meet in September"), "we meet in September")
        XCTAssertEqual(EnglishITN.normalize("September"), "September")
        XCTAssertEqual(EnglishITN.normalize("the workshop was postponed until the end of October"),
                       "the workshop was postponed until the end of October")
        // A complete date still normalizes.
        XCTAssertEqual(EnglishITN.normalize("the demo is october fifth"), "the demo is October 5")
    }
}
