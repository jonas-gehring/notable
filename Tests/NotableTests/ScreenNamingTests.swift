import XCTest

/// Spec 24: the order of the sources for one meeting — the timeline if the
/// self-check trusts it, otherwise the 1:1 case, otherwise nothing.
final class ScreenNamingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private let owner: Set<String> = ["jonas", "gehring"]

    private func seg(_ cluster: String, _ start: Double, _ end: Double) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(speaker: cluster, start: start, end: end, text: "…", cluster: cluster)
    }

    /// One observation per second, highlighting whoever `active` names.
    private func observations(roster: [String], active: (Int) -> String?) -> [ScreenObservation] {
        (0..<60).map { second in
            ScreenObservation(at: t0.addingTimeInterval(Double(second)), source: .accessibility,
                              roster: roster, activeSpeakers: active(second).map { [$0] } ?? [])
        }
    }

    private let conversation = [
        MeetingTranscriptSegment(speaker: "Ich", start: 0, end: 5, text: "…", cluster: "Ich"),
        MeetingTranscriptSegment(speaker: "Sprecher 1", start: 5, end: 20, text: "…", cluster: "Sprecher 1"),
        MeetingTranscriptSegment(speaker: "Ich", start: 20, end: 25, text: "…", cluster: "Ich"),
        MeetingTranscriptSegment(speaker: "Sprecher 2", start: 25, end: 40, text: "…", cluster: "Sprecher 2"),
        MeetingTranscriptSegment(speaker: "Ich", start: 40, end: 45, text: "…", cluster: "Ich"),
        MeetingTranscriptSegment(speaker: "Sprecher 2", start: 45, end: 58, text: "…", cluster: "Sprecher 2"),
    ]

    private func truthful(_ second: Int) -> String? {
        switch second {
        case 0..<5, 20..<25, 40..<45: "Du"
        case 5..<20: "Anna Weber"
        case 25..<40, 45..<58: "Ben Kraus"
        default: nil
        }
    }

    func testWithoutObservationsNothingChanges() {
        let outcome = ScreenNaming.apply(conversation, observations: [], recordingStart: t0, ownerTokens: owner)
        XCTAssertEqual(outcome.segments.map(\.speaker), conversation.map(\.speaker))
        XCTAssertEqual(outcome.names, [:])
        XCTAssertEqual(outcome.participants, [])
    }

    /// Interviews and two-person calls: one remote person, one large cluster.
    func testTheOneToOneCaseNeedsNoTimeline() {
        let segments = [seg("Ich", 0, 5), seg("Sprecher 1", 5, 60)]
        let outcome = ScreenNaming.apply(segments, observations: observations(roster: ["Jonas Gehring (Du)", "Anna Weber"]) { _ in nil },
                                         recordingStart: t0, ownerTokens: owner)
        XCTAssertEqual(outcome.names, ["Sprecher 1": "Anna Weber"])
        XCTAssertEqual(outcome.segments.map(\.speaker), ["Ich", "Anna Weber"])
        XCTAssertEqual(outcome.segments.map(\.cluster), ["Ich", "Sprecher 1"], "der geprägte Cluster bleibt")
        XCTAssertEqual(ScreenNaming.unnamedLabels(in: outcome.segments), [])
    }

    func testATrustedTimelineNamesEveryRemoteSpeaker() throws {
        let outcome = ScreenNaming.apply(conversation,
                                         observations: observations(roster: ["Du", "Anna Weber", "Ben Kraus"], active: truthful),
                                         recordingStart: t0, ownerTokens: owner)
        XCTAssertTrue(ScreenSelfCheck.trusts(outcome.selfCheck))
        XCTAssertEqual(outcome.names, ["Sprecher 1": "Anna Weber", "Sprecher 2": "Ben Kraus"])
        XCTAssertEqual(outcome.participants, ["Anna Weber", "Ben Kraus"])
    }

    /// The same meeting read by a wrong adapter: the local user's highlight
    /// lands on someone else's turn. Nothing from the timeline is used — and
    /// with two remote people, the 1:1 rule does not apply either.
    func testAnUntrustedTimelineNamesNobody() {
        let wrong: (Int) -> String? = { second in
            switch second {
            case 5..<20: "Du"
            case 0..<5, 20..<25: "Anna Weber"
            default: "Ben Kraus"
            }
        }
        let outcome = ScreenNaming.apply(conversation,
                                         observations: observations(roster: ["Du", "Anna Weber", "Ben Kraus"], active: wrong),
                                         recordingStart: t0, ownerTokens: owner)
        XCTAssertFalse(ScreenSelfCheck.trusts(outcome.selfCheck))
        XCTAssertEqual(outcome.names, [:])
        XCTAssertEqual(ScreenNaming.unnamedLabels(in: outcome.segments), ["Sprecher 1", "Sprecher 2"])
    }
}
