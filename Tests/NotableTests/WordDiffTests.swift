import XCTest

final class WordDiffTests: XCTestCase {
    /// Compare against expected [(heard, corrected)] pairs (tuples aren't Equatable).
    private func assertPairs(_ actual: [(heard: String, corrected: String)],
                             _ expected: [(String, String)],
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count,
                       "pair count mismatch: \(actual)", file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.heard, e.0, file: file, line: line)
            XCTAssertEqual(a.corrected, e.1, file: file, line: line)
        }
    }

    func testSingleSubstitution() {
        let pairs = WordDiff.substitutions(from: "danke Hofmann", to: "danke Hoffmann")
        assertPairs(pairs, [("Hofmann", "Hoffmann")])
    }

    func testSubstitutionSurroundedByStableWords() {
        let pairs = WordDiff.substitutions(from: "a Hofmann b", to: "a Hoffmann b")
        assertPairs(pairs, [("Hofmann", "Hoffmann")])
    }

    func testPureInsertionYieldsNoPair() {
        let pairs = WordDiff.substitutions(from: "hallo welt", to: "hallo schöne welt")
        assertPairs(pairs, [])
    }

    func testPureDeletionYieldsNoPair() {
        let pairs = WordDiff.substitutions(from: "hallo schöne welt", to: "hallo welt")
        assertPairs(pairs, [])
    }

    func testTwoAdjacentSubstitutions() {
        // "der" → "die" and "Hofmann" → "Hoffmann"; "kam" is the common anchor.
        let pairs = WordDiff.substitutions(from: "der Hofmann kam", to: "die Hoffmann kam")
        assertPairs(pairs, [("der", "die"), ("Hofmann", "Hoffmann")])
    }

    func testCaseOnlyDifferenceIgnored() {
        let pairs = WordDiff.substitutions(from: "Hallo", to: "hallo")
        assertPairs(pairs, [])
    }

    func testTrailingPunctuationStripped() {
        let pairs = WordDiff.substitutions(from: "danke Hofmann,", to: "danke Hoffmann")
        assertPairs(pairs, [("Hofmann", "Hoffmann")])
    }

    func testUnequalReplacementRunLengthsSkipped() {
        // Two old words replaced by one new word — ambiguous, no pair.
        let pairs = WordDiff.substitutions(from: "a X Y b", to: "a Z b")
        assertPairs(pairs, [])
    }
}
