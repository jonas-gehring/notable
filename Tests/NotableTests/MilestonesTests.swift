import XCTest

/// Spec 37 §3.5. The thresholds, and the rule that each one happens once.
///
/// The failure this guards against is not a wrong number — it is a *repeated*
/// celebration, or a stack of them arriving at once on the first launch after
/// an update. Both are decided here, in the diff between what is passed and
/// what is marked.
final class MilestonesTests: XCTestCase {
    private func counts(
        words: Int = 0,
        dictations: Int = 0,
        savedSeconds: TimeInterval = 0,
        meetings: Int = 0,
        streak: Int = 0
    ) -> MilestoneCounts {
        MilestoneCounts(
            words: words, dictations: dictations, savedSeconds: savedSeconds,
            meetings: meetings, streak: streak)
    }

    // MARK: - Reaching

    func testNothingIsReachedAtZero() {
        XCTAssertTrue(Milestones.reached(counts()).isEmpty)
    }

    func testEveryThresholdBelowTheCountCounts() {
        let reached = Milestones.reached(counts(words: 12_000))
        XCTAssertEqual(reached.map(\.threshold), [1_000, 10_000])
        XCTAssertTrue(reached.allSatisfy { $0.kind == .words })
    }

    /// Exactly on the threshold counts — 1 000 words *is* the milestone.
    func testTheThresholdItselfIsReached() {
        XCTAssertEqual(Milestones.reached(counts(words: 1_000)).count, 1)
        XCTAssertTrue(Milestones.reached(counts(words: 999)).isEmpty)
    }

    /// 59 minutes is not an hour. Rounding up would announce something that has
    /// not happened.
    func testSavedTimeIsFlooredToWholeHours() {
        XCTAssertTrue(Milestones.reached(counts(savedSeconds: 3_599)).isEmpty)
        XCTAssertEqual(Milestones.reached(counts(savedSeconds: 3_600)).map(\.kind), [.saved])
    }

    // MARK: - Once, and only once

    func testAMarkedMilestoneIsNotReachedAgain() {
        let now = counts(words: 10_500)
        let marked = Set(Milestones.reached(now).map(\.id))
        XCTAssertTrue(Milestones.newlyReached(now, marked: marked).isEmpty)
    }

    /// The backfill, as the caller performs it: mark everything already passed,
    /// celebrate nothing. The next threshold still arrives normally.
    func testBackfillSilencesTheHistoryButNotTheFuture() {
        let existing = counts(words: 7_977, dictations: 234, savedSeconds: 40_000, meetings: 33, streak: 4)
        let marked = Set(Milestones.reached(existing).map(\.id))
        XCTAssertFalse(marked.isEmpty, "der Bestand hat Schwellen überschritten")
        XCTAssertTrue(Milestones.newlyReached(existing, marked: marked).isEmpty)

        var later = existing
        later.words = 10_100
        XCTAssertEqual(Milestones.newlyReached(later, marked: marked).map(\.threshold), [10_000])
    }

    /// Several at once — the largest step is the one worth the moment.
    func testTheHeadlineIsTheBiggestStep() {
        let new = Milestones.newlyReached(counts(words: 10_000, dictations: 100), marked: [])
        XCTAssertEqual(new.count, 3, "1 000 und 10 000 Wörter plus 100 Diktate")
        XCTAssertEqual(Milestones.headline(new)?.threshold, 10_000)
        XCTAssertNil(Milestones.headline([]))
    }

    // MARK: - Identity and text

    /// The id is the marker on disk. Renaming one would re-celebrate everything
    /// that has ever been reached.
    func testIdsAreStableAndUnique() {
        XCTAssertEqual(Milestone(kind: .words, threshold: 10_000).id, "words.10000")
        XCTAssertEqual(Set(Milestones.all.map(\.id)).count, Milestones.all.count)
    }

    func testEveryMilestoneSaysSomething() {
        for milestone in Milestones.all {
            XCTAssertFalse(milestone.title.isEmpty, milestone.id)
            XCTAssertFalse(milestone.title.contains("%"), "unformatiert: \(milestone.title)")
        }
    }

    // MARK: - The next one

    /// "noch 2.023 bis 10.000": the nearest in *relative* distance, because
    /// that is the one about to happen.
    func testTheNextOneIsTheNearestInRelativeTerms() throws {
        let progress = try XCTUnwrap(Milestones.next(counts(words: 7_977, dictations: 234, meetings: 5)))
        XCTAssertEqual(progress.milestone.kind, .words)
        XCTAssertEqual(progress.milestone.threshold, 10_000)
        XCTAssertEqual(progress.remaining, 2_023)
        XCTAssertEqual(progress.fraction, 0.7977, accuracy: 0.0001)
    }

    func testNothingLeftWhenEverythingIsReached() {
        let everything = counts(
            words: 2_000_000, dictations: 20_000, savedSeconds: 400 * 3_600,
            meetings: 200, streak: 400)
        XCTAssertNil(Milestones.next(everything))
    }

    func testRemainingNeverGoesNegative() {
        let progress = Milestones.Progress(milestone: Milestone(kind: .words, threshold: 1_000), current: 1_200)
        XCTAssertEqual(progress.remaining, 0)
        XCTAssertEqual(progress.fraction, 1)
    }
}
