import XCTest

/// Spec 36, Stufe 3: the three locks that stand between a voice and a name.
///
/// The threshold itself is a starting value and deliberately not tested for a
/// number — §3.4 measures it. What is tested is the *rule*: nothing is named on
/// a coin toss, a name is used once per meeting, and a correction moves the
/// profile rather than leaving it wrong.
final class VoiceProfilesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// A unit vector in the plane, `degrees` away from the x-axis — so a
    /// distance can be written down instead of guessed.
    private func voice(_ degrees: Double) -> [Float] {
        let radians = degrees * .pi / 180
        return [Float(cos(radians)), Float(sin(radians)), 0]
    }

    private func profile(_ name: String, _ vector: [Float], meetings: Int = 1) -> VoiceProfiles.Profile {
        VoiceProfiles.Profile(id: VoiceProfiles.identifier(for: name), name: name, sum: vector,
                              meetings: meetings, createdAt: now, updatedAt: now)
    }

    func testTheSameNameIsOneProfileHoweverItIsWritten() {
        XCTAssertEqual(VoiceProfiles.identifier(for: "Anna  Weber"), VoiceProfiles.identifier(for: "anna weber"))
        XCTAssertNotEqual(VoiceProfiles.identifier(for: "Anna Weber"), VoiceProfiles.identifier(for: "Anna Weberin"))
    }

    func testDistanceIsCosineAndUnusableVectorsAreAsFarAwayAsPossible() {
        XCTAssertEqual(VoiceProfiles.distance(voice(0), voice(0)), 0, accuracy: 1e-5)
        XCTAssertEqual(VoiceProfiles.distance(voice(0), voice(90)), 1, accuracy: 1e-5)
        // A length mismatch and a zero vector are never a lucky hit.
        XCTAssertEqual(VoiceProfiles.distance([1, 0, 0], [1, 0]), 2, accuracy: 1e-5)
        XCTAssertEqual(VoiceProfiles.distance([0, 0, 0], voice(0)), 2, accuracy: 1e-5)
    }

    func testACloseVoiceTakesTheName() {
        let matches = VoiceProfiles.assign(
            [.init(cluster: "Sprecher 1", centroid: voice(10))],
            profiles: [profile("Anna Weber", voice(0)), profile("Ben Kraus", voice(90))]
        )
        XCTAssertEqual(matches.map(\.name), ["Anna Weber"])
        XCTAssertEqual(matches.first?.cluster, "Sprecher 1")
    }

    func testAVoiceBeyondTheThresholdKeepsItsNumber() {
        let matches = VoiceProfiles.assign(
            [.init(cluster: "Sprecher 1", centroid: voice(70))],
            profiles: [profile("Anna Weber", voice(0))]
        )
        XCTAssertTrue(matches.isEmpty, "0,66 Abstand ist keine Stimmübereinstimmung")
    }

    /// The rule from Spec 24 §9.2, here as well: where the voice cannot decide,
    /// nobody decides.
    func testTwoProfilesWithinTheMarginNameNobody() {
        let matches = VoiceProfiles.assign(
            [.init(cluster: "Sprecher 1", centroid: voice(20))],
            profiles: [profile("Anna Weber", voice(0)), profile("Ben Kraus", voice(40))],
            threshold: 0.5, margin: 0.1
        )
        XCTAssertTrue(matches.isEmpty, "zwei fast gleich nahe Profile sind ein Münzwurf")
    }

    func testANameIsUsedOnceAndTheBetterMatchGetsIt() {
        let matches = VoiceProfiles.assign(
            [.init(cluster: "Sprecher 1", centroid: voice(20)), .init(cluster: "Sprecher 2", centroid: voice(5))],
            profiles: [profile("Anna Weber", voice(0))],
            threshold: 0.5, margin: 0.1
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.cluster, "Sprecher 2", "der nähere Cluster bekommt den Namen")
    }

    func testANameAnotherSourceAlreadyGaveIsNotHandedOutAgain() {
        let matches = VoiceProfiles.assign(
            [.init(cluster: "Sprecher 2", centroid: voice(5))],
            profiles: [profile("Anna Weber", voice(0))],
            taken: ["anna  weber"]
        )
        XCTAssertTrue(matches.isEmpty, "der Bildschirm hat den Namen schon vergeben")
    }

    // MARK: - Lernen und Zurückziehen

    func testAddingAndRemovingAreExactInverses() throws {
        let first = try XCTUnwrap(VoiceProfiles.adding(voice(0), to: nil, name: "Anna Weber", at: now))
        XCTAssertEqual(first.meetings, 1)
        let second = try XCTUnwrap(VoiceProfiles.adding(voice(30), to: first, name: "Anna Weber", at: now))
        XCTAssertEqual(second.meetings, 2)

        let back = try XCTUnwrap(VoiceProfiles.removing(voice(30), from: second, at: now))
        XCTAssertEqual(back.meetings, 1)
        // The sum is what makes this exact — a stored mean could not be undone.
        for (left, right) in zip(back.sum, first.sum) {
            XCTAssertEqual(left, right, accuracy: 1e-5)
        }
    }

    /// A profile that was built from one meeting and loses it is not a voice
    /// any more — it is nothing, and nothing is deleted rather than kept at zero.
    func testRetractingTheOnlyMeetingEndsTheProfile() throws {
        let only = try XCTUnwrap(VoiceProfiles.adding(voice(0), to: nil, name: "Anna Weber", at: now))
        XCTAssertNil(VoiceProfiles.removing(voice(0), from: only, at: now))
    }

    func testAProfileIsComparedByItsDirectionNotItsLength() throws {
        let one = try XCTUnwrap(VoiceProfiles.adding(voice(0), to: nil, name: "Anna", at: now))
        let two = try XCTUnwrap(VoiceProfiles.adding(voice(0), to: one, name: "Anna", at: now))
        let vector = try XCTUnwrap(two.vector)
        XCTAssertEqual(VoiceProfiles.distance(vector, voice(0)), 0, accuracy: 1e-5)
    }

    func testTheBlobRoundTripsExactly() {
        let vector: [Float] = [0.5, -0.25, 0.125, 0]
        XCTAssertEqual(VoiceProfiles.decode(VoiceProfiles.encode(vector)), vector)
        XCTAssertEqual(VoiceProfiles.decode(Data()), [])
    }
}
