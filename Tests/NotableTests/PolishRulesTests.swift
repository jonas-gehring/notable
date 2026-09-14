import XCTest
@testable import Notable

/// Spec 31: the rule-based polish, end to end through `TextPolisher.polish` —
/// sentence starts, German numbers, positional fillers, stutters.
final class PolishRulesTests: XCTestCase {
    private func options(_ languages: [String]) -> TextPolisher.Options {
        var options = TextPolisher.Options()
        options.spokenLanguages = languages
        return options
    }

    private var german: TextPolisher.Options { options(["de"]) }
    private var english: TextPolisher.Options { options(["en"]) }

    // MARK: - Sentence starts (§3.1)

    func testEverySentenceStartsWithACapital() {
        XCTAssertEqual(TextPolisher.polish("das ist gut. dann weiter", options: german), "Das ist gut. Dann weiter")
        XCTAssertEqual(TextPolisher.polish("ok? ja. passt!", options: german), "Ok? Ja. Passt!")
    }

    func testMixedCaseWordsAreLeftAlone() {
        XCTAssertEqual(TextPolisher.polish("iPhone ist gut. macOS auch", options: german), "iPhone ist gut. macOS auch")
    }

    /// A German ordinal is a digit and a period, not a sentence end.
    func testOrdinalsDoNotStartASentence() {
        XCTAssertEqual(TextPolisher.polish("vom 3. bis zum 5. geht es", options: german), "Vom 3. bis zum 5. geht es")
    }

    func testChatProfileKeepsLowercase() {
        var chat = german
        chat.capitalizeStart = false
        XCTAssertEqual(TextPolisher.polish("das ist gut. dann weiter", options: chat), "das ist gut. dann weiter")
    }

    // MARK: - German ITN (§3.2)

    func testGermanNumbersInThePolish() {
        XCTAssertEqual(
            TextPolisher.polish("Das kostet zweiundzwanzig Euro fünfzig.", options: german),
            "Das kostet 22,50\u{00A0}€."
        )
        XCTAssertEqual(TextPolisher.polish("Wir treffen uns um halb drei.", options: german), "Wir treffen uns um 2:30.")
    }

    func testGermanITNOnlyForGerman() {
        XCTAssertEqual(
            TextPolisher.polish("zweiundzwanzig", options: english),
            "Zweiundzwanzig",
            "Englisches Profil: kein deutsches ITN"
        )
    }

    func testITNSwitchTurnsGermanNumbersOff() {
        var off = german
        off.applyITN = false
        XCTAssertEqual(TextPolisher.polish("Wir waren zweiundzwanzig.", options: off), "Wir waren zweiundzwanzig.")
    }

    // MARK: - Fillers and stutters (§3.3)

    func testPositionalGermanFillers() {
        XCTAssertEqual(
            TextPolisher.polish("Also, ich denke, sozusagen, dass das geht", options: german),
            "Ich denke, dass das geht"
        )
    }

    func testFillerWordsInOrdinaryUseStay() {
        XCTAssertEqual(TextPolisher.polish("also ist es so.", options: german), "Also ist es so.")
        XCTAssertEqual(TextPolisher.polish("Das ist halt so.", options: german), "Das ist halt so.")
        XCTAssertEqual(TextPolisher.polish("Das ist sozusagen fertig.", options: german), "Das ist sozusagen fertig.")
        XCTAssertEqual(TextPolisher.polish("Wir halten das fest, halten wir fest.", options: german),
                       "Wir halten das fest, halten wir fest.")
    }

    func testFillerBeforeTheSentenceEnd() {
        XCTAssertEqual(TextPolisher.polish("Das war gut, quasi.", options: german), "Das war gut.")
    }

    func testStuttersAreRemoved() {
        XCTAssertEqual(TextPolisher.polish("ich ich habe das", options: german), "Ich habe das")
        XCTAssertEqual(TextPolisher.polish("Ich ich habe das", options: german), "Ich habe das")
        XCTAssertEqual(TextPolisher.polish("Ich weiß, dass dass es geht.", options: german), "Ich weiß, dass es geht.")
    }

    /// Repetition that is grammar or meaning must survive.
    func testRepetitionsThatMeanSomethingStay() {
        XCTAssertEqual(TextPolisher.polish("Das ist sehr sehr gut.", options: german), "Das ist sehr sehr gut.")
        XCTAssertEqual(TextPolisher.polish("Ja ja, schon gut.", options: german), "Ja ja, schon gut.")
        XCTAssertEqual(TextPolisher.polish("Leute, die die Regeln kennen.", options: german), "Leute, die die Regeln kennen.")
        XCTAssertEqual(TextPolisher.polish("Ich glaube, dass das das Beste ist.", options: german),
                       "Ich glaube, dass das das Beste ist.")
    }

    func testEnglishFillersAndStutters() {
        XCTAssertEqual(TextPolisher.polish("I I think, you know, it works.", options: english), "I think, it works.")
        XCTAssertEqual(TextPolisher.polish("I know that that works.", options: english), "I know that that works.")
    }

    func testVerbatimKeepsEverything() {
        var verbatim = german
        verbatim.verbatim = true
        XCTAssertEqual(TextPolisher.polish("also, ich ich zweiundzwanzig", options: verbatim), "also, ich ich zweiundzwanzig")
    }
}
