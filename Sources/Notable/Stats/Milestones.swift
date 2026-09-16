import Foundation

/// A threshold worth a moment, and the rule that it happens exactly once
/// (Spec 37 §3.5).
///
/// Counted out of `recordings`, never out of a counter of its own. That is
/// possible because of a decision taken long before this: retention clears
/// *text*, never rows (issue #2), so the numbers these thresholds are measured
/// against can only ever grow. A separate tally would have been a second truth
/// that drifts from the first.
struct Milestone: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable, CaseIterable {
        case words
        case dictations
        /// Whole **hours** saved — the threshold is in hours, not seconds.
        case saved
        case meetings
        /// Days in a row.
        case streak
    }

    let kind: Kind
    let threshold: Int

    /// Also the marker written into `UserDefaults` — so a renamed kind would
    /// re-celebrate everything, and therefore never gets renamed.
    var id: String { "\(kind.rawValue).\(threshold)" }

    /// What the HUD says instead of the word count.
    var title: String {
        let number = UsageMetrics.integer(threshold)
        switch kind {
        case .words: return String(localized: "\(number) Wörter diktiert")
        case .dictations: return String(localized: "\(number) Diktate")
        case .saved:
            return threshold == 1
                ? String(localized: "1 Stunde gespart")
                : String(localized: "\(number) Stunden gespart")
        case .meetings: return String(localized: "\(number) Meetings aufgezeichnet")
        case .streak: return String(localized: "\(number) Tage in Folge")
        }
    }
}

/// The five counts a milestone can be measured against, in one value so the
/// three functions below cannot drift apart in their parameter order.
struct MilestoneCounts: Sendable, Equatable {
    var words = 0
    var dictations = 0
    var savedSeconds: TimeInterval = 0
    var meetings = 0
    var streak = 0

    init(words: Int = 0, dictations: Int = 0, savedSeconds: TimeInterval = 0, meetings: Int = 0, streak: Int = 0) {
        self.words = words
        self.dictations = dictations
        self.savedSeconds = savedSeconds
        self.meetings = meetings
        self.streak = streak
    }

    init(totals: UsageTotals, streak: Int) {
        self.init(
            words: totals.dictationWords,
            dictations: totals.dictationCount,
            savedSeconds: totals.savedSeconds,
            meetings: totals.meetingCount,
            streak: streak
        )
    }

    /// The comparable number for a kind. Saved time is **floored** to whole
    /// hours: 59 minutes is not an hour, and rounding up would announce a
    /// milestone that has not happened.
    func value(for kind: Milestone.Kind) -> Int {
        switch kind {
        case .words: words
        case .dictations: dictations
        case .saved: Int(savedSeconds / 3600)
        case .meetings: meetings
        case .streak: streak
        }
    }
}

enum Milestones {
    /// The fixed list. Deliberately short and far apart — a threshold every
    /// other week is a notification, not a moment.
    static let all: [Milestone] = [
        Milestone(kind: .words, threshold: 1_000),
        Milestone(kind: .words, threshold: 10_000),
        Milestone(kind: .words, threshold: 50_000),
        Milestone(kind: .words, threshold: 100_000),
        Milestone(kind: .words, threshold: 500_000),
        Milestone(kind: .words, threshold: 1_000_000),
        Milestone(kind: .dictations, threshold: 100),
        Milestone(kind: .dictations, threshold: 1_000),
        Milestone(kind: .dictations, threshold: 10_000),
        Milestone(kind: .saved, threshold: 1),
        Milestone(kind: .saved, threshold: 10),
        Milestone(kind: .saved, threshold: 100),
        Milestone(kind: .meetings, threshold: 10),
        Milestone(kind: .meetings, threshold: 100),
        Milestone(kind: .streak, threshold: 7),
        Milestone(kind: .streak, threshold: 30),
        Milestone(kind: .streak, threshold: 100),
        Milestone(kind: .streak, threshold: 365),
    ]

    /// Every threshold the counts have passed, in the order of ``all``.
    static func reached(_ counts: MilestoneCounts) -> [Milestone] {
        all.filter { counts.value(for: $0.kind) >= $0.threshold }
    }

    /// What is passed but not yet marked.
    ///
    /// **The first launch after the update marks everything silently** — that is
    /// not a rule in here but in the caller, and the reason it exists is this
    /// function: without it, 234 dictations of history would produce a stack of
    /// celebrations on a Tuesday for thresholds crossed in July.
    static func newlyReached(_ counts: MilestoneCounts, marked: Set<String>) -> [Milestone] {
        reached(counts).filter { !marked.contains($0.id) }
    }

    /// The one to show when several fell at once: the largest step, because it
    /// is the one that took the longest to get to.
    static func headline(_ new: [Milestone]) -> Milestone? {
        new.max { $0.threshold < $1.threshold }
    }

    /// How far the next one is. The statistics card shows it as "noch 2.023 bis
    /// 10.000".
    struct Progress: Sendable, Equatable {
        let milestone: Milestone
        let current: Int
        var remaining: Int { max(0, milestone.threshold - current) }
        /// 0…1 — how much of the way is behind.
        var fraction: Double {
            guard milestone.threshold > 0 else { return 0 }
            return min(1, Double(current) / Double(milestone.threshold))
        }
    }

    /// The nearest unreached milestone, measured in *relative* distance: 2 000
    /// words short of 10 000 is nearer than 40 meetings short of 100, and the
    /// one the user is about to reach is the one worth naming.
    static func next(_ counts: MilestoneCounts) -> Progress? {
        all
            .filter { counts.value(for: $0.kind) < $0.threshold }
            .map { Progress(milestone: $0, current: counts.value(for: $0.kind)) }
            .min { left, right in
                let a = Double(left.remaining) / Double(max(1, left.milestone.threshold))
                let b = Double(right.remaining) / Double(max(1, right.milestone.threshold))
                return a == b ? left.milestone.threshold < right.milestone.threshold : a < b
            }
    }
}
