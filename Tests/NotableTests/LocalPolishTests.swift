import XCTest
@testable import Notable

/// Spec 32, the part that needs no model: when the on-device stage runs and
/// what of its answer is allowed into a foreign text field.
final class LocalPolishTests: XCTestCase {
    private let long = Array(repeating: "wort", count: 30).joined(separator: " ")

    // MARK: - When

    func testOffNeverRuns() {
        XCTAssertFalse(LocalPolish.shouldRun(mode: .off, category: .prose, text: long))
    }

    func testLongRunsFromTheThreshold() {
        let short = Array(repeating: "wort", count: 24).joined(separator: " ")
        let exact = Array(repeating: "wort", count: 25).joined(separator: " ")
        XCTAssertFalse(LocalPolish.shouldRun(mode: .long, category: .prose, text: short))
        XCTAssertTrue(LocalPolish.shouldRun(mode: .long, category: .prose, text: exact))
    }

    func testAlwaysRunsOnShortText() {
        XCTAssertTrue(LocalPolish.shouldRun(mode: .always, category: .mail, text: "ja passt"))
    }

    /// Verbatim means verbatim.
    func testNeverInACodeEditor() {
        XCTAssertFalse(LocalPolish.shouldRun(mode: .always, category: .code, text: long))
    }

    func testModeFallsBackToOffForUnknownValues() throws {
        let suite = "LocalPolishTests-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LocalPolish.Mode.current(store), .off)
        store.set("unsinn", forKey: LocalPolish.Mode.storageKey)
        XCTAssertEqual(LocalPolish.Mode.current(store), .off)
        store.set("long", forKey: LocalPolish.Mode.storageKey)
        XCTAssertEqual(LocalPolish.Mode.current(store), .long)
    }

    // MARK: - What survives

    /// The whole point of the stage: a self-correction deletes what it corrects.
    func testSelfCorrectionMayRemoveANameAndANumber() {
        XCTAssertEqual(
            LocalPolish.accept("Schick das an Moritz, um 15 Uhr.",
                               forInput: "schick das an Max ich meine an Moritz um 14 Uhr nein 15 Uhr"),
            "Schick das an Moritz, um 15 Uhr."
        )
    }

    func testAnInventedNumberIsRejected() {
        XCTAssertNil(LocalPolish.accept("Wir treffen uns um 16 Uhr im Büro.",
                                        forInput: "wir treffen uns um 15 Uhr im Büro"))
    }

    func testAnInventedNameIsRejected() {
        XCTAssertNil(LocalPolish.accept("Hallo Anna, wir sehen uns morgen im Büro.",
                                        forInput: "hallo wir sehen uns morgen im büro"))
    }

    /// Capitalizing a sentence start is formatting, not invention.
    func testNewCapitalsOnExistingWordsAreFine() {
        XCTAssertEqual(
            LocalPolish.accept("Das passt. Dann machen wir das so.", forInput: "das passt dann machen wir das so"),
            "Das passt. Dann machen wir das so."
        )
    }

    func testCommentaryIsStillRejected() {
        XCTAssertNil(LocalPolish.accept("Hier ist der überarbeitete Text: Das passt.",
                                        forInput: "das passt dann machen wir das so"))
    }

    func testListFormattingIsAccepted() {
        let input = "wir brauchen erstens milch zweitens brot und drittens eier für morgen früh"
        XCTAssertEqual(
            LocalPolish.accept("Wir brauchen:\n- Milch\n- Brot\n- Eier\n\nfür morgen früh.", forInput: input),
            "Wir brauchen:\n- Milch\n- Brot\n- Eier\n\nfür morgen früh."
        )
    }

    // MARK: - Prompt

    func testPromptCarriesTheTextAndTheTarget() {
        let prompt = LocalPolish.prompt(for: "hallo welt", category: .chat)
        XCTAssertTrue(prompt.hasSuffix("hallo welt"))
        XCTAssertTrue(prompt.contains("Chat-Nachricht"))
    }

    func testNumberAndWordExtraction() {
        XCTAssertEqual(LocalPolish.numbers(in: "um 8:30 Uhr für 22,50 € und 1.000 Leute"), ["8:30", "22,50", "1.000"])
        XCTAssertEqual(LocalPolish.words(in: "Müller-Lüdenscheidt's Büro, 3 Tage"), ["Müller-Lüdenscheidt's", "Büro", "Tage"])
    }
}
