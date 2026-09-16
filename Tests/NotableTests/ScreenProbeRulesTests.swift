import XCTest

/// Spec 36 §3.1: the measurement that runs by itself — once per app and
/// version, and cleaned up after thirty days.
final class ScreenProbeRuleTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "notable-probe-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testOncePerAppAndVersion() {
        XCTAssertTrue(ScreenProbeRule.shouldProbe(bundleID: "com.microsoft.teams2", version: "25.1", defaults: defaults))
        ScreenProbeRule.markProbed(bundleID: "com.microsoft.teams2", version: "25.1", defaults: defaults)
        XCTAssertFalse(ScreenProbeRule.shouldProbe(bundleID: "com.microsoft.teams2", version: "25.1", defaults: defaults),
                       "ein zweiter Call derselben Version schreibt keine Datei")
        // A new release is exactly what may have changed the tree an adapter
        // would be built from, so it is measured again.
        XCTAssertTrue(ScreenProbeRule.shouldProbe(bundleID: "com.microsoft.teams2", version: "25.2", defaults: defaults))
        XCTAssertTrue(ScreenProbeRule.shouldProbe(bundleID: "us.zoom.xos", version: "25.1", defaults: defaults))
    }

    func testOnlyFilesOlderThanThirtyDaysGo() {
        let now = Date(timeIntervalSince1970: 100 * 24 * 3600)
        let fresh = (url: URL(fileURLWithPath: "/tmp/fresh.txt"), modified: now.addingTimeInterval(-29 * 24 * 3600))
        let old = (url: URL(fileURLWithPath: "/tmp/old.txt"), modified: now.addingTimeInterval(-31 * 24 * 3600))
        XCTAssertEqual(ScreenProbeRule.expired([fresh, old], now: now), [old.url])
    }
}

/// "Der Adapter liefert seit drei Meetings nichts" (Spec 24 §6, Spec 36 §3.1).
final class ScreenDataWatchTests: XCTestCase {
    func testOnlyAMeetingWithAnAdapterCounts() {
        XCTAssertEqual(ScreenDataWatch.next(2, adapterRan: false, observations: 0), 2,
                       "ohne Adapter ist nichts blind geworden")
        XCTAssertEqual(ScreenDataWatch.next(2, adapterRan: true, observations: 0), 3)
        XCTAssertEqual(ScreenDataWatch.next(2, adapterRan: true, observations: 17), 0,
                       "eine einzige Beobachtung setzt zurück")
    }

    func testTheWarningStartsAtThree() {
        XCTAssertEqual(ScreenDataWatch.warnAfter, 3)
        var count = 0
        for _ in 0 ..< 3 { count = ScreenDataWatch.next(count, adapterRan: true, observations: 0) }
        XCTAssertGreaterThanOrEqual(count, ScreenDataWatch.warnAfter)
    }
}
