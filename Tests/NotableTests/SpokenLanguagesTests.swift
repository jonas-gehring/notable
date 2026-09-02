import NaturalLanguage
import XCTest
@testable import Notable

/// Spec 11 Teil B. This is the one part of that spec that sits in the **core
/// path** — `polish()` runs on every dictation — so the language profile is
/// tested rather than trusted.
final class SpokenLanguagesTests: XCTestCase {
    // MARK: - Storage

    func testDefaultProfileIsGermanAndEnglish() {
        let store = UserDefaults(suiteName: "Lang.\(UUID().uuidString)")!
        XCTAssertEqual(SpokenLanguages.load(store), ["de", "en"])
    }

    /// The last language cannot be taken away — an empty profile would leave the
    /// recognizer unconstrained again, which is the state this type prevents.
    func testEmptyProfileFallsBackInsteadOfBecomingUnconstrained() {
        let store = UserDefaults(suiteName: "Lang.\(UUID().uuidString)")!
        SpokenLanguages.save([], store: store)
        XCTAssertEqual(SpokenLanguages.load(store), ["de"])
    }

    func testUnsupportedCodesAreDropped() {
        let store = UserDefaults(suiteName: "Lang.\(UUID().uuidString)")!
        SpokenLanguages.save(["de", "fr", "klingon"], store: store)
        XCTAssertEqual(SpokenLanguages.load(store), ["de"])
    }

    func testConstraintsMapToNLLanguage() {
        XCTAssertEqual(SpokenLanguages.constraints(["de", "en"]), [.german, .english])
        XCTAssertEqual(SpokenLanguages.constraints([]), [.german])
    }

    // MARK: - Detection

    func testEnglishTextIsDetectedUnderTheDefaultProfile() {
        XCTAssertTrue(TextPolisher.isEnglish("This is clearly an English sentence about the weather."))
    }

    func testGermanTextIsNotEnglishUnderTheDefaultProfile() {
        XCTAssertFalse(TextPolisher.isEnglish("Das ist eindeutig ein deutscher Satz über das Wetter."))
    }

    /// A profile without English can never report English — intended, not a side
    /// effect: English fillers and ITN are then off for good.
    func testProfileWithoutEnglishNeverReportsEnglish() {
        XCTAssertFalse(TextPolisher.isEnglish("This is undeniably an English sentence.", languages: ["de"]))
    }

    /// With only English possible, asking the recognizer would be theatre.
    func testProfileWithOnlyEnglishAlwaysReportsEnglish() {
        XCTAssertTrue(TextPolisher.isEnglish("Das ist deutsch.", languages: ["en"]))
    }

    // MARK: - Effect on polishing

    private func options(_ languages: [String]) -> TextPolisher.Options {
        var options = TextPolisher.Options()
        options.applyFuzzyDictionary = false
        options.paragraphs = false
        options.structureCommands = false
        options.spokenLanguages = languages
        return options
    }

    func testEnglishFillersAreRemovedForAnEnglishProfile() {
        let result = TextPolisher.polish("So um I think uh that works.", options: options(["en"]))
        XCTAssertFalse(result.lowercased().contains(" um "), result)
        XCTAssertFalse(result.lowercased().contains(" uh "), result)
    }

    /// The reason the whole profile exists: "er" and "um" are ordinary German
    /// words, and a misdetected German sentence loses them.
    func testGermanProfileKeepsGermanWordsThatLookLikeEnglishFillers() {
        let text = "Er kommt um acht, und um neun gehen wir."
        let result = TextPolisher.polish(text, options: options(["de"]))
        XCTAssertTrue(result.contains("Er kommt um acht"), result)
        XCTAssertTrue(result.contains("um neun"), result)
    }

    /// Universal fillers are language-independent and must still go.
    func testUniversalFillersGoInEveryProfile() {
        for profile in [["de"], ["en"], ["de", "en"]] {
            let result = TextPolisher.polish("Das ist ähm wichtig.", options: options(profile))
            XCTAssertFalse(result.contains("ähm"), "Profil \(profile): \(result)")
        }
    }

    /// The default profile must behave exactly as the code did before Spec 11 on
    /// unambiguous input — the profile constrains guessing, it does not change
    /// what a clear sentence is.
    func testDefaultProfileMatchesThePreviousBehaviourOnClearInput() {
        let english = TextPolisher.polish("So um I really think uh this works.", options: options(["de", "en"]))
        XCTAssertFalse(english.lowercased().contains(" um "), english)

        let german = TextPolisher.polish("Er kommt um acht Uhr an.", options: options(["de", "en"]))
        XCTAssertTrue(german.contains("Er kommt um acht"), german)
    }

    // MARK: - Whisper

    func testSingleLanguageProfilePinsWhispersLanguage() {
        let pinned = WhisperTranscriber.decodingOptions(languages: ["de"])
        XCTAssertEqual(pinned.language, "de")
        XCTAssertFalse(pinned.detectLanguage ?? true)
    }

    func testTwoLanguagesLeaveDetectionOn() {
        let detecting = WhisperTranscriber.decodingOptions(languages: ["de", "en"])
        XCTAssertNil(detecting.language)
        XCTAssertTrue(detecting.detectLanguage ?? false)
    }

    /// Never `.translate` — that is how German speech came back in English.
    func testTaskIsAlwaysTranscribe() {
        XCTAssertEqual(WhisperTranscriber.decodingOptions(languages: ["de"]).task, .transcribe)
        XCTAssertEqual(WhisperTranscriber.decodingOptions(languages: ["de", "en"]).task, .transcribe)
    }

    func testEmptyProfileFallsBackForWhisperToo() {
        XCTAssertEqual(WhisperTranscriber.decodingOptions(languages: []).language, "de")
    }
}
