import XCTest

/// One table for the meeting clients, checked from the side that used to have
/// its own copy: a name shown in the settings window has to come from the same
/// row the detector matches on.
final class MeetingAppsTests: XCTestCase {
    func testEveryDetectedAppHasAName() {
        for app in MeetingApps.native {
            XCTAssertEqual(MeetingApps.displayName(for: app.bundleID), app.name)
            XCTAssertFalse(app.name.isEmpty)
        }
    }

    func testWebServicesAreNamedFromTheSameTableThatDetectsThem() {
        // The key comes from a window title, the name from the key — and the
        // settings list only ever has the key.
        let detected = MeetingIdentity.webService(forWindowTitle: "Zoom Meeting")
        XCTAssertEqual(detected?.key, "web:zoom")
        XCTAssertEqual(MeetingIdentity.displayName(forKey: "web:zoom"), "Zoom")
        XCTAssertEqual(MeetingApps.displayName(for: "web:zoom"), "Zoom (Browser)")

        XCTAssertEqual(MeetingIdentity.webService(forWindowTitle: "Meet – Standup")?.key, "web:google-meet")
        XCTAssertEqual(MeetingApps.displayName(for: "web:google-meet"), "Google Meet (Browser)")
        XCTAssertEqual(MeetingApps.displayName(for: "web:teams"), "Microsoft Teams (Browser)")
    }

    func testWindowTitleWithoutCallEvidenceMatchesNothing() {
        XCTAssertNil(MeetingIdentity.webService(forWindowTitle: "Posteingang – Mail"))
        XCTAssertNil(MeetingIdentity.displayName(forKey: "web:unknown"))
    }

    /// An unknown key shows itself rather than a guess: a raw identifier is
    /// ugly, but it is the only thing that lets someone recognise an entry the
    /// app no longer knows about.
    func testUnknownKeyFallsBackToItself() {
        XCTAssertEqual(MeetingApps.displayName(for: "com.example.irgendwas"), "com.example.irgendwas")
    }

    func testSlackIsAmbientAndZoomIsDedicated() {
        // The tier decides whether *output* going quiet may end a call. Slack
        // and browsers play audio all day; getting this wrong ends calls early
        // or never ends them at all.
        let byID = Dictionary(uniqueKeysWithValues: MeetingApps.native.map { ($0.bundleID, $0) })
        XCTAssertEqual(byID["com.tinyspeck.slackmacgap"]?.tier, .ambient)
        XCTAssertEqual(byID["us.zoom.xos"]?.tier, .dedicated)
        XCTAssertEqual(byID["com.apple.FaceTime"]?.tier, .dedicated)
    }
}
