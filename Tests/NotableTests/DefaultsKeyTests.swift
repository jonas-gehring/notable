import XCTest

/// A key and the value it means when unset belong together. These tests pin
/// what used to be two separate facts in two files.
final class DefaultsKeyTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "notable-defaults-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// `defaults.bool(forKey:)` answers `false` for "never set", which is the
    /// wrong answer for every switch that is on by default — the whole reason
    /// this type exists.
    func testUnsetKeyMeansTheDeclaredFallbackAndNotFalse() {
        XCTAssertTrue(DefaultsKey.autoRecordMeetings.value(defaults))
        XCTAssertTrue(DefaultsKey.speakerNamingEnabled.value(defaults))
        XCTAssertFalse(DefaultsKey.dictationSounds.value(defaults))
        XCTAssertEqual(DefaultsKey.typingWPM.value(defaults), 40)
        XCTAssertEqual(DefaultsKey.meetingHookPath.value(defaults), "")
        XCTAssertFalse(defaults.bool(forKey: DefaultsKey.autoRecordMeetings.key),
                       "Genau der Unterschied, um den es geht")
    }

    func testAStoredValueWins() {
        defaults.set(false, forKey: DefaultsKey.autoRecordMeetings.key)
        XCTAssertFalse(DefaultsKey.autoRecordMeetings.value(defaults))
        defaults.set(90.0, forKey: DefaultsKey.typingWPM.key)
        XCTAssertEqual(DefaultsKey.typingWPM.value(defaults), 90)
    }

    /// The keys only moved; renaming one loses a setting the user made, with no
    /// message and no way back. So the strings themselves are pinned.
    func testTheStringsAreTheOnesAlreadyOnDisk() {
        XCTAssertEqual(DefaultsKey.summarizationProvider.key, "summarizationProvider")
        XCTAssertEqual(DefaultsKey.typingWPM.key, "typingWPM")
        XCTAssertEqual(DefaultsKey.didCompleteOnboarding.key, "didCompleteOnboarding")
        XCTAssertEqual(DefaultsKey.meetingNotesFloating.key, "meetingNotesFloating")
        XCTAssertEqual(DefaultsKey.appStatistics.key, "appStatistics")
        XCTAssertEqual(DefaultsKey.polishRemoveFillers.key, "polishRemoveFillers")
    }

    /// `TextPolisher.Options` declares its own defaults, and `fromDefaults()`
    /// now fills them from `DefaultsKey`. The two are the same value by
    /// construction — a switch whose "off" and whose "never touched" disagree
    /// is a bug nobody would look for in a polish option.
    func testPolishFallbacksMatchTheOptionDefaults() {
        let options = TextPolisher.Options()
        XCTAssertEqual(DefaultsKey.polishRemoveFillers.fallback, options.removeFillers)
        XCTAssertEqual(DefaultsKey.polishApplyITN.fallback, options.applyITN)
        XCTAssertEqual(DefaultsKey.polishFuzzyDictionary.fallback, options.applyFuzzyDictionary)
        XCTAssertEqual(DefaultsKey.polishParagraphs.fallback, options.paragraphs)
        XCTAssertEqual(DefaultsKey.polishStructureCommands.fallback, options.structureCommands)
    }
}
