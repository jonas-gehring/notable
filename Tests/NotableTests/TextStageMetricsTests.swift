import XCTest
@testable import Notable

/// Spec 32 §3.7–3.8: the statistics for the text stages.
final class TextStageMetricsTests: XCTestCase {
    private func row(_ polisher: String?, ms: Int? = nil, kind: UsageKind = .dictation) -> UsageRow {
        UsageRow(kind: kind, startedAt: Date(), endedAt: Date(), wordCount: 10, polisher: polisher, polishMs: ms)
    }

    func testSharesInFixedOrderAndUnknownKeptApart() {
        let rows = [row("cli"), row(nil), row("rules"), row("rules"), row("local")]
        let shares = UsageMetrics.polisherShares(rows)
        XCTAssertEqual(shares.map(\.polisher), ["rules", "local", "cli", UsageMetrics.unknownKey])
        XCTAssertEqual(shares.map(\.count), [2, 1, 1, 1])
    }

    func testMeetingsAreNotCounted() {
        let shares = UsageMetrics.polisherShares([row("rules"), row(nil, kind: .meeting)])
        XCTAssertEqual(shares.map(\.polisher), ["rules"])
    }

    func testEmptyStagesAreLeftOut() {
        XCTAssertTrue(UsageMetrics.polisherShares([]).isEmpty)
        XCTAssertEqual(UsageMetrics.polisherShares([row("local")]).map(\.polisher), ["local"])
    }

    func testLatencyNeedsEnoughSamples() {
        let few = (0 ..< UsageMetrics.minimumLatencySamples - 1).map { row("local", ms: 900 + $0) }
        XCTAssertNil(UsageMetrics.polishLatency(few))
    }

    func testLatencyIsMedianAndP95OfTheLocalStageOnly() throws {
        var rows = (1 ... 20).map { row("local", ms: $0 * 100) }
        rows.append(row("rules", ms: 99_999))
        let stats = try XCTUnwrap(UsageMetrics.polishLatency(rows))
        XCTAssertEqual(stats.count, 20)
        XCTAssertEqual(stats.p50, 1_000)
        XCTAssertEqual(stats.p95, 1_900)
    }
}
