import XCTest
@testable import Notable

/// Spec 31 §3.2. A wrong number is worse than a spelled-out one, so most of
/// these check what must *not* change.
final class GermanITNTests: XCTestCase {
    // MARK: - Number words

    func testCardinalDecomposition() {
        let cases: [(String, Int)] = [
            ("null", 0), ("eins", 1), ("zwei", 2), ("sieben", 7), ("zehn", 10), ("elf", 11), ("zwölf", 12),
            ("dreizehn", 13), ("sechzehn", 16), ("siebzehn", 17), ("neunzehn", 19),
            ("zwanzig", 20), ("dreißig", 30), ("dreissig", 30), ("sechzig", 60), ("siebzig", 70), ("neunzig", 90),
            ("einundzwanzig", 21), ("zweiundzwanzig", 22), ("siebenundsiebzig", 77), ("neunundneunzig", 99),
            ("hundert", 100), ("einhundert", 100), ("einhunderteins", 101), ("einhundertelf", 111),
            ("dreihundertfünf", 305), ("sechshundertsechsundsechzig", 666), ("neunhundertneunundneunzig", 999),
            ("tausend", 1_000), ("eintausend", 1_000), ("tausendeins", 1_001),
            ("zweitausend", 2_000), ("zweitausendvierundzwanzig", 2_024),
            ("neunzehnhundert", 1_900), ("neunzehnhundertvierundachtzig", 1_984),
            ("zweiundzwanzigtausend", 22_000), ("hunderttausend", 100_000),
            ("dreihundertfünfundsechzigtausend", 365_000),
            ("zweitausendunddrei", 2_003), ("dreihundertundzwei", 302),
            ("Zweiundzwanzig", 22),
        ]
        for (word, value) in cases {
            XCTAssertEqual(GermanITN.cardinal(word), value, word)
        }
    }

    /// Words that merely contain number syllables.
    func testWordsThatAreNotNumbers() {
        for word in ["Stunden", "Kunde", "Hundertschaft", "Tausendfüßler", "und", "ein", "eine",
                     "hundertprozentig", "zweiundzwanzigste", "Achtung", "Elfen", "zwanzig-jährig",
                     "einundeinhalb", "dreizehnhundertzwölftausendfünf", ""] {
            XCTAssertNil(GermanITN.cardinal(word), word)
        }
    }

    func testOrdinals() {
        let cases: [(String, Int)] = [
            ("erste", 1), ("ersten", 1), ("erster", 1), ("zweiten", 2), ("dritter", 3), ("vierte", 4),
            ("siebten", 7), ("siebenten", 7), ("achten", 8), ("zwölften", 12), ("neunzehnten", 19),
            ("zwanzigsten", 20), ("einundzwanzigsten", 21), ("dreißigsten", 30), ("einunddreißigsten", 31),
        ]
        for (word, value) in cases {
            XCTAssertEqual(GermanITN.ordinal(word), value, word)
        }
        XCTAssertNil(GermanITN.ordinal("erstens"), "Listenkommando, keine Ordinalzahl")
        XCTAssertNil(GermanITN.ordinal("Treppe"))
    }

    func testGrouping() {
        XCTAssertEqual(GermanITN.digits(2_024), "2024")
        XCTAssertEqual(GermanITN.digits(9_999), "9999")
        XCTAssertEqual(GermanITN.digits(22_000), "22.000")
        XCTAssertEqual(GermanITN.digits(1_234_567), "1.234.567")
    }

    // MARK: - Normalization

    private func assertNormalizes(_ input: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(GermanITN.normalize(input), expected, file: file, line: line)
    }

    func testCardinalsFromThirteenUp() {
        assertNormalizes("Wir waren zweiundzwanzig Leute.", "Wir waren 22 Leute.")
        assertNormalizes("Das Haus hat dreihundertfünf Zimmer", "Das Haus hat 305 Zimmer")
        assertNormalizes("Es war neunzehnhundertvierundachtzig.", "Es war 1984.")
    }

    /// Duden: two to twelve stay words on their own.
    func testSmallNumbersStayWords() {
        assertNormalizes("Das dauert drei Tage.", "Das dauert drei Tage.")
        assertNormalizes("Wir sind zu zweit.", "Wir sind zu zweit.")
        assertNormalizes("Ein paar Minuten und eine Frage.", "Ein paar Minuten und eine Frage.")
        assertNormalizes("Gib acht darauf.", "Gib acht darauf.")
    }

    func testNumberRunsStayWords() {
        assertNormalizes("Die Durchwahl ist vier zwei dreizehn.", "Die Durchwahl ist vier zwei dreizehn.")
        assertNormalizes("zwanzig dreißig vierzig", "zwanzig dreißig vierzig")
    }

    func testIdiomsStayWords() {
        assertNormalizes("Tausend Dank für alles!", "Tausend Dank für alles!")
    }

    func testEuroAmounts() {
        assertNormalizes("Das kostet zweiundzwanzig Euro fünfzig.", "Das kostet 22,50\u{00A0}€.")
        assertNormalizes("Das kostet zwanzig Euro.", "Das kostet 20\u{00A0}€.")
        assertNormalizes("Das kostet drei Euro und fünfzig Cent", "Das kostet 3,50\u{00A0}€")
        assertNormalizes("Es waren zwölf Euro neunzig", "Es waren 12,90\u{00A0}€")
    }

    /// "fünfzig Leute" is a count of people, not fifty cents — and, from thirteen
    /// up, a count written in digits.
    func testCentsBeforeANounAreNotCents() {
        assertNormalizes("Für zehn Euro fünfzig Leute bewirten", "Für 10\u{00A0}€ 50 Leute bewirten")
    }

    func testOtherCurrenciesKeepTheirWord() {
        assertNormalizes("fünf Dollar", "5 Dollar")
        assertNormalizes("fünf Cent", "5 Cent")
        XCTAssertEqual(GermanITN.normalize("ein Euro"), "ein Euro", "Artikel, keine Zahl")
    }

    func testPercentAndDecimals() {
        assertNormalizes("Das sind zwanzig Prozent.", "Das sind 20\u{00A0}%.")
        assertNormalizes("zwei Prozent", "2\u{00A0}%")
        assertNormalizes("drei Komma fünf Prozent", "3,5\u{00A0}%")
        assertNormalizes("Pi ist drei Komma eins vier.", "Pi ist 3,14.")
        assertNormalizes("null Komma fünfundzwanzig", "0,25")
    }

    func testTimes() {
        assertNormalizes("Wir treffen uns um halb drei.", "Wir treffen uns um 2:30.")
        assertNormalizes("halb eins", "12:30")
        assertNormalizes("Viertel nach acht", "8:15")
        assertNormalizes("viertel vor acht", "7:45")
        assertNormalizes("Der Zug fährt um acht Uhr dreißig.", "Der Zug fährt um 8:30 Uhr.")
        assertNormalizes("Das beginnt acht Uhr", "Das beginnt 8 Uhr")
        assertNormalizes("Wir treffen uns um acht.", "Wir treffen uns um 8 Uhr.")
        assertNormalizes("um ein Uhr", "um 1 Uhr")
    }

    func testThingsThatLookLikeTimesButAreNot() {
        assertNormalizes("Das ist halb so wild.", "Das ist halb so wild.")
        assertNormalizes("Es geht um drei Personen.", "Es geht um drei Personen.")
        assertNormalizes("Um ein Haar!", "Um ein Haar!")
        assertNormalizes("um ein bisschen", "um ein bisschen")
        assertNormalizes("um acht zu sein", "um acht zu sein")
    }

    func testDates() {
        assertNormalizes("Am dritten März geht es los.", "Am 3. März geht es los.")
        assertNormalizes("der einunddreißigste Dezember zweitausendvierundzwanzig", "der 31. Dezember 2024")
        assertNormalizes("vom dritten bis zum fünften.", "vom 3. bis zum 5.")
        assertNormalizes("am zweiten", "am 2.")
    }

    func testOrdinalsThatAreNotDays() {
        assertNormalizes("Zum ersten Mal hier.", "Zum ersten Mal hier.")
        assertNormalizes("zum ersten, zum zweiten", "zum ersten, zum zweiten")
        assertNormalizes("am ersten Tag", "am ersten Tag")
        assertNormalizes("Wir achten darauf.", "Wir achten darauf.")
        assertNormalizes("Erstens das, zweitens das.", "Erstens das, zweitens das.")
    }

    /// Untouched text keeps its exact whitespace.
    func testUnchangedTextKeepsItsLineBreaks() {
        let text = "Hallo Max,\n\nwie geht es?"
        XCTAssertEqual(GermanITN.normalize(text), text)
    }
}
