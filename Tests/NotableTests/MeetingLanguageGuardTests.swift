import XCTest

/// One language per meeting: short English strays in a German meeting are
/// turned German where they are fillers and dropped where they are not.
final class MeetingLanguageGuardTests: XCTestCase {
    private func segment(_ speaker: String, _ start: TimeInterval, _ text: String) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(speaker: speaker, start: start, end: start + 1, text: text, cluster: speaker)
    }

    private lazy var german: [MeetingTranscriptSegment] = [
        segment("Ich", 0, "Ich glaube, das ist eine gute Idee, und wir sollten das auch so machen, dann ist es für die Kunden einfacher und wir haben noch Zeit."),
        segment("Sprecher 1", 5, "Genau, ja, das machen wir dann so, aber nicht heute."),
        segment("Ich", 20, "Wir haben das jetzt auch schon mit den Kollegen besprochen, und die sind auch dafür, wenn wir das noch vor dem Sommer machen."),
    ]

    func testTheMeetingLanguageIsCountedFromFunctionWords() {
        XCTAssertEqual(MeetingLanguageGuard.language(of: german), .german)
        XCTAssertNil(MeetingLanguageGuard.language(of: [segment("Ich", 0, "Ja, genau.")]), "too little to tell")
    }

    /// The strays measured on the benchmark notes, in one German meeting.
    func testShortEnglishStraysInAGermanMeeting() {
        let result = MeetingLanguageGuard.guarded(german + [
            segment("Sprecher 1", 8, "Yeah. Yeah."),
            segment("Ich", 9, "See the home."),
            segment("Ich", 10, "Find the Shop."),
            segment("Sprecher 1", 11, "What?"),
            segment("Ich", 12, "I think that is the right thing to do here."),
            segment("Sprecher 1", 15, "Mm-hmm, yeah."),
            segment("Ich", 16, "Start and am vorauslichen Projektende."),
        ])
        XCTAssertEqual(result.language, .german)
        XCTAssertEqual(Array(result.segments.dropFirst(3).map(\.text)), [
            "Ja. Ja.",
            "Find the Shop.",                                // a capitalised noun: German after all
            "I think that is the right thing to do here.",   // too long to be a stray
            "Mhm, ja.",
            "Start and am vorauslichen Projektende.",
        ])
        XCTAssertEqual(result.dropped, 2)
        XCTAssertEqual(result.droppedWords, 4)
        XCTAssertEqual(result.rewritten, 2)
    }

    /// In the English interviews the only German segment was a real aside.
    func testAnEnglishMeetingIsLeftAlone() {
        let segments = [
            segment("Ich", 0, "I think that we should do this, and it is the right thing for you and for the team, but we have to be quick about it."),
            segment("Sprecher 1", 5, "Yeah, that is what I would do with it."),
            segment("Ich", 6, "Was für ein Witz, Alter."),
        ]
        let result = MeetingLanguageGuard.guarded(segments)
        XCTAssertEqual(result.language, .english)
        XCTAssertEqual(result.segments.map(\.text), segments.map(\.text))
    }

    func testFillersTurnGermanAndKeepTheirCapital() {
        XCTAssertEqual(MeetingLanguageGuard.rewritingFillers("Yeah, klar. Yeah."), "Ja, klar. Ja.")
        XCTAssertEqual(MeetingLanguageGuard.rewritingFillers("gerne, yeah"), "gerne, ja")
        XCTAssertEqual(MeetingLanguageGuard.rewritingFillers("Mm-hmm."), "Mhm.")
        XCTAssertEqual(MeetingLanguageGuard.rewritingFillers("Ja - nein"), "Ja - nein")
        XCTAssertEqual(MeetingLanguageGuard.rewritingFillers("Yesterday"), "Yesterday")
    }

    func testGermanEvidence() {
        XCTAssertTrue(MeetingLanguageGuard.hasGermanEvidence("Größe"))
        XCTAssertTrue(MeetingLanguageGuard.hasGermanEvidence("Find the Shop."))
        XCTAssertFalse(MeetingLanguageGuard.hasGermanEvidence("See the home."))
        XCTAssertFalse(MeetingLanguageGuard.hasGermanEvidence("Hallo, I said. It works."), "\"I\" and a sentence start are no evidence")
    }
}
