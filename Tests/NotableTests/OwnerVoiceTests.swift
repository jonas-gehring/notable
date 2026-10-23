import XCTest

/// Which voice on a shared microphone is "Ich", and the honest answer when
/// the levels do not say.
final class OwnerVoiceTests: XCTestCase {
    func testTheClearlyLoudestVoiceIsTheUser() {
        let owner = OwnerVoice.owner(levels: ["1": [-30, -32, -31], "2": [-20, -21, -19]], large: ["1", "2"])
        XCTAssertEqual(owner, "2")
    }

    func testWithoutAClearLeadThereIsNoUser() {
        XCTAssertNil(OwnerVoice.owner(levels: ["1": [-20], "2": [-21.5]], large: ["1", "2"]))
    }

    /// A splinter is not a voice, however loud.
    func testOnlyLargeClustersCount() {
        let owner = OwnerVoice.owner(levels: ["1": [-30], "2": [-24], "3": [-5]], large: ["1", "2"])
        XCTAssertEqual(owner, "2")
    }

    func testDisplayLabelsCountUpAgainWithoutTheUser() {
        let labels = OwnerVoice.displayLabels(clusters: ["1", "2", "3", "?"], owner: "2")
        XCTAssertEqual(labels, ["1": "Sprecher 1", "2": "Ich", "3": "Sprecher 2", "?": "Sprecher ?"])
        XCTAssertEqual(OwnerVoice.displayLabels(clusters: ["1", "2"], owner: nil), ["1": "Sprecher 1", "2": "Sprecher 2"])
    }

    func testDecibels() {
        XCTAssertEqual(OwnerVoice.decibels([Float](repeating: 1, count: 100)[...]), 0, accuracy: 0.001)
        XCTAssertEqual(OwnerVoice.decibels([Float](repeating: 0.1, count: 100)[...]), -20, accuracy: 0.001)
        XCTAssertEqual(OwnerVoice.decibels([Float](repeating: 0, count: 100)[...]), -120)
        XCTAssertEqual(OwnerVoice.decibels([]), -120)
    }

    func testMedian() {
        XCTAssertEqual(OwnerVoice.median([3, 1, 2]), 2)
        XCTAssertEqual(OwnerVoice.median([4, 1, 2, 3]), 2.5)
        XCTAssertNil(OwnerVoice.median([]))
    }

    // MARK: - The microphone split, without the models

    private let rate = PCMDownsampler.targetSampleRate

    /// 40 s: cluster "1" speaks 0–10 s and 20–30 s at `loud`, cluster "2"
    /// 10–20 s and 30–40 s at `quiet`. The diarization is handed over as the
    /// models would hand it, on a timeline the regions map one to one.
    private func split(loud: Float, quiet: Float, onlyOne: Bool = false) -> MeetingPipeline.MicrophoneVoices? {
        var samples: [Float] = []
        var segments: [SpeakerClusterCleanup.Segment] = []
        for (index, start) in stride(from: 0, to: 40, by: 10).enumerated() {
            let label = onlyOne || index.isMultiple(of: 2) ? "1" : "2"
            samples += [Float](repeating: label == "1" ? loud : quiet, count: rate * 10)
            segments.append(.init(label: label, start: TimeInterval(start), end: TimeInterval(start + 10), embedding: [], quality: 1))
        }
        let diarization = MeetingPipeline.Diarization(
            raw: segments, cleaned: segments,
            regions: [.init(compactStart: 0, originalStart: 0, duration: 40)]
        )
        return MeetingPipeline.microphoneVoices(diarization, samples: samples)
    }

    func testTheMicrophoneSplitsIntoTheUserAndTheOtherVoice() throws {
        let result = try XCTUnwrap(split(loud: 0.5, quiet: 0.1))
        XCTAssertTrue(result.ownerFound)
        XCTAssertEqual(result.specs.map(\.speaker), ["Ich", "Sprecher 1", "Ich", "Sprecher 1"])
        XCTAssertEqual(result.specs.map(\.start), [0, 10, 20, 30])
        XCTAssertTrue(result.specs.allSatisfy { $0.track == .microphone })
        XCTAssertEqual(result.seconds, ["Sprecher 1": 20])
    }

    func testTwoVoicesAtTheSameLevelStayNumbers() throws {
        let result = try XCTUnwrap(split(loud: 0.2, quiet: 0.19))
        XCTAssertFalse(result.ownerFound)
        XCTAssertEqual(Set(result.specs.compactMap(\.speaker)), ["Sprecher 1", "Sprecher 2"])
    }

    /// One voice on the microphone is the user alone: nothing changes.
    func testASingleVoiceLeavesTheMicrophoneAlone() {
        XCTAssertNil(split(loud: 0.5, quiet: 0.1, onlyOne: true))
    }
}
