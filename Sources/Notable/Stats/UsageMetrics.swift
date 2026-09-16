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
    /// Which stage shaped a dictation's text last: "rules", "local", "cli"
    /// (Spec 32). `nil` for rows from before migration 6 — reported as unknown.
    var polisher: String? = nil
    /// How long the on-device stage took, where it ran.
    var polishMs: Int? = nil

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
///
/// `Equatable` since Spec 37: a chart that morphs instead of swapping its picture
/// needs `.animation(_:value:)`, and that takes an `Equatable` value.
struct UsageBucket: Sendable, Identifiable, Equatable {
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
        if hours > 0 { return String(localized: "\(hours) h \(minutes) min") }
        if minutes > 0 { return String(localized: "\(minutes) min") }
        return String(localized: "\(total) s")
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
        let billed = totals.billedCostUSD > 0
            ? String(localized: "\(currency(totals.billedCostUSD)) berechnet") : nil
        let shadow = totals.shadowCostUSD > 0
            ? String(localized: "\(currency(totals.shadowCostUSD)) über Abo") : nil
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
            parts.append(String(localized: "\(integer(totals.dictationWords)) Wörter"))
        }
        if totals.meetingCount > 0 {
            parts.append(totals.meetingCount == 1
                ? String(localized: "1 Meeting")
                : String(localized: "\(totals.meetingCount) Meetings"))
        }
        if totals.savedSeconds >= 60 {
            parts.append(String(localized: "\(duration(totals.savedSeconds)) gespart"))
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
    ///
    /// Localized at the point of display, not here: this value is also a
    /// *grouping key*, so it has to stay one stable string no matter what
    /// language the window is drawn in.
    static let unknownKey = "Unbekannt"

    /// How `unknownKey` and the "rest" bucket are written on screen.
    static func displayKey(_ key: String) -> String {
        switch key {
        case unknownKey: String(localized: "Unbekannt")
        case restKey: String(localized: "Weitere")
        default: key
        }
    }

    /// The bucket that collects everything past the top N.
    static let restKey = "Weitere"

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
            + [(sourceApp: restKey, totals: rest)]
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

    /// Dictations per text stage, in a fixed order — rules, local, CLI, unknown —
    /// so the card does not reshuffle as counts change. Stages with no dictation
    /// are left out (Spec 32 §3.7).
    static func polisherShares(_ rows: [UsageRow]) -> [(polisher: String, count: Int)] {
        var counts: [String: Int] = [:]
        for row in rows where row.kind == .dictation {
            counts[row.polisher ?? unknownKey, default: 0] += 1
        }
        return ["rules", "local", "command", "cli", unknownKey].compactMap { key in
            counts[key].map { (polisher: key, count: $0) }
        }
    }

    /// Median and p95 of the on-device stage, never the mean — one cold model
    /// load would move a mean by seconds (Spec 32 §3.8). `nil` below
    /// `minimumLatencySamples`.
    static func polishLatency(_ rows: [UsageRow]) -> LatencyStats? {
        let samples = rows
            .filter { $0.kind == .dictation && $0.polisher == "local" }
            .compactMap(\.polishMs)
            .map(Double.init)
            .sorted()
        guard samples.count >= minimumLatencySamples else { return nil }
        return LatencyStats(p50: percentile(samples, 0.5), p95: percentile(samples, 0.95), count: samples.count)
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

    /// The longest run of consecutive active days there has ever been, and the
    /// day it ended on.
    ///
    /// The sibling of ``streak(_:today:calendar:)``, which only knows the run
    /// that is still going. This one looks at every run, so a broken streak is
    /// not simply forgotten — that is the whole point of the record: "Bester:
    /// 23 Tage" survives the day the current one goes back to 1.
    static func longestStreak(_ buckets: [UsageBucket], calendar: Calendar) -> (days: Int, endedAt: Date?) {
        let active = buckets
            .filter { $0.dictationCount > 0 || $0.meetingCount > 0 }
            .map(\.id)
            .sorted()
        guard !active.isEmpty else { return (0, nil) }

        var best = 1
        var bestEnd = active[0]
        var run = 1
        for (previous, day) in zip(active, active.dropFirst()) {
            let next = calendar.date(byAdding: .day, value: 1, to: previous)
            run = next == day ? run + 1 : 1
            if run > best {
                best = run
                bestEnd = day
            }
        }
        return (best, bestEnd)
    }

    // MARK: - Records (Spec 37 §3.3)

    /// One personal best. **Never an estimate**: every value comes out of
    /// `recordings`, and a record whose measurement is missing (`latency_ms` on
    /// six weeks of rows) simply does not appear rather than being guessed from
    /// what is there.
    struct Record: Sendable, Equatable, Identifiable {
        enum Kind: String, Sendable, CaseIterable {
            case longestDictation
            case bestDay
            case bestWeek
            case longestStreak
            case fastestDictation
        }

        let kind: Kind
        /// Words, words, seconds saved, days, or milliseconds — per `kind`.
        let value: Int
        /// When it happened. The streak carries the day it ended on.
        let at: Date?
        /// Broken inside the period the window is currently showing.
        var isNew: Bool = false

        var id: String { kind.rawValue }
    }

    /// A dictation needs this many words before its latency says anything about
    /// the engine rather than about the length of the clip.
    static let fastestRecordMinimumWords = 10

    /// The five records, in display order. A record with nothing behind it is
    /// left out, so a fresh install shows an empty card instead of five zeros.
    ///
    /// `newSince` is the period the window is showing; a record whose date falls
    /// inside it is marked `isNew`.
    static func records(
        _ rows: [UsageRow],
        calendar: Calendar,
        typingWPM: Double,
        newSince: DateInterval? = nil
    ) -> [Record] {
        let dictations = rows.filter { $0.kind == .dictation }
        var found: [Record] = []

        if let longest = dictations
            .filter({ ($0.wordCount ?? 0) > 0 })
            .max(by: { ($0.wordCount ?? 0) < ($1.wordCount ?? 0) }) {
            found.append(Record(kind: .longestDictation, value: longest.wordCount ?? 0, at: longest.startedAt))
        }

        let days = buckets(rows, by: .day, calendar: calendar, typingWPM: typingWPM)
        if let best = days.filter({ $0.dictationWords > 0 }).max(by: { $0.dictationWords < $1.dictationWords }) {
            found.append(Record(kind: .bestDay, value: best.dictationWords, at: best.id))
        }

        let weeks = buckets(rows, by: .week, calendar: calendar, typingWPM: typingWPM)
        if let best = weeks.filter({ $0.savedSeconds >= 60 }).max(by: { $0.savedSeconds < $1.savedSeconds }) {
            found.append(Record(kind: .bestWeek, value: Int(best.savedSeconds.rounded()), at: best.id))
        }

        let streak = longestStreak(days, calendar: calendar)
        if streak.days > 1 {
            found.append(Record(kind: .longestStreak, value: streak.days, at: streak.endedAt))
        }

        // The same rule as the latency card, for the same reason: a single cold
        // model load is a measurement of the load, not of the dictation. Under
        // ten measured dictations the row is absent rather than wrong.
        let measured = dictations.filter {
            $0.latencyMs != nil && ($0.wordCount ?? 0) >= fastestRecordMinimumWords
        }
        if measured.count >= minimumLatencySamples,
           let fastest = measured.min(by: { ($0.latencyMs ?? .max) < ($1.latencyMs ?? .max) }) {
            found.append(Record(kind: .fastestDictation, value: fastest.latencyMs ?? 0, at: fastest.startedAt))
        }

        guard let newSince else { return found }
        return found.map { record in
            var marked = record
            marked.isNew = record.at.map(newSince.contains) ?? false
            return marked
        }
    }

    // MARK: - The year as a grid (Spec 37 §3.3)

    /// One day in the year grid.
    struct DayCell: Sendable, Equatable, Identifiable {
        /// Local start of the day.
        let date: Date
        let words: Int
        let count: Int
        /// A day that has not happened yet — drawn as nothing, not as a quiet day.
        let inFuture: Bool

        var id: Date { date }
    }

    /// 7 rows (row 0 = the calendar's first weekday) × `weeks` columns, ending
    /// with the week that contains `endingAt`. Always fully populated, like the
    /// heatmap: a grid with holes in it cannot be read as a calendar.
    static func yearGrid(
        _ buckets: [UsageBucket],
        calendar: Calendar,
        endingAt: Date,
        weeks: Int = 53
    ) -> [[DayCell]] {
        guard weeks > 0,
              let thisWeek = calendar.dateInterval(of: .weekOfYear, for: endingAt)?.start,
              let first = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)
        else { return [] }

        let byDay = Dictionary(buckets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let today = calendar.dateInterval(of: .day, for: endingAt)?.start ?? endingAt

        return (0 ..< 7).map { row in
            (0 ..< weeks).compactMap { column -> DayCell? in
                guard let day = calendar.date(byAdding: .day, value: column * 7 + row, to: first) else { return nil }
                let bucket = byDay[day]
                return DayCell(
                    date: day,
                    words: bucket?.dictationWords ?? 0,
                    count: (bucket?.dictationCount ?? 0) + (bucket?.meetingCount ?? 0),
                    inFuture: day > today
                )
            }
        }
    }

    // MARK: - Speaking against typing (Spec 37 §3.3)

    /// How many times faster dictating is than typing would have been, from two
    /// numbers that both already exist: the measured speaking rate and the
    /// typing speed the user set. `nil` when either side is missing — "1×" would
    /// be a claim, and a missing measurement is not one.
    static func speedFactor(wordsPerMinute spoken: Double, typingWPM: Double) -> Double? {
        guard spoken > 0, typingWPM > 0 else { return nil }
        return spoken / typingWPM
    }

    /// How long `words` would have taken to type. The other half of every
    /// "gespart" figure, said on its own for the onboarding sentence.
    static func typingSeconds(words: Int, typingWPM: Double) -> TimeInterval {
        guard typingWPM > 0, words > 0 else { return 0 }
        return (Double(words) / typingWPM) * 60
    }

    /// `3,4` in a German locale — one decimal, because the second one is noise
    /// at this size.
    static func factor(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    /// Local start of the calendar period containing `date`, or `nil` if the calendar
    /// cannot resolve the interval (never expected for a valid calendar/date).
    private static func bucketStart(for date: Date, granularity: Granularity, calendar: Calendar) -> Date? {
        calendar.dateInterval(of: calendarComponent(granularity), for: date)?.start
    }
}
