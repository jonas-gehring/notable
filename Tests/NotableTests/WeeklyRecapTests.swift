import XCTest

/// Spec 37 §3.4. A rule about a clock that would otherwise only ever be
/// exercised by waiting for a Monday.
final class WeeklyRecapTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// 2026-09-14 is a Monday, 2026-09-13 the Sunday before it.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private func totals(words: Int, meetings: Int = 0, saved: TimeInterval = 0) -> UsageTotals {
        UsageTotals(
            dictationCount: words > 0 ? 1 : 0,
            dictationWords: words,
            dictationSeconds: 0,
            savedSeconds: saved,
            meetingCount: meetings,
            meetingSeconds: 0)
    }

    // MARK: - When

    func testMondayMorningIsDue() {
        XCTAssertTrue(WeeklyRecapRules.isDue(now: date(14, 8), lastPosted: nil, calendar: calendar))
        XCTAssertTrue(WeeklyRecapRules.isDue(now: date(14, 17), lastPosted: nil, calendar: calendar))
    }

    /// Not at night, and not on any other day. "First activity after 8:00" is
    /// the rule — no timer wakes anything up.
    func testBeforeEightAndOnOtherDaysItIsNot() {
        XCTAssertFalse(WeeklyRecapRules.isDue(now: date(14, 7, 59), lastPosted: nil, calendar: calendar))
        XCTAssertFalse(WeeklyRecapRules.isDue(now: date(15, 9), lastPosted: nil, calendar: calendar))
        XCTAssertFalse(WeeklyRecapRules.isDue(now: date(13, 9), lastPosted: nil, calendar: calendar))
    }

    /// The app restarts, and every dictation asks again. Once a week means once.
    func testNotTwiceInTheSameWeek() {
        XCTAssertFalse(WeeklyRecapRules.isDue(now: date(14, 9), lastPosted: date(14, 8, 5), calendar: calendar))
        XCTAssertFalse(WeeklyRecapRules.isDue(now: date(14, 20), lastPosted: date(14, 8, 5), calendar: calendar))
    }

    func testTheWeekAfterIsDueAgain() {
        XCTAssertTrue(WeeklyRecapRules.isDue(now: date(21, 8), lastPosted: date(14, 8, 5), calendar: calendar))
    }

    // MARK: - Whether it is worth saying

    /// A week without dictations does not need to be told that it had none.
    func testAQuietWeekGetsNoReview() {
        XCTAssertNil(WeeklyRecapRules.make(
            lastWeek: totals(words: 99), weekBefore: totals(words: 4_000), streak: 3))
    }

    func testTheNumbersAreTheOnesFromTheWindow() throws {
        let recap = try XCTUnwrap(WeeklyRecapRules.make(
            lastWeek: totals(words: 4_210, meetings: 3, saved: 4_320),
            weekBefore: totals(words: 3_568),
            streak: 9))
        XCTAssertEqual(recap.words, 4_210)
        XCTAssertEqual(recap.meetings, 3)
        XCTAssertEqual(recap.savedSeconds, 4_320)
        XCTAssertEqual(try XCTUnwrap(recap.deltaWords), 0.18, accuracy: 0.005)
        XCTAssertEqual(recap.streak, 9)
    }

    func testTheBodyNamesEveryPartThatHasSomethingToSay() throws {
        let recap = try XCTUnwrap(WeeklyRecapRules.make(
            lastWeek: totals(words: 4_210, meetings: 3, saved: 4_320),
            weekBefore: totals(words: 3_568),
            streak: 9))
        let body = recap.body
        XCTAssertTrue(body.contains(UsageMetrics.integer(4_210)), body)
        XCTAssertTrue(body.contains("3 Meetings"), body)
        XCTAssertTrue(body.contains("gespart"), body)
        XCTAssertTrue(body.contains("mehr als in der Vorwoche"), body)
        XCTAssertTrue(body.contains("Serie: 9 Tage."), body)
        XCTAssertFalse(recap.title.isEmpty)
    }

    /// Parts that would read as zero are dropped, exactly as in the menu line —
    /// "0 Meetings" in a weekly review is a reproach, not a number.
    func testZeroPartsAreLeftOut() throws {
        let recap = try XCTUnwrap(WeeklyRecapRules.make(
            lastWeek: totals(words: 500), weekBefore: totals(words: 0), streak: 1))
        XCTAssertFalse(recap.body.contains("Meeting"), recap.body)
        XCTAssertFalse(recap.body.contains("gespart"), recap.body)
        XCTAssertFalse(recap.body.contains("Serie"), "eine Serie von einem Tag ist keine")
        XCTAssertNil(recap.deltaWords, "ohne Vorwoche kein Prozentsatz")
    }

    func testFewerWordsThanTheWeekBeforeIsSaidPlainly() throws {
        let recap = try XCTUnwrap(WeeklyRecapRules.make(
            lastWeek: totals(words: 1_000), weekBefore: totals(words: 2_000), streak: 0))
        XCTAssertTrue(recap.body.contains("weniger als in der Vorwoche"), recap.body)
    }
}
