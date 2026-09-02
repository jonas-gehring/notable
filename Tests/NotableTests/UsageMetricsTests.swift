import XCTest

/// Pure tests for the Spec 01 statistics core. No DB, no clock: every `Date` is built
/// from explicit `DateComponents` via a fixed Europe/Berlin, Monday-first calendar, so
/// bucketing (incl. DST and year boundaries) is exercised deterministically.
final class UsageMetricsTests: XCTestCase {

    // MARK: - Fixtures

    /// Gregorian, Europe/Berlin, week starts Monday (firstWeekday == 2) — the calendar
    /// the app uses for local buckets.
    private func berlinCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        c.firstWeekday = 2
        return c
    }

    /// Build a local wall-clock instant in the Berlin calendar. Never uses `Date()`.
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi; comps.second = 0
        guard let date = berlinCalendar().date(from: comps) else {
            fatalError("could not build date \(y)-\(mo)-\(d) \(h):\(mi)")
        }
        return date
    }

    private func dictation(_ start: Date, seconds: TimeInterval, words: Int) -> UsageRow {
        UsageRow(kind: .dictation, startedAt: start, endedAt: start.addingTimeInterval(seconds), wordCount: words)
    }

    private func meeting(_ start: Date, seconds: TimeInterval?) -> UsageRow {
        let end = seconds.map { start.addingTimeInterval($0) }
        return UsageRow(kind: .meeting, startedAt: start, endedAt: end, wordCount: nil)
    }

    // MARK: - wordCount

    func testWordCountEmptyIsZero() {
        XCTAssertEqual(UsageMetrics.wordCount(""), 0)
        XCTAssertEqual(UsageMetrics.wordCount("   \n\t "), 0)
    }

    func testWordCountSimple() {
        XCTAssertEqual(UsageMetrics.wordCount("hallo welt"), 2)
    }

    func testWordCountCollapsesRepeatedAndMixedWhitespace() {
        XCTAssertEqual(UsageMetrics.wordCount("hallo    welt"), 2)
        XCTAssertEqual(UsageMetrics.wordCount("eins\nzwei\tdrei"), 3)
        XCTAssertEqual(UsageMetrics.wordCount("  \t leading und trailing \n "), 3)
    }

    // MARK: - savedSeconds

    func testSavedSecondsNormalCaseAt40WPM() {
        // 100 words / 40 WPM = 2.5 min = 150 s typing; minus 30 s dictation = 120 s saved.
        XCTAssertEqual(UsageMetrics.savedSeconds(words: 100, dictationSeconds: 30, typingWPM: 40), 120, accuracy: 1e-9)
    }

    func testSavedSecondsFlooredAtZero() {
        // 40 words / 40 WPM = 60 s typing; dictation took 90 s → no time saved.
        XCTAssertEqual(UsageMetrics.savedSeconds(words: 40, dictationSeconds: 90, typingWPM: 40), 0, accuracy: 1e-9)
    }

    func testSavedSecondsNonPositiveWPMIsZero() {
        XCTAssertEqual(UsageMetrics.savedSeconds(words: 100, dictationSeconds: 10, typingWPM: 0), 0)
        XCTAssertEqual(UsageMetrics.savedSeconds(words: 100, dictationSeconds: 10, typingWPM: -5), 0)
    }

    // MARK: - totals

    func testTotalsMixesDictationAndMeetings() {
        let day = date(2025, 6, 2, 9)
        let rows: [UsageRow] = [
            dictation(day, seconds: 30, words: 100),   // saved 120
            dictation(day, seconds: 90, words: 40),    // saved 0
            meeting(day, seconds: 3600),               // counts, 3600 s
            meeting(day, seconds: nil)                 // counts, 0 s (no endedAt)
        ]

        let t = UsageMetrics.totals(rows, typingWPM: 40)

        XCTAssertEqual(t.dictationCount, 2)
        XCTAssertEqual(t.dictationWords, 140)
        XCTAssertEqual(t.dictationSeconds, 120, accuracy: 1e-9)
        XCTAssertEqual(t.savedSeconds, 120, accuracy: 1e-9)
        XCTAssertEqual(t.meetingCount, 2)
        XCTAssertEqual(t.meetingSeconds, 3600, accuracy: 1e-9)
    }

    // MARK: - buckets: day

    func testTwoRowsSameLocalDayShareOneDayBucket() {
        let rows = [
            dictation(date(2025, 6, 1, 9), seconds: 10, words: 10),
            dictation(date(2025, 6, 1, 18), seconds: 10, words: 20)
        ]
        let buckets = UsageMetrics.buckets(rows, by: .day, calendar: berlinCalendar(), typingWPM: 40)

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].id, date(2025, 6, 1, 0))
        XCTAssertEqual(buckets[0].dictationCount, 2)
        XCTAssertEqual(buckets[0].dictationWords, 30)
    }

    func testJustBeforeAndJustAfterMidnightAreSeparateDayBuckets() {
        let rows = [
            dictation(date(2025, 5, 31, 23, 55), seconds: 5, words: 5),
            dictation(date(2025, 6, 1, 0, 5), seconds: 5, words: 7)
        ]
        let buckets = UsageMetrics.buckets(rows, by: .day, calendar: berlinCalendar(), typingWPM: 40)

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].id, date(2025, 5, 31, 0))
        XCTAssertEqual(buckets[1].id, date(2025, 6, 1, 0))
        // Ascending by id.
        XCTAssertLessThan(buckets[0].id, buckets[1].id)
    }

    // MARK: - buckets: week (Monday start)

    func testWeekBucketStartsOnMonday() {
        // 2025-06-01 is a Sunday, 2025-06-02 a Monday; the week Mon 02 – Sun 08 is one bucket.
        let rows = [
            meeting(date(2025, 6, 2, 8), seconds: 60),   // Monday
            meeting(date(2025, 6, 4, 8), seconds: 60),   // Wednesday
            meeting(date(2025, 6, 8, 23), seconds: 60)   // Sunday
        ]
        let buckets = UsageMetrics.buckets(rows, by: .week, calendar: berlinCalendar(), typingWPM: 40)

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].id, date(2025, 6, 2, 0), "week bucket must start on Monday")
        XCTAssertEqual(buckets[0].meetingCount, 3)
    }

    func testSundayAndFollowingMondayAreDifferentWeeks() {
        let rows = [
            meeting(date(2025, 6, 1, 12), seconds: 60),  // Sunday → week of Mon May 26
            meeting(date(2025, 6, 2, 12), seconds: 60)   // Monday → week of Mon Jun 2
        ]
        let buckets = UsageMetrics.buckets(rows, by: .week, calendar: berlinCalendar(), typingWPM: 40)

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].id, date(2025, 5, 26, 0))
        XCTAssertEqual(buckets[1].id, date(2025, 6, 2, 0))
    }

    // MARK: - buckets: month

    func testMonthBucketsSplitAcrossMonths() {
        let rows = [
            dictation(date(2025, 6, 3, 9), seconds: 10, words: 10),
            dictation(date(2025, 6, 20, 9), seconds: 10, words: 10),
            dictation(date(2025, 7, 1, 9), seconds: 10, words: 10)
        ]
        let buckets = UsageMetrics.buckets(rows, by: .month, calendar: berlinCalendar(), typingWPM: 40)

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].id, date(2025, 6, 1, 0))
        XCTAssertEqual(buckets[0].dictationCount, 2)
        XCTAssertEqual(buckets[1].id, date(2025, 7, 1, 0))
        XCTAssertEqual(buckets[1].dictationCount, 1)
    }

    // MARK: - buckets: DST day

    func testDSTSpringForwardDayGroupsCorrectly() {
        // 2025-03-30: Europe/Berlin springs forward (02:00 → 03:00), a 23-hour day.
        // A row at 10:00 local must land in the day bucket starting 2025-03-30 00:00 local.
        let rows = [
            dictation(date(2025, 3, 30, 10), seconds: 20, words: 30),
            dictation(date(2025, 3, 30, 20), seconds: 20, words: 30)
        ]
        let buckets = UsageMetrics.buckets(rows, by: .day, calendar: berlinCalendar(), typingWPM: 40)

        XCTAssertEqual(buckets.count, 1, "a DST-transition day is still one local day bucket")
        XCTAssertEqual(buckets[0].id, date(2025, 3, 30, 0))
        XCTAssertEqual(buckets[0].dictationCount, 2)
    }

    // MARK: - buckets: year boundary

    // MARK: - contiguous (chart series)

    func testContiguousZeroFillsQuietPeriodsAndEndsAtNow() {
        let rows = [dictation(date(2025, 6, 1, 9), seconds: 10, words: 40)]
        let buckets = UsageMetrics.buckets(rows, by: .day, calendar: berlinCalendar(), typingWPM: 40)

        let series = UsageMetrics.contiguous(
            buckets, by: .day, calendar: berlinCalendar(), endingAt: date(2025, 6, 4, 15), count: 5)

        XCTAssertEqual(series.map(\.id), [
            date(2025, 5, 31, 0), date(2025, 6, 1, 0), date(2025, 6, 2, 0),
            date(2025, 6, 3, 0), date(2025, 6, 4, 0)
        ], "exactly `count` consecutive days, ending with the day containing `endingAt`")
        XCTAssertEqual(series.map(\.dictationWords), [0, 40, 0, 0, 0])
    }

    func testContiguousTrimsPeriodsOlderThanTheWindow() {
        let rows = [
            dictation(date(2025, 1, 6, 9), seconds: 10, words: 10),   // week of Jan 6 — outside
            dictation(date(2025, 6, 2, 9), seconds: 10, words: 20)    // week of Jun 2 — inside
        ]
        let buckets = UsageMetrics.buckets(rows, by: .week, calendar: berlinCalendar(), typingWPM: 40)

        let series = UsageMetrics.contiguous(
            buckets, by: .week, calendar: berlinCalendar(), endingAt: date(2025, 6, 5, 12), count: 3)

        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(series.map(\.id), [date(2025, 5, 19, 0), date(2025, 5, 26, 0), date(2025, 6, 2, 0)])
        XCTAssertEqual(series.map(\.dictationWords), [0, 0, 20], "the January week is outside the window")
    }

    func testContiguousSpansAYearBoundaryByMonth() {
        let series = UsageMetrics.contiguous(
            [], by: .month, calendar: berlinCalendar(), endingAt: date(2025, 2, 10, 8), count: 4)

        XCTAssertEqual(series.map(\.id), [
            date(2024, 11, 1, 0), date(2024, 12, 1, 0), date(2025, 1, 1, 0), date(2025, 2, 1, 0)
        ])
    }

    func testContiguousWithNonPositiveCountIsEmpty() {
        XCTAssertTrue(UsageMetrics.contiguous(
            [], by: .day, calendar: berlinCalendar(), endingAt: date(2025, 6, 1), count: 0).isEmpty)
    }

    // MARK: - delta

    func testDeltaIsRelativeChange() {
        XCTAssertEqual(UsageMetrics.delta(current: 125, previous: 100)!, 0.25, accuracy: 1e-9)
        XCTAssertEqual(UsageMetrics.delta(current: 50, previous: 100)!, -0.5, accuracy: 1e-9)
        XCTAssertEqual(UsageMetrics.delta(current: 100, previous: 100)!, 0, accuracy: 1e-9)
    }

    func testDeltaWithoutBaselineIsNil() {
        XCTAssertNil(UsageMetrics.delta(current: 42, previous: 0), "no baseline → no percentage worth showing")
        XCTAssertNil(UsageMetrics.delta(current: 0, previous: 0))
    }

    // MARK: - buckets: year boundary

    func testYearBoundarySplitsDec31FromJan1() {
        let rows = [
            dictation(date(2024, 12, 31, 23), seconds: 10, words: 10),
            dictation(date(2025, 1, 1, 1), seconds: 10, words: 10)
        ]
        let buckets = UsageMetrics.buckets(rows, by: .year, calendar: berlinCalendar(), typingWPM: 40)

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].id, date(2024, 1, 1, 0))
        XCTAssertEqual(buckets[1].id, date(2025, 1, 1, 0))
    }

    // MARK: - LLM spend

    private func llm(_ at: Date, tokens: Int, cost: Double, billed: Bool) -> LLMUsageRow {
        LLMUsageRow(at: at, tokens: tokens, costUSD: cost, billed: billed)
    }

    /// Billed and flat-rate spend must never end up in one number: the flat-rate
    /// figure is what the call *would* have cost, not money that was paid.
    func testLLMTotalsKeepBilledAndShadowCostApart() {
        let totals = UsageMetrics.llmTotals([
            llm(date(2026, 8, 31, 9), tokens: 1_000, cost: 0.30, billed: true),
            llm(date(2026, 8, 31, 10), tokens: 2_500, cost: 1.20, billed: false),
            llm(date(2026, 8, 31, 11), tokens: 500, cost: 0.10, billed: true),
        ])
        XCTAssertEqual(totals.calls, 3)
        XCTAssertEqual(totals.tokens, 4_000)
        XCTAssertEqual(totals.billedCostUSD, 0.40, accuracy: 0.0001)
        XCTAssertEqual(totals.shadowCostUSD, 1.20, accuracy: 0.0001)
    }

    func testLLMTotalsOfNoRowsIsEmpty() {
        let totals = UsageMetrics.llmTotals([])
        XCTAssertTrue(totals.isEmpty)
        XCTAssertEqual(totals.tokens, 0)
        XCTAssertEqual(totals.billedCostUSD, 0)
        XCTAssertEqual(totals.shadowCostUSD, 0)
    }

    /// A fraction of a cent is still spend — rounding it to `0,00 $` would read
    /// as free. The exact glyphs are locale-dependent, so only the rule is pinned.
    func testCurrencyNeverRoundsSpendToZero() {
        XCTAssertTrue(UsageMetrics.currency(0.0004).hasPrefix("< "))
        XCTAssertFalse(UsageMetrics.currency(0).hasPrefix("< "))
        XCTAssertFalse(UsageMetrics.currency(0.42).hasPrefix("< "))
    }

    /// Each kind of money carries its own label, and a kind that is zero is
    /// dropped rather than printed as `0,00 $`.
    func testCostLineLabelsEachKindOfMoney() {
        let both = UsageMetrics.llmCostLine(LLMTotals(calls: 2, tokens: 10, billedCostUSD: 0.4, shadowCostUSD: 1.2))
        XCTAssertTrue(both.contains("berechnet"))
        XCTAssertTrue(both.contains("über Abo"))

        let flatRateOnly = UsageMetrics.llmCostLine(LLMTotals(calls: 1, tokens: 10, billedCostUSD: 0, shadowCostUSD: 1.2))
        XCTAssertTrue(flatRateOnly.contains("über Abo"))
        XCTAssertFalse(flatRateOnly.contains("berechnet"))

        XCTAssertEqual(UsageMetrics.llmCostLine(LLMTotals()), "")
    }
}
