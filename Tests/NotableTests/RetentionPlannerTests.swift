import XCTest
@testable import Notable

/// Issue #2. The planner decides what gets destroyed, so the tests are mostly
/// about restraint: nothing configured deletes nothing, and the budget rule stops
/// the moment it is under budget.
final class RetentionPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_756_700_000)  // 2026-09-01

    private func session(daysAgo: Double, gigabytes: Double = 1, name: String = UUID().uuidString) -> RetentionPlanner.Session {
        RetentionPlanner.Session(
            url: URL(fileURLWithPath: "/tmp/spool-archive/\(name)"),
            startedAt: now.addingTimeInterval(-daysAgo * 86_400),
            byteSize: Int64(gigabytes * 1024 * 1024 * 1024)
        )
    }

    private func plan(
        _ policy: RetentionPolicy,
        archive: [RetentionPlanner.Session] = [],
        failed: [RetentionPlanner.Session] = []
    ) -> RetentionPlanner.Plan {
        RetentionPlanner.plan(policy: policy, now: now, archive: archive, failed: failed)
    }

    // MARK: - The "do nothing" cases

    func testEmptyArchiveGivesEmptyPlan() {
        XCTAssertTrue(plan(.default).isEmpty)
    }

    /// The case that matters most: a user who never opened the settings loses
    /// nothing.
    func testPolicyFullyOffDeletesNothing() {
        let sessions = (1...20).map { session(daysAgo: Double($0) * 100, gigabytes: 5) }
        let result = plan(.off, archive: sessions, failed: sessions)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.reclaimedBytes, 0)
    }

    // MARK: - Age

    func testExactlyAtTheAgeLimitSurvives() {
        var policy = RetentionPolicy.off
        policy.audioMaxAgeDays = 30
        XCTAssertTrue(plan(policy, archive: [session(daysAgo: 30)]).removals.isEmpty)
        XCTAssertEqual(plan(policy, archive: [session(daysAgo: 30.5)]).removals.count, 1)
    }

    func testFailedSpoolsGetTheirOwnLongerGrace() {
        var policy = RetentionPolicy.off
        policy.audioMaxAgeDays = 30
        policy.failedMaxAgeDays = 90

        let old = session(daysAgo: 60)
        let result = plan(policy, archive: [old], failed: [old])
        XCTAssertEqual(result.removals.count, 1)
        XCTAssertEqual(result.removals.first?.klass, .archive)
    }

    // MARK: - Budget

    func testBudgetDeletesOldestFirstAndStopsAtTheLimit() {
        var policy = RetentionPolicy.off
        policy.audioBudgetBytes = 3 * 1024 * 1024 * 1024

        let oldest = session(daysAgo: 5, gigabytes: 2, name: "oldest")
        let middle = session(daysAgo: 3, gigabytes: 2, name: "middle")
        let newest = session(daysAgo: 1, gigabytes: 2, name: "newest")

        // 6 GB total: dropping the oldest leaves 4 GB, still over — so the next
        // oldest goes too, and the newest survives.
        let removals = plan(policy, archive: [newest, oldest, middle]).removals
        XCTAssertEqual(removals.map(\.url.lastPathComponent), ["oldest", "middle"])
    }

    func testBudgetDeletesUntilUnderTheLimitNotOneMore() {
        var policy = RetentionPolicy.off
        policy.audioBudgetBytes = 2 * 1024 * 1024 * 1024
        // s1 is the oldest (4 days), s4 the newest (1 day).
        let sessions = (1...4).map { session(daysAgo: Double(5 - $0), gigabytes: 1, name: "s\($0)") }
        // 4 GB total, budget 2 GB ⇒ the two oldest go, the two newest stay.
        let removals = plan(policy, archive: sessions).removals
        XCTAssertEqual(removals.map(\.url.lastPathComponent), ["s1", "s2"])
    }

    func testUnderBudgetDeletesNothing() {
        var policy = RetentionPolicy.off
        policy.audioBudgetBytes = 20 * 1024 * 1024 * 1024
        XCTAssertTrue(plan(policy, archive: [session(daysAgo: 1, gigabytes: 5)]).removals.isEmpty)
    }

    // MARK: - Both axes

    func testAgeAndBudgetAreAUnionWithEachSessionOnlyOnce() {
        var policy = RetentionPolicy.off
        policy.audioMaxAgeDays = 30
        policy.audioBudgetBytes = 3 * 1024 * 1024 * 1024

        let ancient = session(daysAgo: 100, gigabytes: 4, name: "ancient")
        let recentBig = session(daysAgo: 5, gigabytes: 4, name: "recentBig")
        let today = session(daysAgo: 0, gigabytes: 1, name: "today")

        let removals = plan(policy, archive: [ancient, recentBig, today]).removals
        XCTAssertEqual(removals.count, 2)
        XCTAssertEqual(Set(removals.map(\.url)).count, 2, "keine URL doppelt")
        XCTAssertEqual(Set(removals.map(\.url.lastPathComponent)), ["ancient", "recentBig"])
        XCTAssertEqual(removals.first { $0.url.lastPathComponent == "ancient" }?.reason, .tooOld(days: 100))
        XCTAssertEqual(removals.first { $0.url.lastPathComponent == "recentBig" }?.reason, .overBudget)
    }

    /// The runaway session that started this issue: 6.4 GB in one folder, only
    /// four days old, so no age rule would ever reach it.
    func testTheRunawaySessionIsCaughtByTheBudgetAlone() {
        var policy = RetentionPolicy.default
        policy.audioBudgetBytes = 5 * 1024 * 1024 * 1024
        let runaway = session(daysAgo: 4, gigabytes: 6.4, name: "14-hours")
        XCTAssertEqual(plan(policy, archive: [runaway]).removals.first?.reason, .overBudget)
    }

    // MARK: - SQLite cut-offs

    func testTextCutoffsAreNilWhenTheRuleIsOff() {
        let result = plan(.default)
        XCTAssertNil(result.dictationTextBefore)
        XCTAssertNil(result.meetingTextBefore)
        XCTAssertNil(result.chatBefore)
    }

    func testTextCutoffIsTheAgeInThePast() throws {
        var policy = RetentionPolicy.off
        policy.dictationTextMaxAgeDays = 90
        let cutoff = try XCTUnwrap(plan(policy).dictationTextBefore)
        XCTAssertEqual(cutoff.timeIntervalSince1970, now.timeIntervalSince1970 - 90 * 86_400, accuracy: 1)
    }

    // MARK: - Policy loading

    func testZeroInDefaultsMeansOff() {
        let store = UserDefaults(suiteName: "RetentionTests.\(UUID().uuidString)")!
        store.set(0, forKey: RetentionPolicy.Key.audioAge)
        store.set(0, forKey: RetentionPolicy.Key.audioBudget)
        let policy = RetentionPolicy.fromDefaults(store)
        XCTAssertNil(policy.audioMaxAgeDays)
        XCTAssertNil(policy.audioBudgetBytes)
    }

    func testUnsetDefaultsFallBackToTheDefaultPolicy() {
        let store = UserDefaults(suiteName: "RetentionTests.\(UUID().uuidString)")!
        XCTAssertEqual(RetentionPolicy.fromDefaults(store), .default)
    }

    /// Automatic cleanup stays off until it is switched on explicitly.
    func testCleanupIsOffUntilExplicitlyEnabled() {
        let store = UserDefaults(suiteName: "RetentionTests.\(UUID().uuidString)")!
        XCTAssertFalse(RetentionPolicy.isEnabled(store))
        store.set(true, forKey: RetentionPolicy.Key.enabled)
        XCTAssertTrue(RetentionPolicy.isEnabled(store))
    }
}
