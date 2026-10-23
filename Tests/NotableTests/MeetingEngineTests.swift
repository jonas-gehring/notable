import XCTest

/// Which model transcribes a meeting, and the one language Whisper settles on.
final class MeetingEngineTests: XCTestCase {
    // MARK: - Die Wahl und der alte Schalter

    /// Before the picker there was only "Meetings mit dem gewählten
    /// Diktat-Modell transkribieren". Whoever had it on keeps that.
    func testWithoutAStoredChoiceTheOldSwitchDecides() {
        XCTAssertEqual(MeetingEngineChoice(stored: "", useDictationEngine: false), .parakeet)
        XCTAssertEqual(MeetingEngineChoice(stored: "", useDictationEngine: true), .dictation)
        XCTAssertEqual(MeetingEngineChoice(stored: "unbekannt", useDictationEngine: true), .dictation)
    }

    func testAStoredChoiceWins() {
        XCTAssertEqual(MeetingEngineChoice(stored: "whisper-turbo", useDictationEngine: true), .whisperTurbo)
        XCTAssertEqual(MeetingEngineChoice(stored: "parakeet", useDictationEngine: true), .parakeet)
    }

    /// Written back and read again, every position comes out as itself, and
    /// the old key says "like dictation" only for that position.
    func testEveryChoiceRoundTrips() {
        for choice in MeetingEngineChoice.allCases {
            XCTAssertEqual(MeetingEngineChoice(stored: choice.rawValue, useDictationEngine: choice.usesDictationEngine), choice)
            XCTAssertEqual(MeetingEngineChoice(stored: "", useDictationEngine: choice.usesDictationEngine),
                           choice == .dictation ? .dictation : .parakeet)
        }
    }

    // MARK: - Eine Sprache pro Meeting

    func testOneLanguageInTheProfileIsPinnedFromTheStart() {
        XCTAssertEqual(MeetingLanguagePin(allowed: ["de"]).pinned, "de")
        XCTAssertNil(MeetingLanguagePin(allowed: ["de", "en"]).pinned)
    }

    func testTheFirstMinuteDecides() {
        var pin = MeetingLanguagePin(allowed: ["de", "en"])
        pin.record("en", seconds: 5)
        pin.record("de", seconds: 30)
        XCTAssertNil(pin.pinned, "nach 35 s ist noch nichts entschieden")
        pin.record("de", seconds: 25)
        XCTAssertEqual(pin.pinned, "de")
        // Once pinned, nothing moves it any more.
        pin.record("en", seconds: 600)
        XCTAssertEqual(pin.pinned, "de")
    }

    /// A short slice detected as Dutch is the misdetection the pin is for,
    /// not a vote.
    func testLanguagesOutsideTheProfileAreNotCounted() {
        var pin = MeetingLanguagePin(allowed: ["de", "en"])
        pin.record("nl", seconds: 120)
        pin.record(nil, seconds: 120)
        XCTAssertNil(pin.pinned)
        XCTAssertTrue(pin.needsRetry(detected: "nl"))
        XCTAssertFalse(pin.needsRetry(detected: "en"))
        XCTAssertFalse(pin.needsRetry(detected: nil))
    }

    func testATieGoesToTheProfilesFirstLanguage() {
        var pin = MeetingLanguagePin(allowed: ["de", "en"])
        pin.record("en", seconds: 30)
        pin.record("de", seconds: 30)
        XCTAssertEqual(pin.pinned, "de")
    }

    // MARK: - Modellordner

    /// The meetings' Whisper model is not a dictation size, but it is no
    /// leftover either: offered for deletion, it would be gone at the next call.
    func testTheMeetingModelIsNotOrphaned() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-whisper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(ModelInventory.meetingWhisperDirectory), withIntermediateDirectories: true)

        let idle = ModelInventory.scanWhisper(root: root, inUse: [])
        XCTAssertEqual(idle.first?.state, .available)
        XCTAssertEqual(idle.first?.name, "Whisper large-v3-turbo")
        let chosen = ModelInventory.scanWhisper(root: root, inUse: [ModelInventory.meetingWhisperDirectory])
        XCTAssertEqual(chosen.first?.state, .inUse)
    }
}
