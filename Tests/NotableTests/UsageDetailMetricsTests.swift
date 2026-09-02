import XCTest
@testable import Notable

/// Issue #5. The new analyses, plus the guard that the existing ones did not
/// change when `UsageRow` grew four fields.
final class UsageDetailMetricsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2 // Montag
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 8) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private func dictation(
        at start: Date,
        seconds: TimeInterval = 60,
        words: Int = 100,
        engine: String? = "parakeet-v3",
        latencyMs: Int? = nil,
        app: String? = nil
    ) -> UsageRow {
        UsageRow(
            kind: .dictation,
            startedAt: start,
            endedAt: start.addingTimeInterval(seconds),
            wordCount: words,
            engine: engine,
            latencyMs: latencyMs,
            sourceApp: app
        )
    }

    // MARK: - Peak hours

    /// The rule, stated and pinned: a row belongs to the hour it *started* in,
    /// even when it runs past midnight.
    func testRowCountsEntirelyInItsStartHour() {
        let row = dictation(at: date(4, 23, 50), seconds: 20 * 60)
        let histogram = UsageMetrics.hourHistogram([row], calendar: calendar)
        XCTAssertEqual(histogram[23]?.dictationCount, 1)
        XCTAssertNil(histogram[0], "nichts darf über Mitternacht verschmiert werden")
    }

    func testHourHistogramSumsMatchTheTotals() {
        let rows = (8...17).map { dictation(at: date(4, $0), words: $0 * 10) }
        let histogram = UsageMetrics.hourHistogram(rows, calendar: calendar)
        XCTAssertEqual(
            histogram.values.reduce(0) { $0 + $1.dictationWords },
            UsageMetrics.totals(rows, typingWPM: 40).dictationWords
        )
    }

    func testWeekdayMatrixIsAlwaysFullyPopulatedAndStartsOnMonday() {
        // 2026-08-03 is a Monday, 2026-08-09 the Sunday after it.
        let matrix = UsageMetrics.weekdayHourMatrix(
            [dictation(at: date(3, 9)), dictation(at: date(9, 14))],
            calendar: calendar
        )
        XCTAssertEqual(matrix.count, 7)
        XCTAssertTrue(matrix.allSatisfy { $0.count == 24 })
        XCTAssertEqual(matrix[0][9].dictationCount, 1, "Montag ist Zeile 0")
        XCTAssertEqual(matrix[6][14].dictationCount, 1, "Sonntag ist Zeile 6")
        XCTAssertEqual(matrix[3][3].dictationCount, 0, "leere Zellen existieren, sie sind nur leer")
    }

    // MARK: - Engines and apps

    func testUnknownEngineIsReportedNotDistributed() {
        let rows = [
            dictation(at: date(4, 9), words: 100, engine: "parakeet-v3"),
            dictation(at: date(4, 10), words: 50, engine: nil),
        ]
        let totals = UsageMetrics.engineTotals(rows)
        XCTAssertEqual(totals.map(\.engine), ["parakeet-v3", UsageMetrics.unknownKey])
        XCTAssertEqual(totals.first { $0.engine == UsageMetrics.unknownKey }?.totals.dictationWords, 50)
    }

    func testGroupsSumToTheWholeSoNothingIsLost() {
        let rows = [
            dictation(at: date(4, 9), words: 100, engine: "parakeet-v3", app: "com.apple.mail"),
            dictation(at: date(4, 10), words: 50, engine: "unified-en", app: nil),
            dictation(at: date(4, 11), words: 25, engine: nil, app: "com.tinyspeck.slackmacgap"),
        ]
        let total = UsageMetrics.totals(rows, typingWPM: 40).dictationWords
        XCTAssertEqual(UsageMetrics.engineTotals(rows).reduce(0) { $0 + $1.totals.dictationWords }, total)
        XCTAssertEqual(UsageMetrics.appTotals(rows).reduce(0) { $0 + $1.totals.dictationWords }, total)
    }

    /// The tail is folded into "Weitere", never dropped — otherwise the parts stop
    /// adding up to the whole.
    func testAppTotalsFoldTheTailIntoOneRow() {
        let rows = (1...8).map { dictation(at: date(4, $0), words: $0 * 10, app: "app.\($0)") }
        let totals = UsageMetrics.appTotals(rows, limit: 3)
        XCTAssertEqual(totals.count, 4)
        XCTAssertEqual(totals.last?.sourceApp, "Weitere")
        XCTAssertEqual(
            totals.reduce(0) { $0 + $1.totals.dictationWords },
            UsageMetrics.totals(rows, typingWPM: 40).dictationWords
        )
    }

    func testMeetingsAreNotCountedAsAnUnknownEngine() {
        let meeting = UsageRow(kind: .meeting, startedAt: date(4, 9), endedAt: date(4, 10), wordCount: 500)
        XCTAssertTrue(UsageMetrics.engineTotals([meeting]).isEmpty)
    }

    // MARK: - Latency

    func testLatencyUsesMedianAndP95NotTheMean() throws {
        // Nine fast runs and one 5-second cold start: the mean would be ~600 ms,
        // which describes none of them.
        let samples = Array(repeating: 100, count: 9) + [5000]
        let rows = samples.enumerated().map { index, ms in
            dictation(at: date(4, 9, index), latencyMs: ms)
        }
        let stats = try XCTUnwrap(UsageMetrics.latency(rows, by: "parakeet-v3"))
        XCTAssertEqual(stats.p50, 100)
        XCTAssertEqual(stats.p95, 5000)
        XCTAssertEqual(stats.count, 10)
    }

    func testLatencyIsNilBelowTenMeasurements() {
        let rows = (0..<9).map { dictation(at: date(4, 9, $0), latencyMs: 100) }
        XCTAssertNil(UsageMetrics.latency(rows, by: "parakeet-v3"))
    }

    func testRowsWithoutLatencyDoNotCount() {
        let measured = (0..<9).map { dictation(at: date(4, 9, $0), latencyMs: 120) }
        let unmeasured = (0..<20).map { dictation(at: date(5, 9, $0), latencyMs: nil) }
        XCTAssertNil(UsageMetrics.latency(measured + unmeasured, by: "parakeet-v3"))
    }

    func testLatencyIsPerEngine() {
        let fast = (0..<10).map { dictation(at: date(4, 9, $0), engine: "parakeet-v3", latencyMs: 100) }
        let slow = (0..<10).map { dictation(at: date(5, 9, $0), engine: "whisper-base", latencyMs: 900) }
        XCTAssertEqual(UsageMetrics.latency(fast + slow, by: "parakeet-v3")?.p50, 100)
        XCTAssertEqual(UsageMetrics.latency(fast + slow, by: "whisper-base")?.p50, 900)
    }

    func testWordsPerMinute() {
        // 100 words in 60 seconds.
        XCTAssertEqual(UsageMetrics.wordsPerMinute([dictation(at: date(4, 9), seconds: 60, words: 100)]), 100, accuracy: 0.01)
        XCTAssertEqual(UsageMetrics.wordsPerMinute([]), 0)
    }

    // MARK: - Streak

    private func day(_ d: Int, words: Int) -> UsageBucket {
        UsageBucket(
            id: calendar.startOfDay(for: date(d, 12)),
            dictationWords: words,
            dictationCount: words > 0 ? 1 : 0,
            savedSeconds: 0,
            meetingCount: 0,
            meetingSeconds: 0
        )
    }

    func testStreakCountsConsecutiveDays() {
        let buckets = [day(2, words: 10), day(3, words: 10), day(4, words: 10)]
        XCTAssertEqual(UsageMetrics.streak(buckets, today: date(4, 18), calendar: calendar), 3)
    }

    /// The day is not over yet — an empty today must not zero a long streak.
    func testEmptyTodayDoesNotBreakTheStreak() {
        let buckets = [day(2, words: 10), day(3, words: 10)]
        XCTAssertEqual(UsageMetrics.streak(buckets, today: date(4, 9), calendar: calendar), 2)
    }

    /// An empty yesterday does — that day is finished.
    func testEmptyYesterdayBreaksTheStreak() {
        let buckets = [day(1, words: 10), day(2, words: 10)]
        XCTAssertEqual(UsageMetrics.streak(buckets, today: date(4, 9), calendar: calendar), 0)
    }

    func testGapInTheMiddleStopsTheCount() {
        let buckets = [day(1, words: 10), day(3, words: 10), day(4, words: 10)]
        XCTAssertEqual(UsageMetrics.streak(buckets, today: date(4, 20), calendar: calendar), 2)
    }

    func testNoActivityIsNoStreak() {
        XCTAssertEqual(UsageMetrics.streak([], today: date(4, 12), calendar: calendar), 0)
        XCTAssertEqual(UsageMetrics.streak([day(4, words: 0)], today: date(4, 12), calendar: calendar), 0)
    }

    // MARK: - Regression

    /// The existing aggregates must not have noticed the four new fields.
    func testExistingTotalsAreUnchangedByTheNewColumns() {
        let bare = UsageRow(kind: .dictation, startedAt: date(4, 9), endedAt: date(4, 9, 1), wordCount: 100)
        let rich = dictation(at: date(4, 9), seconds: 60, words: 100, engine: "parakeet-v3", latencyMs: 250, app: "com.apple.mail")

        let a = UsageMetrics.totals([bare], typingWPM: 40)
        let b = UsageMetrics.totals([rich], typingWPM: 40)
        XCTAssertEqual(a.dictationWords, b.dictationWords)
        XCTAssertEqual(a.dictationSeconds, b.dictationSeconds)
        XCTAssertEqual(a.savedSeconds, b.savedSeconds)
        XCTAssertEqual(
            UsageMetrics.menuLine(a, label: "Heute"),
            UsageMetrics.menuLine(b, label: "Heute")
        )
    }
}
