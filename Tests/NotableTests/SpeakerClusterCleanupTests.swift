import XCTest

/// Spec 24, Stufe 1: splinters go to the nearest large voice; large voices are
/// never merged here — a wrongly merged voice cannot be separated again.
final class SpeakerClusterCleanupTests: XCTestCase {
    private let a: [Float] = [1, 0, 0]
    private let b: [Float] = [0, 1, 0]
    private let c: [Float] = [0, 0, 1]
    private let nearA: [Float] = [0.95, 0.1, 0.05]
    private let nearB: [Float] = [0.1, 0.95, 0.05]

    private func segment(_ label: String, _ start: Double, _ duration: Double, _ embedding: [Float]) -> SpeakerClusterCleanup.Segment {
        SpeakerClusterCleanup.Segment(label: label, start: start, end: start + duration, embedding: embedding, quality: 1)
    }

    private func labels(_ segments: [SpeakerClusterCleanup.Segment]) -> Set<String> { Set(segments.map(\.label)) }

    /// The measured case: five labels, two of them splinters, one a genuine
    /// but split continuation (42 s) that only the screen may merge.
    func testThePayhawkShapeEndsWithThreeLabels() {
        let input = [
            segment("1", 0, 1178, a),
            segment("5", 1200, 254, b),
            segment("3", 1500, 42, [0, 0.8, 0.6]),  // large: 42 s ≥ 8 s; like the second voice, not the same
            segment("4", 1600, 5, nearA),   // "Mm-hmm." / "Thanks a lot…"
            segment("2", 1700, 1, nearB),   // "Mm." / "And"
        ]
        let cleaned = SpeakerClusterCleanup.cleaned(input)
        XCTAssertEqual(labels(cleaned).count, 3)
        XCTAssertEqual(cleaned[3].label, cleaned[0].label, "der 5-s-Splitter gehört zur Hauptstimme")
        XCTAssertEqual(cleaned[4].label, cleaned[1].label, "der 1-s-Splitter gehört zur zweiten Stimme")
        XCTAssertNotEqual(cleaned[2].label, cleaned[1].label, "zwei große Cluster werden hier nie verschmolzen")
    }

    /// 20 s in a 2000-s call: under 3 %, but over 8 s — a quiet real person.
    func testAQuietParticipantInALongCallIsNotASplinter() {
        let cleaned = SpeakerClusterCleanup.cleaned([segment("1", 0, 1980, a), segment("2", 1990, 20, nearA)])
        XCTAssertEqual(labels(cleaned).count, 2)
    }

    /// 5 s in a 60-s call: under 8 s, but over 3 %.
    func testAShortVoiceInAShortCallIsNotASplinter() {
        let cleaned = SpeakerClusterCleanup.cleaned([segment("1", 0, 55, a), segment("2", 55, 5, nearA)])
        XCTAssertEqual(labels(cleaned).count, 2)
    }

    func testASplinterFarFromEveryVoiceKeepsItsLabel() {
        let cleaned = SpeakerClusterCleanup.cleaned([segment("1", 0, 1000, a), segment("2", 1000, 2, c)])
        XCTAssertEqual(labels(cleaned).count, 2)
    }

    func testTwoLargeClustersAreNeverMergedEvenIfTheySoundAlike() {
        let cleaned = SpeakerClusterCleanup.cleaned([segment("1", 0, 500, a), segment("2", 500, 500, a)])
        XCTAssertEqual(labels(cleaned).count, 2)
    }

    func testASplinterWithoutAnEmbeddingStays() {
        let cleaned = SpeakerClusterCleanup.cleaned([segment("1", 0, 1000, a), segment("2", 1000, 2, [])])
        XCTAssertEqual(labels(cleaned).count, 2)
    }

    func testLabelsAreRenumberedBySpeechShare() {
        let cleaned = SpeakerClusterCleanup.cleaned([segment("3", 0, 50, b), segment("7", 60, 100, a)])
        XCTAssertEqual(cleaned.map(\.label), ["2", "1"], "die Hauptstimme ist Sprecher 1, auch wenn sie später einsetzt")
    }

    func testEqualShareFallsBackToFirstAppearance() {
        let cleaned = SpeakerClusterCleanup.cleaned([segment("7", 10, 100, a), segment("3", 0, 100, b)])
        XCTAssertEqual(cleaned.map(\.label), ["2", "1"])
    }

    // MARK: - Decided 2026-09-15 (Spec 24 §9.1)

    /// 0.70 from the only large voice: not a voice match, but nobody else it could be.
    func testWithOneLargeVoiceASplinterJoinsItUpToPointNine() {
        let cleaned = SpeakerClusterCleanup.cleaned([segment("1", 0, 1000, a), segment("2", 1000, 3, [0.3, 0.95, 0])])
        XCTAssertEqual(labels(cleaned), ["1"])
    }

    /// The same distance with two large voices would be a guess.
    func testWithTwoLargeVoicesAnUnmatchedSubSecondSplinterIsUnknown() {
        let between: [Float] = [0.3, 0.3, 0.905]  // 0.70 from both
        let cleaned = SpeakerClusterCleanup.cleaned([
            segment("4", 0, 0.7, between),
            segment("1", 1, 500, a),
            segment("2", 600, 400, b),
        ])
        XCTAssertEqual(cleaned.map(\.label), [SpeakerClusterCleanup.unknownLabel, "1", "2"],
                       "der Splitter nimmt keine Nummer, und die Hauptstimme bleibt Sprecher 1")
    }

    func testWithTwoLargeVoicesAnUnmatchedLongerSplinterKeepsANumber() {
        let cleaned = SpeakerClusterCleanup.cleaned([segment("1", 0, 500, a), segment("2", 500, 400, b), segment("3", 900, 3, c)])
        XCTAssertEqual(labels(cleaned), ["1", "2", "3"])
    }

    func testAMatchedSubSecondSplinterStillJoinsItsVoice() {
        let cleaned = SpeakerClusterCleanup.cleaned([segment("1", 0, 500, a), segment("2", 500, 400, b), segment("3", 900, 0.5, nearB)])
        XCTAssertEqual(cleaned[2].label, cleaned[1].label)
    }

    /// "Sprecher ?" may be several people: never offered for a name.
    func testTheUnknownLabelIsNeverOfferedForNaming() {
        let unknown = SpeakerNameResolver.unknownSpeakerLabel
        XCTAssertEqual(unknown, "Sprecher ?")
        let specs = MeetingPipeline.orderedSpecs(micSegments: [], systemSegments: [(speakerID: SpeakerClusterCleanup.unknownLabel, start: 0, end: 1)])
        XCTAssertEqual(specs.map(\.speaker), [unknown])
        let segments = [
            MeetingTranscriptSegment(speaker: "Sprecher 1", start: 0, end: 5, text: "Hallo.", cluster: "Sprecher 1"),
            MeetingTranscriptSegment(speaker: unknown, start: 5, end: 6, text: "Mm.", cluster: unknown),
        ]
        XCTAssertEqual(SpeakerNameResolver.remoteLabels(in: segments), ["Sprecher 1"])
        XCTAssertEqual(ScreenNaming.unnamedLabels(in: segments), ["Sprecher 1"])
    }
}
