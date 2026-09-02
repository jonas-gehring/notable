import XCTest

/// Spec 06 — dictionary auto-learn: tally, promote, dismiss/tombstone, and the
/// suggestion filtering (already-active / dismissed excluded).
final class PersonalDictionaryLearnTests: XCTestCase {
    private func makeStore() -> UserDefaults {
        UserDefaults(suiteName: "dict-test-\(UUID().uuidString)")!
    }

    func testSuggestionOnlyAfterMinCount() {
        let store = makeStore()
        PersonalDictionary.recordCorrection(heard: "hofmann", corrected: "Hoffmann", store: store)
        XCTAssertTrue(PersonalDictionary.learnedSuggestions(store: store).isEmpty)
        PersonalDictionary.recordCorrection(heard: "hofmann", corrected: "Hoffmann", store: store)
        XCTAssertEqual(PersonalDictionary.learnedSuggestions(store: store)["hofmann"], "Hoffmann")
    }

    func testMostFrequentCorrectionWins() {
        let store = makeStore()
        for _ in 0..<3 { PersonalDictionary.recordCorrection(heard: "hofmann", corrected: "Hoffmann", store: store) }
        for _ in 0..<2 { PersonalDictionary.recordCorrection(heard: "hofmann", corrected: "Goering", store: store) }
        XCTAssertEqual(PersonalDictionary.learnedSuggestions(store: store)["hofmann"], "Hoffmann")
    }

    func testPromoteAddsToActiveAndClearsSuggestion() {
        let store = makeStore()
        for _ in 0..<2 { PersonalDictionary.recordCorrection(heard: "hofmann", corrected: "Hoffmann", store: store) }
        PersonalDictionary.promote(heard: "hofmann", corrected: "Hoffmann", store: store)
        let active = store.dictionary(forKey: PersonalDictionary.defaultsKey) as? [String: String]
        XCTAssertEqual(active?["hofmann"], "Hoffmann")
        XCTAssertTrue(PersonalDictionary.learnedSuggestions(store: store).isEmpty)
    }

    func testDismissTombstonesSoItNeverReturns() {
        let store = makeStore()
        for _ in 0..<2 { PersonalDictionary.recordCorrection(heard: "hofmann", corrected: "Hoffmann", store: store) }
        PersonalDictionary.dismiss(heard: "hofmann", store: store)
        XCTAssertTrue(PersonalDictionary.learnedSuggestions(store: store).isEmpty)
        // Seeing the same correction again must not resurface a dismissed form.
        for _ in 0..<3 { PersonalDictionary.recordCorrection(heard: "hofmann", corrected: "Hoffmann", store: store) }
        XCTAssertTrue(PersonalDictionary.learnedSuggestions(store: store).isEmpty)
    }
}
