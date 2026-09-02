import Foundation

/// Pure, dependency-free computation core for Spec 01 — Nutzungsstatistiken.
///
/// Everything here takes its inputs explicitly (rows, a `Calendar`, the typing-speed
/// assumption) and never reads ambient state. In particular it **never** calls `Date()`
/// or `Date.now`: all "now"/bucket boundaries are derived from the passed-in `Calendar`
/// and the rows' own timestamps, so the numbers are deterministic and unit-testable
/// without a database or a clock.
///
/// The DB actor (`RecordingStore`) feeds raw `UsageRow`s in; this namespace turns them
/// into `UsageTotals` and per-period `UsageBucket`s. Kept intentionally separate from the
/// actor so buckets, savings and the WPM formula are testable in isolation (Spec §4).

/// What a usage row describes. Local mirror of `RecordingStore.Kind` — kept private to
/// this pure layer so `UsageMetrics` has no dependency on storage.
enum UsageKind: Sendable {
    case dictation
    case meeting
}

/// One recording, reduced to just the fields statistics need.
struct UsageRow: Sendable {
    let kind: UsageKind
    let startedAt: Date
    /// `nil` for a crashed/running recording — excluded from all duration sums.
    let endedAt: Date?
    /// Whitespace-token count of the polished text; `nil` if not (yet) computed.
    let wordCount: Int?
    /// Which transcriber produced this. `nil` for every row written before issue
    /// #5 and for meetings — treated as "unknown" and **reported as such**, never
    /// distributed over the known engines.
    var engine: String? = nil
    /// Whole-clip transcription latency in ms; `nil` where it was not measured.
    var latencyMs: Int? = nil
    /// Bundle ID of the app the text went into.
    var sourceApp: String? = nil

    /// Recording duration in seconds, or `nil` when `endedAt` is missing.
    /// Never negative (a clock skew flooring to 0).
    var duration: TimeInterval? {
        endedAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    }
}

/// One LLM round-trip, reduced to what statistics need. Local mirror of the
/// store's row for the same reason `UsageKind` is one: this layer stays pure.
struct LLMUsageRow: Sendable {
    let at: Date
    let tokens: Int
    /// USD for the call — spend only when `billed` is true.
    let costUSD: Double
    let billed: Bool
}

/// Aggregate LLM spend. **The two cost fields are never summed.** Billed cost
/// is money that left the account; shadow cost is what the flat-rate CLI
/// calls would have cost on the metered API. Adding them would report spend
/// that never happened, so they stay apart all the way to the label.
struct LLMTotals: Sendable, Equatable {
    var calls: Int = 0
    var tokens: Int = 0
    var billedCostUSD: Double = 0
    var shadowCostUSD: Double = 0

    var isEmpty: Bool { calls == 0 }
}

/// The calendar period a bucket spans. Boundaries are **local** (Spec §2.4): a week is
/// Monday–Sunday (per the calendar's `firstWeekday`), not a rolling 168-hour window.
enum Granularity: Sendable {
    case day
    case week
    case month
    case year
}

/// Lifetime (or windowed) aggregate over a set of rows.
struct UsageTotals: Sendable {
    var dictationCount: Int
    var dictationWords: Int
    var dictationSeconds: TimeInterval
    /// Estimated time saved vs. typing, summed per dictation (Spec §2.2). Floored at 0.
    var savedSeconds: TimeInterval
    var meetingCount: Int
    var meetingSeconds: TimeInterval
}

/// One calendar period's aggregate. `id` is the local period start (day/week/month/year),
/// making it directly usable as a chart x-value and `Identifiable` key.
struct UsageBucket: Sendable, Identifiable {
    /// Local start of the period this bucket covers (e.g. 00:00 local on the day).
    let id: Date
    let dictationWords: Int
    let dictationCount: Int
    let savedSeconds: TimeInterval
    let meetingCount: Int
    let meetingSeconds: TimeInterval
}

enum UsageMetrics {
    /// The `Calendar.Component` a granularity buckets by — also the step used to walk
    /// periods backwards (``contiguous(_:by:calendar:endingAt:count:)``) and the unit the
    /// charts bin their x-axis by, so the three can never drift apart.
    static func calendarComponent(_ granularity: Granularity) -> Calendar.Component {
        switch granularity {
        case .day:   .day
        case .week:  .weekOfYear
        case .month: .month
        case .year:  .year
        }
    }

    /// Number of whitespace-separated tokens (spaces, newlines, tabs). Empty tokens are
    /// ignored, so leading/trailing/repeated whitespace does not inflate the count.
    /// Correct for whitespace-delimited scripts (DE/EN); CJK would mis-count (Spec §7).
    static func wordCount(_ text: String) -> Int {
        text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }

    /// Seconds saved by dictating instead of typing `words`, given a typing speed
    /// (`typingWPM`) and how long the dictation actually took. Floored at 0 — a short
    /// dictation never "saves" negative time. Returns 0 for a non-positive WPM.
    static func savedSeconds(words: Int, dictationSeconds: TimeInterval, typingWPM: Double) -> TimeInterval {
        guard typingWPM > 0 else { return 0 }
        let typingSeconds = (Double(words) / typingWPM) * 60
        return max(0, typingSeconds - dictationSeconds)
    }

    /// Aggregate every row into a single lifetime total.
    ///
    /// - Dictation rows contribute count, words (`wordCount ?? 0`), seconds
    ///   (`duration ?? 0`) and per-row saved seconds.
    /// - Meeting rows contribute to `meetingCount` and `meetingSeconds`; a meeting with
    ///   no `endedAt` still counts but adds 0 seconds (Spec §7).
    static func totals(_ rows: [UsageRow], typingWPM: Double) -> UsageTotals {
        var totals = UsageTotals(
            dictationCount: 0,
            dictationWords: 0,
            dictationSeconds: 0,
            savedSeconds: 0,
            meetingCount: 0,
            meetingSeconds: 0
        )
        for row in rows {
            accumulate(row, into: &totals, typingWPM: typingWPM)
        }
        return totals
    }

    /// Group rows into local calendar buckets and aggregate each bucket like ``totals``.
    ///
    /// A row lands in the bucket whose period contains its `startedAt`, computed with the
    /// passed-in `calendar` (its `timeZone` and `firstWeekday` are respected). Bucket
    /// starts come from `calendar.dateInterval(of:for:)`, which handles DST-length days
    /// (23/25 h) correctly. Only periods with at least one row appear; the result is
    /// sorted ascending by `id`.
    static func buckets(
        _ rows: [UsageRow],
        by granularity: Granularity,
        calendar: Calendar,
        typingWPM: Double
    ) -> [UsageBucket] {
        var byStart: [Date: UsageTotals] = [:]
        for row in rows {
            guard let start = bucketStart(for: row.startedAt, granularity: granularity, calendar: calendar) else {
                continue
            }
            var totals = byStart[start] ?? UsageTotals(
                dictationCount: 0,
                dictationWords: 0,
                dictationSeconds: 0,
                savedSeconds: 0,
                meetingCount: 0,
                meetingSeconds: 0
            )
            accumulate(row, into: &totals, typingWPM: typingWPM)
            byStart[start] = totals
        }

        return byStart
            .sorted { $0.key < $1.key }
            .map { start, totals in
                UsageBucket(
                    id: start,
                    dictationWords: totals.dictationWords,
                    dictationCount: totals.dictationCount,
                    savedSeconds: totals.savedSeconds,
                    meetingCount: totals.meetingCount,
                    meetingSeconds: totals.meetingSeconds
                )
            }
    }

    /// Trim/pad ``buckets`` into a contiguous run of exactly `count` periods, ending with
    /// the period that contains `endingAt`. Periods without rows become zero buckets.
    ///
    /// ``buckets`` only contains periods that actually have rows, which makes a chart lie:
    /// a quiet week silently disappears and its neighbours become adjacent, so the x-axis
    /// stops being a time axis. Charts plot this instead. Still pure — "now" is passed in.
    static func contiguous(
        _ buckets: [UsageBucket],
        by granularity: Granularity,
        calendar: Calendar,
        endingAt: Date,
        count: Int
    ) -> [UsageBucket] {
        guard count > 0, let last = bucketStart(for: endingAt, granularity: granularity, calendar: calendar) else {
            return []
        }
        let component = calendarComponent(granularity)
        let byStart = Dictionary(buckets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return (0..<count).reversed().compactMap { stepsBack in
            guard let start = calendar.date(byAdding: component, value: -stepsBack, to: last) else { return nil }
            return byStart[start] ?? UsageBucket(
                id: start,
                dictationWords: 0,
                dictationCount: 0,
                savedSeconds: 0,
                meetingCount: 0,
                meetingSeconds: 0
            )
        }
    }

    /// Relative change from `previous` to `current`, e.g. `0.25` for +25 %.
    ///
    /// `nil` when there is no baseline to compare against (`previous <= 0`) — "+∞ %"
    /// against a zero week is not a statement worth putting on screen.
    static func delta(current: Double, previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous
    }

    /// Aggregate every LLM round-trip in the given rows.
    static func llmTotals(_ rows: [LLMUsageRow]) -> LLMTotals {
        var totals = LLMTotals()
        for row in rows {
            totals.calls += 1
            totals.tokens += row.tokens
            if row.billed {
                totals.billedCostUSD += row.costUSD
            } else {
                totals.shadowCostUSD += row.costUSD
            }
        }
        return totals
    }

    // MARK: - Formatting (shared by the stats window and the menu-bar line)

    /// Grouped integer, e.g. `1.240` in a German locale.
    static func integer(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// `2 h 14 min` / `38 min` / `12 s` — the coarsest unit that still says
    /// something. Used for every duration Notable shows.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) h \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total) s"
    }

    /// A USD amount, e.g. `0,42 $` in a German locale. Anything above zero but
    /// below a displayable cent reads `< 0,01 $` rather than `0,00 $`, which
    /// would claim a call was free.
    static func currency(_ usd: Double) -> String {
        if usd > 0 && usd < 0.005 {
            return "< " + 0.01.formatted(.currency(code: "USD"))
        }
        return usd.formatted(.currency(code: "USD"))
    }

    /// The cost line under the token count, phrased so the two kinds of money
    /// can never be read as one number: billed spend is stated as spend, the
    /// flat-rate figure only as what the API would have charged.
    static func llmCostLine(_ totals: LLMTotals) -> String {
        let billed = totals.billedCostUSD > 0 ? "\(currency(totals.billedCostUSD)) berechnet" : nil
        let shadow = totals.shadowCostUSD > 0 ? "\(currency(totals.shadowCostUSD)) über Abo" : nil
        return [billed, shadow].compactMap { $0 }.joined(separator: " · ")
    }

    /// The one-line summary shown directly in the menu-bar dropdown, e.g.
    /// `Heute: 1.240 Wörter · 2 Meetings · 38 min gespart`.
    ///
    /// Returns `nil` when there is nothing to report — a menu row reading
    /// "Heute: 0 Wörter" is noise, so the caller simply omits the line. Parts
    /// that would read as zero are dropped individually for the same reason, and
    /// saved time is only claimed once it reaches a full minute (below that the
    /// estimate is not worth stating).
    static func menuLine(_ totals: UsageTotals, label: String) -> String? {
        var parts: [String] = []
        if totals.dictationWords > 0 {
            parts.append("\(integer(totals.dictationWords)) Wörter")
        }
        if totals.meetingCount > 0 {
            parts.append(totals.meetingCount == 1 ? "1 Meeting" : "\(totals.meetingCount) Meetings")
        }
        if totals.savedSeconds >= 60 {
            parts.append("\(duration(totals.savedSeconds)) gespart")
        }
        guard !parts.isEmpty else { return nil }
        return "\(label): " + parts.joined(separator: " · ")
    }

    // MARK: - Private

    /// Fold one row into a running total (shared by ``totals`` and ``buckets``).
    private static func accumulate(_ row: UsageRow, into totals: inout UsageTotals, typingWPM: Double) {
        switch row.kind {
        case .dictation:
            let words = row.wordCount ?? 0
            let seconds = row.duration ?? 0
            totals.dictationCount += 1
            totals.dictationWords += words
            totals.dictationSeconds += seconds
            totals.savedSeconds += savedSeconds(words: words, dictationSeconds: seconds, typingWPM: typingWPM)
        case .meeting:
            totals.meetingCount += 1
            totals.meetingSeconds += row.duration ?? 0
        }
    }


    // MARK: - Detail analyses (issue #5)

    /// The bucket a row with no `engine`/`sourceApp` lands in. It is shown, never
    /// folded into a neighbour: six weeks of existing rows have no value here, and
    /// silently attributing them to the current engine would invent a measurement.
    static let unknownKey = "Unbekannt"

    static var zeroTotals: UsageTotals {
        UsageTotals(dictationCount: 0, dictationWords: 0, dictationSeconds: 0,
                    savedSeconds: 0, meetingCount: 0, meetingSeconds: 0)
    }

    /// Words per hour of day, 0…23.
    ///
    /// **A row counts entirely in the hour it started in.** A 20-minute meeting
    /// beginning at 23:50 is a Tuesday-23:00 event, not a smear across midnight.
    /// Spreading it would be more accurate and far less readable, and the question
    /// the chart answers is "when do you start working", so the start hour is the
    /// honest answer.
    static func hourHistogram(_ rows: [UsageRow], calendar: Calendar, typingWPM: Double = 40) -> [Int: UsageTotals] {
        var result: [Int: UsageTotals] = [:]
        for row in rows {
            let hour = calendar.component(.hour, from: row.startedAt)
            var totals = result[hour] ?? zeroTotals
            accumulate(row, into: &totals, typingWPM: typingWPM)
            result[hour] = totals
        }
        return result
    }

    /// 7 × 24, always fully populated (zero cells included — a heatmap with holes
    /// in it is unreadable). Row 0 is the calendar's `firstWeekday`, so a German
    /// calendar starts on Monday.
    static func weekdayHourMatrix(_ rows: [UsageRow], calendar: Calendar, typingWPM: Double = 40) -> [[UsageTotals]] {
        var matrix = Array(repeating: Array(repeating: zeroTotals, count: 24), count: 7)
        for row in rows {
            let weekday = calendar.component(.weekday, from: row.startedAt)
            let index = (weekday - calendar.firstWeekday + 7) % 7
            let hour = calendar.component(.hour, from: row.startedAt)
            accumulate(row, into: &matrix[index][hour], typingWPM: typingWPM)
        }
        return matrix
    }

    /// Words and counts per transcription engine, busiest first. Dictations only —
    /// a meeting has no engine of its own to report.
    static func engineTotals(_ rows: [UsageRow], typingWPM: Double = 40) -> [(engine: String, totals: UsageTotals)] {
        grouped(rows, typingWPM: typingWPM) { $0.engine }
            .map { (engine: $0.key, totals: $0.totals) }
    }

    /// Words and counts per target app (bundle ID), busiest first.
    static func appTotals(_ rows: [UsageRow], limit: Int = 5, typingWPM: Double = 40) -> [(sourceApp: String, totals: UsageTotals)] {
        let all = grouped(rows, typingWPM: typingWPM) { $0.sourceApp }
        guard limit > 0, all.count > limit else {
            return all.map { (sourceApp: $0.key, totals: $0.totals) }
        }
        // The tail is folded into one visible "Weitere" row rather than dropped,
        // so the parts still add up to the whole.
        var rest = zeroTotals
        for entry in all[limit...] {
            rest.dictationCount += entry.totals.dictationCount
            rest.dictationWords += entry.totals.dictationWords
            rest.dictationSeconds += entry.totals.dictationSeconds
            rest.savedSeconds += entry.totals.savedSeconds
        }
        return all[..<limit].map { (sourceApp: $0.key, totals: $0.totals) }
            + [(sourceApp: "Weitere", totals: rest)]
    }

    private static func grouped(
        _ rows: [UsageRow],
        typingWPM: Double,
        by key: (UsageRow) -> String?
    ) -> [(key: String, totals: UsageTotals)] {
        var result: [String: UsageTotals] = [:]
        for row in rows where row.kind == .dictation {
            let bucket = key(row) ?? unknownKey
            var totals = result[bucket] ?? zeroTotals
            accumulate(row, into: &totals, typingWPM: typingWPM)
            result[bucket] = totals
        }
        // Descending by words; the name breaks ties so the order never flickers
        // between two equally busy engines.
        return result
            .sorted {
                $0.value.dictationWords == $1.value.dictationWords
                    ? $0.key < $1.key
                    : $0.value.dictationWords > $1.value.dictationWords
            }
            .map { (key: $0.key, totals: $0.value) }
    }

    /// Median and 95th percentile latency, **never the mean**: one cold start
    /// (loading a model) shifts a mean by seconds and would make a fast engine
    /// look slow forever.
    struct LatencyStats: Sendable, Equatable {
        var p50: Double
        var p95: Double
        var count: Int
    }

    /// `nil` below `minimumSamples` measurements — a p95 over four numbers is not
    /// a p95, and the card says "zu wenig Daten" instead of a made-up figure.
    static let minimumLatencySamples = 10

    static func latency(_ rows: [UsageRow], by engine: String) -> LatencyStats? {
        let samples = rows
            .filter { $0.kind == .dictation && $0.engine == engine }
            .compactMap { $0.latencyMs.map(Double.init) }
            .sorted()
        guard samples.count >= minimumLatencySamples else { return nil }
        return LatencyStats(p50: percentile(samples, 0.5), p95: percentile(samples, 0.95), count: samples.count)
    }

    /// Nearest-rank percentile over an ascending array.
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    /// Spoken words per minute of recording — how fast the user talks, not how
    /// fast the model is. 0 when nothing has been recorded.
    static func wordsPerMinute(_ rows: [UsageRow]) -> Double {
        var words = 0
        var seconds: TimeInterval = 0
        for row in rows where row.kind == .dictation {
            words += row.wordCount ?? 0
            seconds += row.duration ?? 0
        }
        guard seconds > 0 else { return 0 }
        return Double(words) / (seconds / 60)
    }

    /// Consecutive days with activity, ending today.
    ///
    /// A day that has not happened yet does not break a streak: if today is still
    /// empty the count runs to yesterday, because the day is not over. An empty
    /// *yesterday* does break it — that day is done.
    static func streak(_ buckets: [UsageBucket], today: Date, calendar: Calendar) -> Int {
        let active = Set(buckets.filter { $0.dictationCount > 0 || $0.meetingCount > 0 }.map(\.id))
        guard let todayStart = calendar.dateInterval(of: .day, for: today)?.start else { return 0 }

        var cursor = todayStart
        if !active.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }
        var days = 0
        while active.contains(cursor) {
            days += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return days
    }

    /// Local start of the calendar period containing `date`, or `nil` if the calendar
    /// cannot resolve the interval (never expected for a valid calendar/date).
    private static func bucketStart(for date: Date, granularity: Granularity, calendar: Calendar) -> Date? {
        calendar.dateInterval(of: calendarComponent(granularity), for: date)?.start
    }
}
