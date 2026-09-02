import XCTest

/// Pure tests for the consent preference store and the stable identity mapping.
/// No UI, no live-window signals — everything runs against a throwaway defaults
/// suite and the pure `MeetingIdentity` helper.
final class MeetingConsentTests: XCTestCase {
    private let suiteName = "MeetingConsentTests.suite"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Store

    func testUnknownKeyMeansAsk() {
        XCTAssertNil(MeetingConsentStore.decision(for: "us.zoom.xos", defaults: defaults))
    }

    func testRememberAlwaysIsReadBack() {
        MeetingConsentStore.remember(.always, for: "us.zoom.xos", defaults: defaults)
        XCTAssertEqual(MeetingConsentStore.decision(for: "us.zoom.xos", defaults: defaults), .always)
    }

    func testRememberNeverIsReadBack() {
        MeetingConsentStore.remember(.never, for: "web:teams", defaults: defaults)
        XCTAssertEqual(MeetingConsentStore.decision(for: "web:teams", defaults: defaults), .never)
    }

    func testRememberOverwritesPriorChoice() {
        MeetingConsentStore.remember(.never, for: "web:zoom", defaults: defaults)
        MeetingConsentStore.remember(.always, for: "web:zoom", defaults: defaults)
        XCTAssertEqual(MeetingConsentStore.decision(for: "web:zoom", defaults: defaults), .always)
    }

    func testForgetRevertsToAsk() {
        MeetingConsentStore.remember(.always, for: "us.zoom.xos", defaults: defaults)
        MeetingConsentStore.forget("us.zoom.xos", defaults: defaults)
        XCTAssertNil(MeetingConsentStore.decision(for: "us.zoom.xos", defaults: defaults))
    }

    func testForgetLeavesOtherKeysIntact() {
        MeetingConsentStore.remember(.always, for: "us.zoom.xos", defaults: defaults)
        MeetingConsentStore.remember(.never, for: "web:google-meet", defaults: defaults)
        MeetingConsentStore.forget("us.zoom.xos", defaults: defaults)
        XCTAssertNil(MeetingConsentStore.decision(for: "us.zoom.xos", defaults: defaults))
        XCTAssertEqual(MeetingConsentStore.decision(for: "web:google-meet", defaults: defaults), .never)
    }

    func testAllReturnsEveryRememberedDecision() {
        MeetingConsentStore.remember(.always, for: "us.zoom.xos", defaults: defaults)
        MeetingConsentStore.remember(.never, for: "web:teams", defaults: defaults)
        let all = MeetingConsentStore.all(defaults: defaults)
        XCTAssertEqual(all, ["us.zoom.xos": .always, "web:teams": .never])
    }

    func testAllIsEmptyWhenNothingRemembered() {
        XCTAssertTrue(MeetingConsentStore.all(defaults: defaults).isEmpty)
    }

    func testCorruptRawValueIsDroppedDefensively() {
        defaults.set(["us.zoom.xos": "maybe"], forKey: MeetingConsentStore.defaultsKey)
        XCTAssertNil(MeetingConsentStore.decision(for: "us.zoom.xos", defaults: defaults))
        XCTAssertTrue(MeetingConsentStore.all(defaults: defaults).isEmpty)
    }

    // MARK: - identityKey mapping (MeetingIdentity)

    func testWebServiceKeyForGoogleMeetURL() {
        let service = MeetingIdentity.webService(forWindowTitle: "Projekt-Sync | meet.google.com")
        XCTAssertEqual(service?.key, "web:google-meet")
        XCTAssertEqual(service?.display, "Google Meet")
    }

    func testWebServiceKeyForGoogleMeetTitlePrefix() {
        XCTAssertEqual(MeetingIdentity.webService(forWindowTitle: "Meet – Standup")?.key, "web:google-meet")
        XCTAssertEqual(MeetingIdentity.webService(forWindowTitle: "Meet - Standup")?.key, "web:google-meet")
    }

    func testWebServiceKeyForZoom() {
        let service = MeetingIdentity.webService(forWindowTitle: "Zoom Meeting")
        XCTAssertEqual(service?.key, "web:zoom")
        XCTAssertEqual(service?.display, "Zoom")
    }

    func testWebServiceKeyForTeams() {
        let service = MeetingIdentity.webService(forWindowTitle: "Microsoft Teams — Weekly")
        XCTAssertEqual(service?.key, "web:teams")
        XCTAssertEqual(service?.display, "Microsoft Teams")
    }

    func testWebServiceKeyIsCaseInsensitive() {
        XCTAssertEqual(MeetingIdentity.webService(forWindowTitle: "ZOOM MEETING")?.key, "web:zoom")
    }

    func testWebServiceKeyNilForNonCallTitle() {
        XCTAssertNil(MeetingIdentity.webService(forWindowTitle: "Inbox – Gmail"))
    }

    // MARK: - Candidate carries a stable identityKey

    func testCandidateIdentityKeyRoundTripsThroughStore() {
        // A candidate built from detection carries the stable key; the store keys
        // on exactly that value.
        let candidate = MeetingDetector.Candidate(sourceName: "Zoom", identityKey: "us.zoom.xos")
        MeetingConsentStore.remember(.always, for: candidate.identityKey, defaults: defaults)
        XCTAssertEqual(MeetingConsentStore.decision(for: candidate.identityKey, defaults: defaults), .always)
    }

    func testCandidateDefaultIdentityKeyIsUnknown() {
        XCTAssertEqual(MeetingDetector.Candidate(sourceName: "Unbekannt").identityKey, "unknown")
    }
}
