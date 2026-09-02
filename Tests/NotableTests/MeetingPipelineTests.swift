import XCTest

final class MeetingPipelineTests: XCTestCase {
    func testOrderedSpecsMergesTracksChronologically() {
        let specs = MeetingPipeline.orderedSpecs(
            micSegments: [(start: 5.0, end: 8.0), (start: 20.0, end: 22.0)],
            systemSegments: [
                (speakerID: "1", start: 0.0, end: 4.5),
                (speakerID: "2", start: 9.0, end: 15.0),
            ]
        )

        XCTAssertEqual(specs.count, 4)
        XCTAssertEqual(specs.map(\.speaker), ["Sprecher 1", "Ich", "Sprecher 2", "Ich"])
        XCTAssertEqual(specs.map(\.start), [0.0, 5.0, 9.0, 20.0])
        XCTAssertEqual(specs[0].track, .system)
        XCTAssertEqual(specs[1].track, .microphone)
    }

    func testOrderedSpecsHandlesEmptyTracks() {
        XCTAssertTrue(MeetingPipeline.orderedSpecs(micSegments: [], systemSegments: []).isEmpty)

        let micOnly = MeetingPipeline.orderedSpecs(
            micSegments: [(start: 1.0, end: 2.0)],
            systemSegments: []
        )
        XCTAssertEqual(micOnly.count, 1)
        XCTAssertEqual(micOnly[0].speaker, "Ich")
    }

    /// Parakeet pads every call to 15 s, so hundreds of short turns burn almost
    /// all their compute on padding. Consecutive turns of one speaker are merged
    /// — but never across a speaker change, a track change, a long pause, or
    /// past the 15 s single-chunk limit.
    func testGroupingMergesOnlyWhatMayBeMerged() {
        func spec(_ track: MeetingPipeline.SegmentSpec.Track, _ speaker: String,
                  _ start: TimeInterval, _ end: TimeInterval) -> MeetingPipeline.SegmentSpec {
            MeetingPipeline.SegmentSpec(track: track, speaker: speaker, start: start, end: end)
        }

        let grouped = MeetingPipeline.groupedSpecs([
            spec(.microphone, "Ich", 0, 2),
            spec(.microphone, "Ich", 2.5, 4),      // same speaker, short pause -> merge
            spec(.microphone, "Ich", 9, 11),       // 5 s pause -> new segment
            spec(.system, "Sprecher 1", 11.5, 13), // track change -> never merged
            spec(.system, "Sprecher 2", 13.2, 15), // speaker change -> new segment
            spec(.system, "Sprecher 2", 15.1, 30), // would exceed 14 s -> new segment
        ])

        XCTAssertEqual(grouped.count, 5)
        XCTAssertEqual(grouped[0].start, 0)
        XCTAssertEqual(grouped[0].end, 4, "Zwei Beiträge desselben Sprechers müssen ein ASR-Call werden")
        XCTAssertEqual(grouped[1].start, 9)
        XCTAssertEqual(grouped[2].speaker, "Sprecher 1")
        XCTAssertEqual(grouped[3].speaker, "Sprecher 2")
        XCTAssertEqual(grouped[3].end, 15)
        XCTAssertEqual(grouped[4].start, 15.1, "Über 14 s darf nicht verschmolzen werden")
        // Index 4 is 14.9 s all by itself: a single long diarized turn passes
        // through untouched (FluidAudio's chunker handles it correctly — there
        // is no carried state here to lose). Grouping may never CREATE one.
        for (index, segment) in grouped.enumerated() where index != 4 {
            XCTAssertLessThanOrEqual(
                segment.end - segment.start, MeetingPipeline.maximumGroupDuration,
                "Gruppierung darf kein Segment über 14 s erzeugen"
            )
        }
    }

    /// The system track is compacted before diarization (silence destroys the
    /// speaker embeddings). Diarized times therefore live in the compacted
    /// timeline and must land back on the original one — a wrong shift here
    /// attributes the right words to the right speaker at the wrong moment.
    func testDiarizedTimesMapBackOntoTheOriginalTimeline() {
        // Speech at 10–15 s and 30–34 s; compacted to 0–5 s and 5.3–9.3 s.
        let regions = [
            MeetingPipeline.SpeechRegion(compactStart: 0, originalStart: 10, duration: 5),
            MeetingPipeline.SpeechRegion(compactStart: 5.3, originalStart: 30, duration: 4),
        ]

        let inFirst = MeetingPipeline.mapToOriginal(start: 1, end: 3, regions: regions)
        XCTAssertEqual(inFirst.count, 1)
        XCTAssertEqual(inFirst[0].start, 11, accuracy: 0.001)
        XCTAssertEqual(inFirst[0].end, 13, accuracy: 0.001)

        let inSecond = MeetingPipeline.mapToOriginal(start: 6, end: 8, regions: regions)
        XCTAssertEqual(inSecond.count, 1)
        XCTAssertEqual(inSecond[0].start, 30.7, accuracy: 0.001)

        // A segment the compaction glued across both stretches splits again,
        // and the padding in between belongs to nobody.
        let spanning = MeetingPipeline.mapToOriginal(start: 4, end: 7, regions: regions)
        XCTAssertEqual(spanning.count, 2)
        XCTAssertEqual(spanning[0].start, 14, accuracy: 0.001)
        XCTAssertEqual(spanning[0].end, 15, accuracy: 0.001)
        XCTAssertEqual(spanning[1].start, 30, accuracy: 0.001)
        XCTAssertEqual(spanning[1].end, 31.7, accuracy: 0.001)

        XCTAssertTrue(MeetingPipeline.mapToOriginal(start: 5.0, end: 5.2, regions: regions).isEmpty,
                      "Reines Padding darf keinem Sprecher zugeschrieben werden")
    }
}
