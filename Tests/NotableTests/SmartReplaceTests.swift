import XCTest
@testable import Notable

/// Issue #4. An expansion writes whole paragraphs into someone else's app, so the
/// tests care most about the cases where it must *not* fire.
final class SmartReplaceTests: XCTestCase {
    private func item(
        _ trigger: String,
        _ replacement: String,
        caseSensitive: Bool = false,
        enabled: Bool = true
    ) -> SmartReplacement {
        SmartReplacement(
            trigger: trigger,
            replacement: replacement,
            caseSensitive: caseSensitive,
            enabled: enabled
        )
    }

    // MARK: - Matching

    func testMultiWordTriggerIsExpanded() {
        let items = [item("meine Adresse", "Musterweg 1\n12345 Berlin")]
        XCTAssertEqual(
            SmartReplace.apply(items, to: "Schick es an meine Adresse, bitte."),
            "Schick es an Musterweg 1\n12345 Berlin, bitte."
        )
    }

    /// The whole reason for the Unicode lookarounds: a trigger inside a longer word
    /// is not a trigger.
    func testPartialWordIsNotATrigger() {
        let items = [item("Adresse", "Musterweg 1")]
        let text = "Das Adressbuch und die Adressen bleiben."
        XCTAssertEqual(SmartReplace.apply(items, to: text), text)
    }

    func testUmlautTriggerMatchesAtWordBoundaries() {
        let items = [item("Grußformel", "Viele Grüße\nMax")]
        XCTAssertEqual(
            SmartReplace.apply(items, to: "Und dann Grußformel."),
            "Und dann Viele Grüße\nMax."
        )
    }

    func testLongestTriggerWins() {
        let items = [item("Adresse", "KURZ"), item("neue Adresse", "LANG")]
        XCTAssertEqual(SmartReplace.apply(items, to: "Meine neue Adresse ist da."), "Meine LANG ist da.")
        XCTAssertEqual(SmartReplace.apply(items, to: "Meine Adresse ist da."), "Meine KURZ ist da.")
    }

    func testCaseInsensitiveByDefaultAndSensitiveOnRequest() {
        XCTAssertEqual(SmartReplace.apply([item("adresse", "X")], to: "Die Adresse."), "Die X.")
        XCTAssertEqual(
            SmartReplace.apply([item("adresse", "X", caseSensitive: true)], to: "Die Adresse."),
            "Die Adresse."
        )
    }

    func testDisabledEntryDoesNothing() {
        let items = [item("Adresse", "X", enabled: false)]
        XCTAssertEqual(SmartReplace.apply(items, to: "Die Adresse."), "Die Adresse.")
    }

    /// A user must not be able to build a loop out of two innocent rows.
    func testExpansionIsNotRescanned() {
        let items = [item("Gruß", "Grußformel"), item("Grußformel", "Viele Grüße")]
        XCTAssertEqual(SmartReplace.apply(items, to: "Ein Gruß."), "Ein Grußformel.")
    }

    /// Two triggers in one sentence both fire — one pass is not one replacement.
    func testEveryOccurrenceInOnePass() {
        let items = [item("aa", "X"), item("bb", "Y")]
        XCTAssertEqual(SmartReplace.apply(items, to: "aa und bb und aa"), "X und Y und X")
    }

    func testWhitespaceTriggerIsNeverApplied() {
        XCTAssertEqual(SmartReplace.apply([item("   ", "X")], to: "Ein Satz."), "Ein Satz.")
        XCTAssertEqual(SmartReplace.apply([item("", "X")], to: "Ein Satz."), "Ein Satz.")
    }

    func testEmptyListLeavesTextIdentical() {
        XCTAssertEqual(SmartReplace.apply([], to: "Ein Satz."), "Ein Satz.")
    }

    func testReplacementIsInsertedLiterally() {
        // "$1" in the user's text must not act as a regex template.
        let items = [item("Preis", "$1.000 (Netto)")]
        XCTAssertEqual(SmartReplace.apply(items, to: "Der Preis."), "Der $1.000 (Netto).")
    }

    // MARK: - Placeholders

    func testPlaceholdersAreFilled() {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let date = calendar.date(from: components)!

        let result = SmartReplace.expanding("Am {datum}, einem {wochentag}.", now: date, locale: Locale(identifier: "de_DE"))
        XCTAssertTrue(result.contains("2026"), result)
        XCTAssertTrue(result.contains("September"), result)
        XCTAssertTrue(result.contains("Dienstag"), result)
        XCTAssertFalse(result.contains("{"), result)
    }

    func testUnknownBracesAreLeftAlone() {
        XCTAssertEqual(SmartReplace.expanding("Ein {foo} Ding."), "Ein {foo} Ding.")
    }

    // MARK: - Storage

    func testSaveRejectsEmptyTriggers() {
        let defaults = UserDefaults(suiteName: "SmartReplaceTests.\(UUID().uuidString)")!
        SmartReplace.save([item("gut", "X"), item("  ", "Y")], store: defaults)
        let loaded = SmartReplace.load(store: defaults)
        XCTAssertEqual(loaded.map(\.trigger), ["gut"])
    }

    func testCollisionsWithPersonalDictionary() {
        let colliding = item("Hoffmann", "Max Hoffmann")
        let clean = item("Adresse", "Musterweg 1")
        let found = SmartReplace.collisions([colliding, clean], dictionary: ["hoffmann": "Hoffmann"])
        XCTAssertEqual(found, [colliding.id])
    }

    // MARK: - Integration with polish()

    private func polishOptions(_ items: [SmartReplacement]) -> TextPolisher.Options {
        var options = TextPolisher.Options()
        options.applyFuzzyDictionary = false
        options.replacements = items
        return options
    }

    /// The change this spec makes to `tidy()`: line breaks from an expansion have to
    /// survive the whitespace collapse, or a multi-line block is not one.
    func testMultiLineExpansionSurvivesPolish() {
        let options = polishOptions([item("meine Adresse", "Max Mustermann\nMusterweg 1\n12345 Berlin")])
        let result = TextPolisher.polish("Das ist meine Adresse.", options: options)
        XCTAssertEqual(result, "Das ist Max Mustermann\nMusterweg 1\n12345 Berlin.")
    }

    /// A line the user wrote himself keeps its casing — otherwise a mail address on
    /// its own line comes back as "Max.mustermann@…".
    func testExpansionLinesAreNotRecapitalized() {
        let options = polishOptions([item("meine Mail", "Kontakt:\nmax.mustermann@example.de")])
        let result = TextPolisher.polish("Nimm meine Mail.", options: options)
        XCTAssertEqual(result, "Nimm Kontakt:\nmax.mustermann@example.de.")
    }

    /// Deliberate deviation from "verbatim means verbatim": a shorthand is an
    /// instruction, and in a terminal it is the whole point.
    func testExpansionsRunInVerbatimMode() {
        var options = polishOptions([item("Projektpfad", "~/Code/notable")])
        options.verbatim = true
        XCTAssertEqual(
            TextPolisher.polish("cd Projektpfad", options: options),
            "cd ~/Code/notable"
        )
    }

    /// The fuzzy dictionary never sees a trigger — it is gone before that pass runs.
    func testFuzzyDictionaryNeverTouchesATrigger() {
        var options = TextPolisher.Options()
        options.applyFuzzyDictionary = true
        options.dictionary = ["Adressen": "ADRESSEN"]

        // Without the expansion, "Adresse" is within fuzzy range of "Adressen".
        XCTAssertTrue(TextPolisher.polish("Die Adresse.", options: options).contains("ADRESSEN"))

        options.replacements = [item("Adresse", "Musterweg 1")]
        XCTAssertEqual(TextPolisher.polish("Die Adresse.", options: options), "Die Musterweg 1.")
    }

    /// An empty list must leave `polish()` byte-identical to before this feature.
    func testEmptyReplacementListDoesNotChangePolish() {
        var options = TextPolisher.Options()
        options.applyFuzzyDictionary = false
        let text = "Also ähm ich denke das passt so. Und noch ein Satz. Und ein dritter. Und ein vierter."
        XCTAssertEqual(
            TextPolisher.polish(text, options: options),
            TextPolisher.polish(text, options: polishOptions([]))
        )
    }
}
