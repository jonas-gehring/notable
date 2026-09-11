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

    func testLabelsAreRenumberedByFirstAppearance() {
        let cleaned = SpeakerClusterCleanup.cleaned([segment("7", 10, 100, a), segment("3", 0, 100, b)])
        XCTAssertEqual(cleaned.map(\.label), ["2", "1"])
    }
}
