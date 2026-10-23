import XCTest

/// Spec 35: the one place where a name is applied without having been spoken —
/// and every guard that keeps it there.
final class OneToOneNamingTests: XCTestCase {
    private let owner: Set<String> = ["jonas", "gehring"]

    private func name(attendees: [String], open: Set<String> = ["Sprecher 1"], large: [String] = ["Sprecher 1"]) -> (label: String, name: String)? {
        OneToOneNaming.name(attendees: attendees, openLabels: open, largeClusters: large, ownerTokens: owner)
    }

    /// The measured case of 2026-09-15: one guest, one voice, no name in the note.
    func testOneGuestAndOneVoiceGetTheName() {
        let result = name(attendees: ["jana.schultze", "Jonas Gehring"])
        XCTAssertEqual(result?.label, "Sprecher 1")
        XCTAssertEqual(result?.name, "Jana Schultze")
    }

    func testTwoGuestsNameNobody() {
        XCTAssertNil(name(attendees: ["Jana Schultze", "Tom Meier"]))
    }

    func testTwoVoicesNameNobody() {
        XCTAssertNil(name(attendees: ["Jana Schultze"], open: ["Sprecher 1", "Sprecher 2"], large: ["Sprecher 1", "Sprecher 2"]))
    }

    /// The screen (or the user) already named it — that outranks the calendar.
    func testALabelThatIsAlreadyNamedIsLeftAlone() {
        XCTAssertNil(name(attendees: ["Jana Schultze"], open: []))
    }

    func testAMeetingWithOnlyMyselfInvitedNamesNobody() {
        XCTAssertNil(name(attendees: ["Jonas Gehring"]))
        XCTAssertNil(name(attendees: []))
    }

    /// A splinter is not a voice: only large clusters count.
    func testTheOnlyLargeClusterIsTheOneNamed() {
        let result = name(attendees: ["Jana Schultze"], open: ["Sprecher 1", "Sprecher ?"], large: ["Sprecher 1"])
        XCTAssertEqual(result?.label, "Sprecher 1")
    }

    /// 2026-09-21: the account knew only the first name, the invitation listed
    /// the user under their full name, and the remote voice was named after
    /// them. Containment does not catch that; sharing a name does.
    func testTheUserUnderTheirFullNameIsNeverTheGuest() {
        let firstNameOnly: Set<String> = ["jonas"]
        XCTAssertNil(OneToOneNaming.name(
            attendees: ["Jonas Gehring"], openLabels: ["Sprecher 1"], largeClusters: ["Sprecher 1"], ownerTokens: firstNameOnly
        ))
        let result = OneToOneNaming.name(
            attendees: ["Jonas Gehring", "Tom Meier"], openLabels: ["Sprecher 1"], largeClusters: ["Sprecher 1"], ownerTokens: firstNameOnly
        )
        XCTAssertEqual(result?.name, "Tom Meier")
    }

    /// The price, paid on purpose: a namesake as the only guest stays
    /// "Sprecher 1" here. The model can still name him if his name is spoken.
    func testANamesakeIsNotNamedFromTheCalendar() {
        XCTAssertNil(name(attendees: ["Jonas Weber"]))
    }
}

final class AttendeeNameTests: XCTestCase {
    func testAnAddressPartBecomesAName() {
        XCTAssertEqual(AttendeeName.readable("jana.schultze"), "Jana Schultze")
        XCTAssertEqual(AttendeeName.readable("JANA.SCHULTZE"), "Jana Schultze")
        XCTAssertEqual(AttendeeName.readable("jana_schultze@example.com"), "Jana Schultze")
        XCTAssertEqual(AttendeeName.readable("anna-lena.mueller"), "Anna-Lena Mueller")
    }

    func testARealNameIsLeftAlone() {
        XCTAssertEqual(AttendeeName.readable("Jana Schultze"), "Jana Schultze")
        XCTAssertEqual(AttendeeName.readable(" Dr. Jana Schultze "), "Dr. Jana Schultze")
    }

    /// Anything that is not plainly "first.last" stays as it is: a guessed name
    /// is worse than an ugly one.
    func testWhatDoesNotLookLikeANameStays() {
        XCTAssertEqual(AttendeeName.readable("team.2026.review"), "team.2026.review")
        XCTAssertEqual(AttendeeName.readable("j.s"), "j.s")
        XCTAssertEqual(AttendeeName.readable("meetingroom4"), "meetingroom4")
    }
}
