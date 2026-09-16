import XCTest

/// Spec 37 §3.3 — records, the longest streak there has ever been, the year as
/// a grid, and speaking against typing.
///
/// Every one of these is a number about the user rather than about the app, so
/// the rule they all obey is the same: it comes out of `recordings` or it does
/// not appear.
final class UsageRecordsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// 2026-09-14 is a Monday.
    private func date(_ day: Int, _ hour: Int = 9, month: Int = 9) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)!
    }

    private func dictation(
        _ day: Int,
        hour: Int = 9,
        month: Int = 9,
        seconds: TimeInterval = 30,
        words: Int = 100,
        latencyMs: Int? = nil
    ) -> UsageRow {
        let start = date(day, hour, month: month)
        return UsageRow(
            kind: .dictation,
            startedAt: start,
            endedAt: start.addingTimeInterval(seconds),
            wordCount: words,
            engine: "parakeet-v3",
            latencyMs: latencyMs)
    }

    private func days(_ rows: [UsageRow]) -> [UsageBucket] {
        UsageMetrics.buckets(rows, by: .day, calendar: calendar, typingWPM: 40)
    }

    // MARK: - Longest streak

    func testTheLongestStreakSurvivesABreak() {
        // 1–4 September (four days), then a gap, then 10–11.
        let rows = [1, 2, 3, 4, 10, 11].map { dictation($0) }
        let longest = UsageMetrics.longestStreak(days(rows), calendar: calendar)
        XCTAssertEqual(longest.days, 4)
        XCTAssertEqual(longest.endedAt, calendar.startOfDay(for: date(4)))
    }

    func testASingleDayIsAStreakOfOne() {
        XCTAssertEqual(UsageMetrics.longestStreak(days([dictation(3)]), calendar: calendar).days, 1)
    }

    func testNoActivityIsNoStreak() {
        let empty = UsageMetrics.longestStreak([], calendar: calendar)
        XCTAssertEqual(empty.days, 0)
        XCTAssertNil(empty.endedAt)
    }

    /// The current streak can be shorter than the best one — that is the whole
    /// reason the best one is kept.
    func testTheBestCanOutliveTheCurrentOne() {
        let rows = [1, 2, 3, 4, 5, 9].map { dictation($0) }
        XCTAssertEqual(UsageMetrics.streak(days(rows), today: date(9, 20), calendar: calendar), 1)
        XCTAssertEqual(UsageMetrics.longestStreak(days(rows), calendar: calendar).days, 5)
    }

    // MARK: - Records

    func testTheFiveRecordsComeOutOfTheRows() throws {
        var rows = [
            dictation(1, words: 100),
            dictation(2, words: 900),
            dictation(2, hour: 14, words: 200),
            dictation(3, words: 50),
        ]
        rows += (0 ..< 10).map { dictation(4, hour: $0 + 8, words: 40, latencyMs: 400 - $0 * 10) }

        let records = UsageMetrics.records(rows, calendar: calendar, typingWPM: 40)
        let byKind = Dictionary(uniqueKeysWithValues: records.map { ($0.kind, $0) })

        XCTAssertEqual(byKind[.longestDictation]?.value, 900)
        XCTAssertEqual(byKind[.longestDictation]?.at, date(2))
        XCTAssertEqual(byKind[.bestDay]?.value, 1_100, "900 + 200 am selben Tag")
        XCTAssertEqual(byKind[.bestDay]?.at, calendar.startOfDay(for: date(2)))
        XCTAssertNotNil(byKind[.bestWeek])
        XCTAssertEqual(byKind[.longestStreak]?.value, 4)
        XCTAssertEqual(byKind[.fastestDictation]?.value, 310)
    }

    /// The same rule as the latency card: under ten measured dictations there
    /// is no fastest one, because the number would describe a model load.
    func testTheFastestRecordNeedsTenMeasurements() {
        let rows = (0 ..< 9).map { dictation(4, hour: $0 + 8, words: 40, latencyMs: 200) }
        XCTAssertFalse(UsageMetrics.records(rows, calendar: calendar, typingWPM: 40)
            .contains { $0.kind == .fastestDictation })
    }

    /// A two-word dictation is a measurement of the clip, not of the engine.
    func testShortDictationsCannotSetTheSpeedRecord() {
        let short = (0 ..< 12).map { dictation(4, hour: $0 + 6, words: 3, latencyMs: 20) }
        let real = (0 ..< 12).map { dictation(5, hour: $0 + 6, words: 40, latencyMs: 300) }
        let records = UsageMetrics.records(short + real, calendar: calendar, typingWPM: 40)
        XCTAssertEqual(records.first { $0.kind == .fastestDictation }?.value, 300)
    }

    /// A row without the measurement is not guessed at — it simply does not
    /// take part.
    func testRowsWithoutLatencyAreNotCounted() {
        let rows = (0 ..< 20).map { dictation(4, hour: $0 % 12 + 6, words: 40, latencyMs: nil) }
        XCTAssertFalse(UsageMetrics.records(rows, calendar: calendar, typingWPM: 40)
            .contains { $0.kind == .fastestDictation })
    }

    func testNoRowsMeansNoRecords() {
        XCTAssertTrue(UsageMetrics.records([], calendar: calendar, typingWPM: 40).isEmpty)
    }

    /// "Neu" means: broken inside the period on screen. Outside it, the record
    /// stands without a band.
    func testOnlyRecordsInsideThePeriodAreNew() throws {
        let rows = [dictation(1, month: 8, words: 400), dictation(14, words: 900)]
        let week = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: date(16)))
        let records = UsageMetrics.records(rows, calendar: calendar, typingWPM: 40, newSince: week)

        let longest = try XCTUnwrap(records.first { $0.kind == .longestDictation })
        XCTAssertTrue(longest.isNew, "am Montag dieser Woche aufgestellt")

        let withoutPeriod = UsageMetrics.records(rows, calendar: calendar, typingWPM: 40)
        XCTAssertFalse(withoutPeriod.contains { $0.isNew }, "ohne Zeitraum ist nichts neu")
    }

    // MARK: - The year as a grid

    func testTheGridIsSevenRowsOfWeeks() {
        let grid = UsageMetrics.yearGrid(days([dictation(14)]), calendar: calendar, endingAt: date(16), weeks: 53)
        XCTAssertEqual(grid.count, 7)
        XCTAssertTrue(grid.allSatisfy { $0.count == 53 })
    }

    func testTheGridCarriesTheWordsOfItsDay() throws {
        let rows = [dictation(14, words: 321)]
        let grid = UsageMetrics.yearGrid(days(rows), calendar: calendar, endingAt: date(16), weeks: 4)
        let monday = try XCTUnwrap(grid.first?.last, "Zeile 0 ist Montag, Spalte n-1 diese Woche")
        XCTAssertEqual(monday.date, calendar.startOfDay(for: date(14)))
        XCTAssertEqual(monday.words, 321)
    }

    /// A day that has not happened yet is not a quiet day.
    func testDaysAfterTodayAreMarkedAsFuture() throws {
        let grid = UsageMetrics.yearGrid([], calendar: calendar, endingAt: date(16), weeks: 2)
        let thisWeek = grid.map { try? XCTUnwrap($0.last) }
        XCTAssertEqual(thisWeek.compactMap { $0?.inFuture }, [false, false, false, true, true, true, true])
    }

    func testAnEmptyGridIsStillAGrid() {
        let grid = UsageMetrics.yearGrid([], calendar: calendar, endingAt: date(16), weeks: 1)
        XCTAssertEqual(grid.count, 7)
        XCTAssertTrue(grid.flatMap { $0 }.allSatisfy { $0.words == 0 })
        XCTAssertTrue(UsageMetrics.yearGrid([], calendar: calendar, endingAt: date(16), weeks: 0).isEmpty)
    }

    // MARK: - Speaking against typing

    func testTheSpeedFactorIsSpokenAgainstTyped() throws {
        XCTAssertEqual(try XCTUnwrap(UsageMetrics.speedFactor(wordsPerMinute: 136, typingWPM: 40)), 3.4, accuracy: 0.001)
    }

    /// Without a measurement there is no factor — "1×" would be a claim.
    func testNoMeasurementMeansNoFactor() {
        XCTAssertNil(UsageMetrics.speedFactor(wordsPerMinute: 0, typingWPM: 40))
        XCTAssertNil(UsageMetrics.speedFactor(wordsPerMinute: 120, typingWPM: 0))
    }

    func testTypingSecondsIsTheOtherHalfOfEverySaving() {
        // 100 words at 40 WPM = 150 s.
        XCTAssertEqual(UsageMetrics.typingSeconds(words: 100, typingWPM: 40), 150, accuracy: 0.001)
        XCTAssertEqual(UsageMetrics.typingSeconds(words: 0, typingWPM: 40), 0)
        XCTAssertEqual(UsageMetrics.typingSeconds(words: 100, typingWPM: 0), 0)
        // And it agrees with what `savedSeconds` subtracts from.
        XCTAssertEqual(
            UsageMetrics.savedSeconds(words: 100, dictationSeconds: 30, typingWPM: 40),
            UsageMetrics.typingSeconds(words: 100, typingWPM: 40) - 30,
            accuracy: 0.001)
    }
}
