import XCTest

/// The one-line statistics summary shown in the menu-bar dropdown. Pure over a
/// `UsageTotals`, so every "what does the menu say" question is answered here
/// rather than by opening the menu.
final class MenuUsageLineTests: XCTestCase {
    private func totals(
        dictations: Int = 0,
        words: Int = 0,
        saved: TimeInterval = 0,
        meetings: Int = 0,
        meetingSeconds: TimeInterval = 0
    ) -> UsageTotals {
        UsageTotals(
            dictationCount: dictations,
            dictationWords: words,
            dictationSeconds: 0,
            savedSeconds: saved,
            meetingCount: meetings,
            meetingSeconds: meetingSeconds)
    }

    /// A menu row reading "Heute: 0 Wörter" is noise — the caller omits the line.
    func testQuietDayProducesNoLine() {
        XCTAssertNil(UsageMetrics.menuLine(totals(), label: "Heute"))
    }

    func testFullDayListsWordsMeetingsAndSavedTime() {
        let line = UsageMetrics.menuLine(
            totals(dictations: 12, words: 1240, saved: 2280, meetings: 2), label: "Heute")
        XCTAssertEqual(line, "Heute: \(UsageMetrics.integer(1240)) Wörter · 2 Meetings · 38 min gespart")
    }

    func testSingleMeetingIsNotPluralized() {
        let line = UsageMetrics.menuLine(totals(meetings: 1, meetingSeconds: 1800), label: "Heute")
        XCTAssertEqual(line, "Heute: 1 Meeting")
    }

    /// Below a minute the savings estimate is not worth stating, but the words
    /// that produced it still are.
    func testSavedTimeUnderAMinuteIsDropped() {
        let line = UsageMetrics.menuLine(totals(dictations: 1, words: 8, saved: 4), label: "Heute")
        XCTAssertEqual(line, "Heute: 8 Wörter")
    }

    /// A dictation that saved nothing and produced no counted words leaves the
    /// line empty rather than printing a bare "Heute:".
    func testDictationWithoutWordsOrSavingsProducesNoLine() {
        XCTAssertNil(UsageMetrics.menuLine(totals(dictations: 3), label: "Heute"))
    }

    func testLabelIsUsedVerbatim() {
        let line = UsageMetrics.menuLine(totals(words: 10), label: "Diese Woche")
        XCTAssertEqual(line, "Diese Woche: 10 Wörter")
    }

    // MARK: - duration formatting (shared with the statistics window)

    func testDurationPicksTheCoarsestMeaningfulUnit() {
        XCTAssertEqual(UsageMetrics.duration(12), "12 s")
        XCTAssertEqual(UsageMetrics.duration(2280), "38 min")
        XCTAssertEqual(UsageMetrics.duration(8040), "2 h 14 min")
    }
}
