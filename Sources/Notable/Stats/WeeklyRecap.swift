import Foundation

/// What Notable says once a week, unasked (Spec 37 §3.4).
///
/// The numbers are the ones the statistics window computes for "Woche" — the
/// same buckets, the same `delta`, no second data path. What is new here is only
/// *when* it is said and *whether* it is worth saying.
struct WeeklyRecap: Sendable, Equatable {
    let words: Int
    let meetings: Int
    let savedSeconds: TimeInterval
    /// Change against the week before, as a fraction; `nil` without a baseline.
    let deltaWords: Double?
    let streak: Int

    var title: String { String(localized: "Deine Woche mit Notable") }

    /// `4.210 Wörter · 3 Meetings · 1 h 12 min gespart — 18 % mehr als in der
    /// Vorwoche. Serie: 9 Tage.`
    ///
    /// Parts that would read as zero are dropped individually, exactly as in
    /// `UsageMetrics.menuLine`: "0 Meetings" in a weekly review is a reproach,
    /// not a number.
    var body: String {
        var parts = [String(localized: "\(UsageMetrics.integer(words)) Wörter")]
        if meetings > 0 {
            parts.append(meetings == 1
                ? String(localized: "1 Meeting")
                : String(localized: "\(meetings) Meetings"))
        }
        if savedSeconds >= 60 {
            parts.append(String(localized: "\(UsageMetrics.duration(savedSeconds)) gespart"))
        }
        var line = parts.joined(separator: " · ")
        if let deltaWords, abs(deltaWords) >= 0.01 {
            // Formatted as a value, not written as "\(n) %": a bare percent
            // sign inside a localized format string is a conversion specifier
            // nobody meant, and the locale puts the sign in its own place
            // anyway.
            let change = abs(deltaWords).formatted(.percent.precision(.fractionLength(0)))
            line += deltaWords > 0
                ? String(localized: " — \(change) mehr als in der Vorwoche.")
                : String(localized: " — \(change) weniger als in der Vorwoche.")
        } else {
            line += "."
        }
        if streak > 1 {
            line += " " + String(localized: "Serie: \(streak) Tage.")
        }
        return line
    }
}

/// When a recap is due, and whether there is one worth posting.
///
/// Pure on purpose: "Montag nach 8 Uhr, höchstens einmal je Woche" is a rule
/// about a clock, and a rule about a clock that is only ever exercised by
/// waiting for Monday is a rule nobody checks.
enum WeeklyRecapRules {
    /// Below this the week gets no review — a week without dictations does not
    /// need to be told that it had none.
    static let minimumWords = 100

    /// The hour it may first appear. Not a timer: a menu-bar app without a timer
    /// is the better menu-bar app, so this is asked at launch and after every
    /// dictation, and the first of those after 8:00 on a Monday wins.
    static let earliestHour = 8

    /// Monday, from 8:00, and not yet this week.
    ///
    /// The "not yet this week" test is deliberately against the calendar week
    /// rather than against 7×24 hours: the app restarts, and a recap posted at
    /// 8:05 must not come again at 9:00.
    static func isDue(now: Date, lastPosted: Date?, calendar: Calendar) -> Bool {
        guard calendar.component(.weekday, from: now) == 2 else { return false }
        guard calendar.component(.hour, from: now) >= earliestHour else { return false }
        guard let lastPosted else { return true }
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return true }
        return !week.contains(lastPosted)
    }

    /// The review of the week that just ended, against the one before it.
    ///
    /// **The week that ended, not the one that started an hour ago** — on Monday
    /// morning the running week is empty, and a review of it would be a review
    /// of nothing.
    static func make(lastWeek: UsageTotals, weekBefore: UsageTotals, streak: Int) -> WeeklyRecap? {
        guard lastWeek.dictationWords >= minimumWords else { return nil }
        return WeeklyRecap(
            words: lastWeek.dictationWords,
            meetings: lastWeek.meetingCount,
            savedSeconds: lastWeek.savedSeconds,
            deltaWords: UsageMetrics.delta(
                current: Double(lastWeek.dictationWords),
                previous: Double(weekBefore.dictationWords)
            ),
            streak: streak
        )
    }
}
