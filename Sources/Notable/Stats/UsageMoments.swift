import Foundation

/// The two things Notable says about itself over time: a milestone in the HUD
/// and one review a week (Spec 37 §3.4, §3.5).
///
/// It keeps the lifetime counts in memory rather than asking SQLite after every
/// dictation, for one reason: the milestone has to be known **at** the moment,
/// not a database round-trip later, or the ✓ would already be fading when the
/// answer arrives. The cache is seeded once at launch from `recordings` and then
/// only ever grows by exactly what was just saved — so it is the same number the
/// statistics window would compute, never an estimate.
///
/// The rules themselves are pure and tested (`Milestones`, `WeeklyRecapRules`);
/// this is the shell that holds the state and reaches for the store.
@MainActor
final class UsageMoments {
    static let shared = UsageMoments()

    private let store: RecordingStore
    private let calendar: Calendar
    private let defaults: UserDefaults

    /// Lifetime counts, as of the last launch plus everything since.
    private(set) var counts = MilestoneCounts()
    /// The thresholds already marked. Seeded from `UserDefaults`, or — on the
    /// first launch after the update — from the existing rows, silently.
    private var marked: Set<String> = []
    /// The day the streak currently runs to, so a dictation can extend it
    /// without recomputing every bucket.
    private var lastActiveDay: Date?
    /// Reached but not yet shown. The HUD is the place for it (§3.5), so a
    /// milestone crossed by a meeting waits for the next dictation instead of
    /// becoming a notification of its own.
    private var pending: Milestone?
    private var loaded = false

    init(store: RecordingStore = .shared, calendar: Calendar = .current, defaults: UserDefaults = .standard) {
        self.store = store
        self.calendar = calendar
        self.defaults = defaults
    }

    // MARK: - Launch

    /// Reads the history once, marks what is already passed, and posts the
    /// weekly review if this is the first activity of a Monday.
    func launch() async {
        await reload()
        await postRecapIfDue()
    }

    private func reload() async {
        let records = (try? await store.usageRows(from: .distantPast, to: Date())) ?? []
        let rows = records.map(UsageRow.init)
        let typingWPM = DefaultsKey.typingWPM.value(defaults)
        let totals = UsageMetrics.totals(rows, typingWPM: typingWPM)
        let days = UsageMetrics.buckets(rows, by: .day, calendar: calendar, typingWPM: typingWPM)
        counts = MilestoneCounts(
            totals: totals,
            streak: UsageMetrics.streak(days, today: Date(), calendar: calendar)
        )
        lastActiveDay = days
            .filter { $0.dictationCount > 0 || $0.meetingCount > 0 }
            .map(\.id)
            .max()

        // A missing key means this build has never counted: mark everything
        // already passed **without celebrating any of it**. Otherwise the first
        // dictation after the update announces 1 000 Wörter from July.
        if defaults.object(forKey: DefaultsKey.milestonesReached.key) == nil {
            marked = Set(Milestones.reached(counts).map(\.id))
            persistMarked()
        } else {
            marked = Set(DefaultsKey.milestonesReached.value(defaults))
        }
        loaded = true
    }

    // MARK: - After a dictation

    /// Folds one just-saved dictation into the counts and works out whether a
    /// threshold fell with it.
    ///
    /// Synchronous and cheap by design — it runs on the dictation task after the
    /// paste and after the save, and must not add a database read there.
    func dictationSaved(words: Int, seconds: TimeInterval, at: Date) {
        guard loaded else { return }
        counts.words += words
        counts.dictations += 1
        counts.savedSeconds += UsageMetrics.savedSeconds(
            words: words, dictationSeconds: seconds, typingWPM: DefaultsKey.typingWPM.value(defaults)
        )
        extendStreak(to: at)

        if let reached = Milestones.headline(Milestones.newlyReached(counts, marked: marked)) {
            pending = reached
        }
        Task { await postRecapIfDue() }
    }

    /// A day with a dictation in it continues the streak; a gap starts a new
    /// one. Same rule as `UsageMetrics.streak`, applied forwards.
    private func extendStreak(to date: Date) {
        guard let day = calendar.dateInterval(of: .day, for: date)?.start else { return }
        defer { lastActiveDay = max(day, lastActiveDay ?? day) }
        guard let last = lastActiveDay else {
            counts.streak = 1
            return
        }
        guard day > last else { return } // same day, or a retried older clip
        let yesterday = calendar.date(byAdding: .day, value: 1, to: last)
        counts.streak = yesterday == day ? counts.streak + 1 : 1
    }

    /// The milestone to show, marked as shown. Consuming it is what makes it
    /// happen once — the next dictation gets the word count again.
    func takeMilestone() -> String? {
        guard let milestone = pending else { return nil }
        pending = nil
        marked.insert(milestone.id)
        persistMarked()
        return milestone.title
    }

    /// What the statistics window puts under "Rekorde".
    func progress() -> Milestones.Progress? { Milestones.next(counts) }

    func reachedMilestones() -> [Milestone] { Milestones.all.filter { marked.contains($0.id) } }

    private func persistMarked() {
        defaults.set(Array(marked).sorted(), forKey: DefaultsKey.milestonesReached.key)
    }

    // MARK: - The weekly review

    /// Monday, from 8:00, once. The numbers are the week that **ended**, because
    /// on Monday morning the running week is empty.
    func postRecapIfDue(now: Date = Date()) async {
        guard DefaultsKey.weeklyRecap.value(defaults) else { return }
        let stamp = DefaultsKey.weeklyRecapLastPosted.value(defaults)
        let lastPosted = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        guard WeeklyRecapRules.isDue(now: now, lastPosted: lastPosted, calendar: calendar) else { return }

        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now),
              let lastWeekDay = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start),
              let lastWeek = calendar.dateInterval(of: .weekOfYear, for: lastWeekDay),
              let beforeDay = calendar.date(byAdding: .weekOfYear, value: -2, to: thisWeek.start),
              let weekBefore = calendar.dateInterval(of: .weekOfYear, for: beforeDay)
        else { return }

        let typingWPM = DefaultsKey.typingWPM.value(defaults)
        let recent = (try? await store.usageRows(from: weekBefore.start, to: thisWeek.start)) ?? []
        let rows = recent.map(UsageRow.init)
        let totals = { (interval: DateInterval) in
            UsageMetrics.totals(rows.filter { interval.contains($0.startedAt) }, typingWPM: typingWPM)
        }
        guard let recap = WeeklyRecapRules.make(
            lastWeek: totals(lastWeek),
            weekBefore: totals(weekBefore),
            streak: counts.streak
        ) else {
            // A quiet week gets no review — and no second attempt this week
            // either, so the question is not asked again at every dictation.
            defaults.set(now.timeIntervalSince1970, forKey: DefaultsKey.weeklyRecapLastPosted.key)
            return
        }
        guard NotificationCenterService.shared.postWeeklyRecap(recap) else { return }
        defaults.set(now.timeIntervalSince1970, forKey: DefaultsKey.weeklyRecapLastPosted.key)
    }
}
