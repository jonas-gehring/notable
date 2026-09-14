import XCTest
@testable import Notable

/// Spec 32 Stufe 2: the context before the caret, and what counts as a
/// correction worth learning from (Spec 06 Quelle C).
final class TargetTextRulesTests: XCTestCase {
    // MARK: - Context

    func testNoContextAtTheStartOfAField() {
        XCTAssertNil(TargetTextRules.context(in: "Hallo", caret: 0))
        XCTAssertNil(TargetTextRules.context(in: "   ", caret: 3))
    }

    func testContextIsTheTextBeforeTheCaret() {
        XCTAssertEqual(TargetTextRules.context(in: "Hallo Anna, danke dir. Weiter", caret: 22), "Hallo Anna, danke dir.")
    }

    /// A cut in the middle of a word is dropped, so the model never sees "nna".
    func testContextStartsAtAWholeWord() {
        let value = "Liebe Anna, wie besprochen"
        XCTAssertEqual(TargetTextRules.context(in: value, caret: value.utf16.count, radius: 18), "wie besprochen")
    }

    func testCaretBeyondTheTextIsNoContext() {
        XCTAssertNil(TargetTextRules.context(in: "kurz", caret: 99))
    }

    // MARK: - Corrections

    func testASingleFixedWordIsLearned() {
        let pairs = TargetTextRules.corrections(
            pasted: "Wir treffen Herrn Hofmann morgen",
            fieldText: "Wir treffen Herrn Hoffmann morgen",
            start: 0
        )
        XCTAssertEqual(pairs.map(\.heard), ["Hofmann"])
        XCTAssertEqual(pairs.map(\.corrected), ["Hoffmann"])
    }

    func testTheStartOffsetIsInUTF16Units() {
        let before = "Grüße 👋 "
        let pairs = TargetTextRules.corrections(
            pasted: "bitte an Kolja schicken",
            fieldText: before + "bitte an Kolya schicken",
            start: before.utf16.count
        )
        XCTAssertEqual(pairs.map(\.corrected), ["Kolya"])
    }

    /// A rewrite says nothing about mishearing.
    func testARewriteIsNotLearned() {
        XCTAssertTrue(TargetTextRules.corrections(
            pasted: "Wir sehen uns morgen im Büro",
            fieldText: "Lass uns lieber Freitag telefonieren",
            start: 0
        ).isEmpty)
    }

    func testTooManySubstitutionsAreNotLearned() {
        XCTAssertTrue(TargetTextRules.corrections(
            pasted: "eins zwei drei vier fünf sechs",
            fieldText: "eins zwo drai fia fünf sechs",
            start: 0
        ).isEmpty)
    }

    func testShortTextsAreNotLearned() {
        XCTAssertTrue(TargetTextRules.corrections(pasted: "Hallo Kolja", fieldText: "Hallo Kolya", start: 0).isEmpty)
    }

    func testAChangedWordCountIsNotLearned() {
        XCTAssertTrue(TargetTextRules.corrections(
            pasted: "Wir treffen Herrn Hofmann",
            fieldText: "Wir",
            start: 0
        ).isEmpty)
    }

    func testAStartOutsideTheFieldIsHarmless() {
        XCTAssertTrue(TargetTextRules.corrections(pasted: "eins zwei drei", fieldText: "eins zwei drei", start: 40).isEmpty)
    }
}
