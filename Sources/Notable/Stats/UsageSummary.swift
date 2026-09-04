import Foundation

/// The single statistics line shown in the menu-bar dropdown.
///
/// The full picture lives in the `Statistik` window; this is the glance version
/// — today's numbers, right where the app already is. Aggregation is the same
/// pure `UsageMetrics` code the window uses, so the two can never disagree.
///
/// Refresh is push, not pull: a `.menu`-style `MenuBarExtra` builds real
/// `NSMenuItem`s, so a view in it has no reliable `onAppear` to fetch from
/// (same constraint that made `DictationHistory` refresh on save). The dictation
/// and meeting flows call `refreshSoon()` after they persist, plus once at
/// launch.
@MainActor
final class UsageSummary: ObservableObject {
    /// e.g. `Heute: 1.240 Wörter · 38 min gespart`, or `nil` on a quiet day.
    @Published private(set) var line: String?

    private let store: RecordingStore
    private let calendar: Calendar

    init(store: RecordingStore = .shared, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    /// Fire-and-forget refresh for call sites that are not already async.
    func refreshSoon() {
        Task { await refresh() }
    }

    /// Recomputes today's line. Best-effort: a read failure leaves the previous
    /// line standing rather than blanking the menu mid-day.
    func refresh(now: Date = Date()) async {
        guard let today = calendar.dateInterval(of: .day, for: now),
              let rows = try? await store.usageRows(from: today.start, to: today.end)
        else { return }

        let typingWPM = UserDefaults.standard.object(forKey: "typingWPM") as? Double ?? 40
        let totals = UsageMetrics.totals(rows.map(UsageRow.init), typingWPM: typingWPM)
        line = UsageMetrics.menuLine(totals, label: String(localized: "Heute"))
    }
}
