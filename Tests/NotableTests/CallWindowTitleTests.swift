import XCTest

/// Spec 36 §3.1: the call window's title as a title for the note — or nothing.
///
/// A wrong note title is the file name, the search term and the line in the
/// list, all wrong at once, so every rule here errs towards nothing.
final class CallWindowTitleTests: XCTestCase {
    func testTheAppNameIsNotATitle() {
        XCTAssertNil(CallWindowTitle.clean("Microsoft Teams"))
        XCTAssertNil(CallWindowTitle.clean("Zoom"))
        XCTAssertNil(CallWindowTitle.clean("Meeting | Microsoft Teams"))
        XCTAssertNil(CallWindowTitle.clean("Besprechung"))
    }

    func testTheMeetingNameSurvivesTheAppNameAroundIt() {
        XCTAssertEqual(CallWindowTitle.clean("Forschungszulage Review Q3 | Microsoft Teams"), "Forschungszulage Review Q3")
        XCTAssertEqual(CallWindowTitle.clean("Zoom — Quartalsplanung mit Payhawk"), "Quartalsplanung mit Payhawk")
        XCTAssertEqual(CallWindowTitle.clean("Design Review Q3 - Google Meet"), "Design Review Q3")
    }

    func testBadgesAndWindowNumbersAreState() {
        XCTAssertEqual(CallWindowTitle.clean("(3) Forschungszulage Review Q3 | Teams"), "Forschungszulage Review Q3")
        XCTAssertEqual(CallWindowTitle.clean("Forschungszulage Review Q3 (1)"), "Forschungszulage Review Q3")
    }

    /// Two words is a label, three is a title — the line §3.1 draws.
    ///
    /// It is a blunt line, and it cuts real titles: "Forschungszulage Review",
    /// the one meeting title Spec 35 actually measured, has two words and is
    /// thrown away here. That is the spec's rule, kept deliberately (§9) — the
    /// cost is a note that falls back to "Microsoft Teams · 10:03", not a wrong
    /// title.
    func testUnderThreeWordsIsNotATitle() {
        XCTAssertNil(CallWindowTitle.clean("Weekly Sync"))
        XCTAssertNil(CallWindowTitle.clean("Forschungszulage Review"))
        XCTAssertEqual(CallWindowTitle.clean("Weekly Sync Team"), "Weekly Sync Team")
        XCTAssertNil(CallWindowTitle.clean(nil))
        XCTAssertNil(CallWindowTitle.clean("   "))
    }

    /// An app name inside a real title is a word, not an app.
    func testAnAppNameInsideATitleIsKept() {
        XCTAssertEqual(CallWindowTitle.clean("Teams-Migration Kickoff Runde | Microsoft Teams"),
                       "Teams-Migration Kickoff Runde")
    }

    func testTheMostFrequentTitleOfAMeetingWins() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func observation(_ second: Double, _ title: String?) -> ScreenObservation {
            ScreenObservation(at: start.addingTimeInterval(second), source: .accessibility,
                              roster: [], activeSpeakers: [], windowTitle: title)
        }
        let observations = [
            observation(0, "Microsoft Teams"),
            observation(1, "Forschungszulage Review Q3 | Microsoft Teams"),
            observation(2, "Bildschirm wird geteilt | Microsoft Teams"),
            observation(3, "Forschungszulage Review Q3 | Microsoft Teams"),
        ]
        XCTAssertEqual(CallWindowTitle.fromObservations(observations), "Forschungszulage Review Q3")
        XCTAssertNil(CallWindowTitle.fromObservations([observation(0, "Zoom")]))
        XCTAssertNil(CallWindowTitle.fromObservations([]))
    }
}
