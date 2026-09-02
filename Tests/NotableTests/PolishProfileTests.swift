import XCTest

/// Spec 03 — per-app polishing profiles and the new verbatim / final-punctuation /
/// casing options they drive.
final class PolishProfileTests: XCTestCase {
    func testCodeProfileIsVerbatim() {
        let options = PolishProfile.options(for: .code)
        XCTAssertTrue(options.verbatim)
    }

    func testMailProfileEnforcesPunctuationAndCasing() {
        let options = PolishProfile.options(for: .mail)
        XCTAssertTrue(options.enforceFinalPunctuation)
        XCTAssertTrue(options.capitalizeStart)
        XCTAssertFalse(options.verbatim)
    }

    func testChatProfileAllowsLowercaseStart() {
        let options = PolishProfile.options(for: .chat)
        XCTAssertFalse(options.capitalizeStart)
        XCTAssertFalse(options.enforceFinalPunctuation)
    }

    func testProseAndUnknownAreDefault() {
        for category in [AppCategory.prose, .unknown] {
            let options = PolishProfile.options(for: category)
            XCTAssertFalse(options.verbatim)
            XCTAssertTrue(options.capitalizeStart)
            XCTAssertFalse(options.enforceFinalPunctuation)
        }
    }

    // MARK: polish() behaviour driven by the new options

    func testVerbatimKeepsFillersNumbersAndCasing() {
        // English text so ITN/English fillers would normally fire — verbatim must not.
        let input = "um the total is two hundred dollars"
        let result = TextPolisher.polish(input, options: .init(verbatim: true))
        XCTAssertEqual(result, input) // untouched (trimmed only), no cap, no filler, no ITN
    }

    func testMailAddsFinalPeriodAndCapitalizes() {
        let result = TextPolisher.polish(
            "hallo welt", options: .init(enforceFinalPunctuation: true))
        XCTAssertEqual(result, "Hallo welt.")
    }

    func testMailDoesNotDoublePunctuate() {
        let result = TextPolisher.polish(
            "hallo welt.", options: .init(enforceFinalPunctuation: true))
        XCTAssertEqual(result, "Hallo welt.")
    }

    func testChatKeepsLowercaseStartAndNoPeriod() {
        let result = TextPolisher.polish(
            "hallo welt", options: .init(capitalizeStart: false))
        XCTAssertEqual(result, "hallo welt")
    }

    func testDictionaryStillAppliesInVerbatim() {
        let result = TextPolisher.polish(
            "meeting mit hofmann", options: .init(dictionary: ["hofmann": "Hoffmann"], verbatim: true))
        XCTAssertEqual(result, "meeting mit Hoffmann")
    }
}
