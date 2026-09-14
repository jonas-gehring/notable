import Foundation

/// Conservative inverse text normalization for German dictation (Spec 31 §3.2):
/// numbers, ordinals before a month, dates, times, euro amounts, percentages and
/// "Komma" decimals.
///
/// Same rule as `EnglishITN`: **never mangle correct text.** A wrong number in a
/// mail is worse than a number spelled out, so every matcher declines what it is
/// not sure of. Concretely:
///
/// - **Two to twelve stay words** on their own ("drei Tage") — Duden convention,
///   and it keeps "acht" (Acht geben) and "elf" (die Elf) away from the digits.
///   An explicit unit changes that: "zwei Prozent", "drei Euro", "halb drei".
/// - **"ein"/"eine" are articles**, never numbers — except inside a compound
///   ("einundzwanzig") and in "ein Uhr".
/// - **A capitalized word after the number is a noun it counts**, not a minute,
///   a cent or a time: "zehn Euro fünfzig Leute", "um drei Personen". German
///   capitalizes nouns and Parakeet writes them that way, which is the one piece
///   of grammar this can lean on without a parser.
/// - Runs of number words ("vier zwei eins") are a phone number or a sequence and
///   stay as they are.
///
/// German number words are compounds — "zweitausendvierundzwanzig" is one token —
/// so the parser decomposes a single word rather than gathering a run, which is
/// the part `GermanITNTests` checks most closely.
enum GermanITN {
    typealias Tok = EnglishITN.Tok

    static func normalize(_ text: String) -> String {
        let tokens = EnglishITN.tokenize(text)
        guard !tokens.isEmpty else { return text }
        var out: [String] = []
        var changed = false
        var i = 0
        while i < tokens.count {
            if let (s, n) = firstMatch(tokens, i) {
                out.append(s)
                i += n
                changed = true
                continue
            }
            out.append(tokens[i].raw)
            i += 1
        }
        // Untouched text keeps its exact whitespace — the token join would
        // otherwise flatten line breaks for nothing.
        return changed ? out.joined(separator: " ") : text
    }

    /// Order matters: a time, a date or an amount claims its number before the
    /// plain cardinal rule sees it. Written out rather than as one `??` chain —
    /// seven optional tuples in one expression is more than the type checker takes.
    private static func firstMatch(_ tokens: [Tok], _ i: Int) -> (String, Int)? {
        if let result = matchTime(tokens, i) { return result }
        if let result = matchDate(tokens, i) { return result }
        if let result = matchCurrency(tokens, i) { return result }
        if let result = matchPercent(tokens, i) { return result }
        if let result = matchDecimal(tokens, i) { return result }
        if let result = matchContextOrdinal(tokens, i) { return result }
        return matchCardinal(tokens, i)
    }

    // MARK: - Number words

    private static let unitWords: [String: Int] = [
        "eins": 1, "zwei": 2, "drei": 3, "vier": 4, "fünf": 5,
        "sechs": 6, "sieben": 7, "acht": 8, "neun": 9,
    ]
    /// The form a unit takes inside a compound: "ein" in "einundzwanzig".
    private static let unitPrefixes: [String: Int] = [
        "ein": 1, "zwei": 2, "drei": 3, "vier": 4, "fünf": 5,
        "sechs": 6, "sieben": 7, "acht": 8, "neun": 9,
    ]
    private static let teenWords: [String: Int] = [
        "zehn": 10, "elf": 11, "zwölf": 12, "dreizehn": 13, "vierzehn": 14,
        "fünfzehn": 15, "sechzehn": 16, "siebzehn": 17, "achtzehn": 18, "neunzehn": 19,
    ]
    private static let tensWords: [String: Int] = [
        "zwanzig": 20, "dreißig": 30, "dreissig": 30, "vierzig": 40, "fünfzig": 50,
        "sechzig": 60, "siebzig": 70, "achtzig": 80, "neunzig": 90,
    ]
    private static let singleDigits: [String: Int] = unitWords.merging(["null": 0]) { a, _ in a }

    /// The value of one German cardinal word, or nil.
    ///
    /// "zweiundzwanzig" 22 · "dreihundertfünf" 305 · "neunzehnhundertvierundachtzig"
    /// 1984 · "zweitausendvierundzwanzig" 2024 · "zweiundzwanzigtausend" 22 000.
    /// Anything with a remainder the grammar does not account for is nil —
    /// "Stunden" contains "und", "Hundertschaft" contains "hundert".
    static func cardinal(_ word: String) -> Int? {
        let w = word.lowercased()
        guard !w.isEmpty, w.allSatisfy({ $0.isLetter }) else { return nil }
        if w == "null" { return 0 }
        if let r = w.range(of: "tausend") {
            let prefix = String(w[..<r.lowerBound])
            var rest = String(w[r.upperBound...])
            let multiplier: Int
            if prefix.isEmpty || prefix == "ein" {
                multiplier = 1
            } else if let m = belowThousand(prefix), (1 ..< 1_000).contains(m) {
                // A thousands multiplier is below a thousand: "zweiundzwanzigtausend",
                // never "dreizehnhundertzwölftausend".
                multiplier = m
            } else {
                return nil
            }
            if rest.hasPrefix("und") { rest.removeFirst(3) }
            if rest.isEmpty { return multiplier * 1_000 }
            guard let tail = belowThousand(rest) else { return nil }
            return multiplier * 1_000 + tail
        }
        return belowThousand(w)
    }

    private static func belowThousand(_ w: String) -> Int? {
        if let r = w.range(of: "hundert") {
            let prefix = String(w[..<r.lowerBound])
            var rest = String(w[r.upperBound...])
            let hundreds: Int
            if prefix.isEmpty || prefix == "ein" {
                hundreds = 1
            } else if let unit = unitPrefixes[prefix], unit >= 2 {
                hundreds = unit
            } else if let teen = teenWords[prefix], teen >= 11 {
                // "neunzehnhundert" — how years are said.
                hundreds = teen
            } else {
                return nil
            }
            if rest.hasPrefix("und") { rest.removeFirst(3) }
            if rest.isEmpty { return hundreds * 100 }
            guard let tail = belowHundred(rest) else { return nil }
            return hundreds * 100 + tail
        }
        return belowHundred(w)
    }

    private static func belowHundred(_ w: String) -> Int? {
        if let value = unitWords[w] ?? teenWords[w] ?? tensWords[w] { return value }
        if let r = w.range(of: "und") {
            let unit = String(w[..<r.lowerBound])
            let ten = String(w[r.upperBound...])
            if let u = unitPrefixes[unit], let t = tensWords[ten] { return u + t }
        }
        return nil
    }

    /// Digits the German way: plain up to four places (years, "2024"), grouped
    /// with a period from ten thousand ("22.000").
    static func digits(_ n: Int) -> String {
        let plain = String(n)
        guard n >= 10_000 else { return plain }
        var out: [Character] = []
        for (index, character) in plain.reversed().enumerated() {
            if index > 0, index % 3 == 0 { out.append(".") }
            out.append(character)
        }
        return String(out.reversed())
    }

    // MARK: - Ordinals

    private static let ordinalStems: [String: Int] = [
        "erst": 1, "zweit": 2, "dritt": 3, "viert": 4, "fünft": 5, "sechst": 6,
        "siebt": 7, "siebent": 7, "acht": 8, "neunt": 9, "zehnt": 10, "elft": 11,
        "zwölft": 12, "dreizehnt": 13, "vierzehnt": 14, "fünfzehnt": 15,
        "sechzehnt": 16, "siebzehnt": 17, "achtzehnt": 18, "neunzehnt": 19,
    ]
    private static let ordinalEndings = ["en", "er", "em", "es", "e"]

    /// "dritter" 3 · "ersten" 1 · "einunddreißigsten" 31. "erstens" is not an
    /// ordinal here — it is `ParagraphFormatter`'s list command.
    static func ordinal(_ word: String) -> Int? {
        let w = word.lowercased()
        for ending in ordinalEndings where w.hasSuffix(ending) {
            let stem = String(w.dropLast(ending.count))
            if let value = ordinalStems[stem] { return value }
            if stem.hasSuffix("st"), let value = cardinal(String(stem.dropLast(2))), value >= 20 {
                return value
            }
        }
        return nil
    }

    private static let months: [String: String] = [
        "januar": "Januar", "februar": "Februar", "märz": "März", "april": "April",
        "mai": "Mai", "juni": "Juni", "juli": "Juli", "august": "August",
        "september": "September", "oktober": "Oktober", "november": "November", "dezember": "Dezember",
    ]

    // MARK: - Guards

    /// A capitalized word right after `j` is a noun that `j` counts.
    private static func nounFollows(_ t: [Tok], _ j: Int) -> Bool {
        guard j + 1 < t.count, t[j].trail.isEmpty else { return false }
        guard let first = t[j + 1].raw.first(where: { $0.isLetter }) else { return false }
        return first.isUppercase && t[j + 1].core != "uhr"
    }

    /// "2." followed by the sentence's own period must not become "2..".
    private static func ordinalText(_ value: Int, trail: String) -> String {
        trail.hasPrefix(".") ? "\(value)." + trail.dropFirst() : "\(value)." + trail
    }

    /// A number on its own, or "<n> Komma <digits>".
    private static func quantity(_ t: [Tok], _ i: Int) -> (text: String, consumed: Int, isInteger: Bool)? {
        if let (s, n) = decimal(t, i) { return (s, n, false) }
        guard let value = cardinal(t[i].core), t[i].trail.isEmpty else { return nil }
        return (digits(value), 1, true)
    }

    private static func decimal(_ t: [Tok], _ i: Int) -> (String, Int)? {
        guard let whole = cardinal(t[i].core), t[i].trail.isEmpty,
              i + 2 < t.count, t[i + 1].core == "komma", t[i + 1].trail.isEmpty
        else { return nil }
        var fraction = ""
        var k = i + 2
        if singleDigits[t[k].core] != nil {
            while k < t.count, let digit = singleDigits[t[k].core] {
                fraction += String(digit)
                k += 1
                if !t[k - 1].trail.isEmpty { break }
            }
        } else if let value = cardinal(t[k].core) {
            fraction = String(value)
            k += 1
        } else {
            return nil
        }
        return (digits(whole) + "," + fraction, k - i)
    }

    // MARK: - Matchers (replacement text + tokens consumed, or nil)

    private static func hour(_ core: String, allowArticle: Bool) -> Int? {
        if allowArticle, core == "ein" { return 1 }
        guard let value = cardinal(core), (0 ... 24).contains(value) else { return nil }
        return value
    }

    /// Words after which "um acht" is clearly a time and nothing else.
    private static let timeFollowers: Set<String> = ["und", "oder", "bis", "am", "im"]

    private static func matchTime(_ t: [Tok], _ i: Int) -> (String, Int)? {
        let core = t[i].core

        // "halb drei" → 2:30
        if core == "halb", t[i].trail.isEmpty, i + 1 < t.count,
           let h = hour(t[i + 1].core, allowArticle: false), (1 ... 12).contains(h),
           !nounFollows(t, i + 1) {
            let shown = h == 1 ? 12 : h - 1
            return (t[i].lead + "\(shown):30" + t[i + 1].trail, 2)
        }

        // "viertel nach acht" → 8:15, "viertel vor acht" → 7:45
        if core == "viertel", t[i].trail.isEmpty, i + 2 < t.count, t[i + 1].trail.isEmpty,
           t[i + 1].core == "nach" || t[i + 1].core == "vor",
           let h = hour(t[i + 2].core, allowArticle: false), (1 ... 12).contains(h),
           !nounFollows(t, i + 2) {
            let text = t[i + 1].core == "nach" ? "\(h):15" : "\(h == 1 ? 12 : h - 1):45"
            return (t[i].lead + text + t[i + 2].trail, 3)
        }

        // "um acht [Uhr [dreißig]]"
        if core == "um", t[i].trail.isEmpty, i + 1 < t.count {
            let u = i + 2
            if let h = hour(t[i + 1].core, allowArticle: true), t[i + 1].trail.isEmpty,
               u < t.count, t[u].core == "uhr" {
                return (t[i].raw + " " + clock(h, t, u).text, 1 + 1 + clock(h, t, u).consumed)
            }
            // Without "Uhr" only when nothing else could follow: the end of the
            // text, punctuation, or a word that cannot be a counted noun.
            if let h = hour(t[i + 1].core, allowArticle: false), !nounFollows(t, i + 1) {
                let last = i + 1
                let closes = !t[last].trail.isEmpty || last + 1 == t.count
                    || timeFollowers.contains(t[last + 1].core)
                if closes {
                    return (t[i].raw + " " + "\(h) Uhr" + t[last].trail, 2)
                }
            }
            return nil
        }

        // "acht Uhr [dreißig]"
        if let h = hour(core, allowArticle: true), t[i].trail.isEmpty,
           i + 1 < t.count, t[i + 1].core == "uhr" {
            let result = clock(h, t, i + 1)
            return (t[i].lead + result.text, 1 + result.consumed)
        }
        return nil
    }

    /// The "Uhr [minutes]" tail at `u`: "8 Uhr" or "8:30 Uhr".
    private static func clock(_ h: Int, _ t: [Tok], _ u: Int) -> (text: String, consumed: Int) {
        if t[u].trail.isEmpty, u + 1 < t.count,
           let minutes = cardinal(t[u + 1].core), (0 ... 59).contains(minutes),
           !nounFollows(t, u + 1) {
            return ("\(h):" + String(format: "%02d", minutes) + " Uhr" + t[u + 1].trail, 2)
        }
        return ("\(h) Uhr" + t[u].trail, 1)
    }

    /// "dritter März [zweitausendvierundzwanzig]" → "3. März [2024]".
    private static func matchDate(_ t: [Tok], _ i: Int) -> (String, Int)? {
        guard let day = ordinal(t[i].core), (1 ... 31).contains(day), t[i].trail.isEmpty,
              i + 1 < t.count, let month = months[t[i + 1].core]
        else { return nil }
        var last = i + 1
        var text = "\(day). \(month)"
        if t[i + 1].trail.isEmpty, i + 2 < t.count,
           let year = cardinal(t[i + 2].core), (1_000 ... 2_999).contains(year) {
            text += " \(year)"
            last = i + 2
        }
        return (t[i].lead + text + t[last].trail, last - i + 1)
    }

    /// Where an ordinal without a month is still a day: "am zweiten", "vom
    /// dritten", "bis zum fünften". Not after a bare "zum" — "zum ersten, zum
    /// zweiten" is an auction, not a calendar.
    private static func matchContextOrdinal(_ t: [Tok], _ i: Int) -> (String, Int)? {
        guard i > 0, t[i - 1].trail.isEmpty else { return nil }
        let before = t[i - 1].core
        let dayContext = ["am", "vom", "ab", "bis"].contains(before)
            || (before == "zum" && i > 1 && t[i - 2].core == "bis")
        guard dayContext, let day = ordinal(t[i].core), (1 ... 31).contains(day),
              !nounFollows(t, i)
        else { return nil }
        if t[i].trail.isEmpty, i + 1 < t.count, t[i + 1].core == "mal" { return nil }
        return (t[i].lead + ordinalText(day, trail: t[i].trail), 1)
    }

    private static let wordCurrencies: Set<String> = ["dollar", "pfund", "franken"]

    /// "zweiundzwanzig Euro fünfzig" → "22,50 €"; "fünf Dollar" → "5 Dollar".
    private static func matchCurrency(_ t: [Tok], _ i: Int) -> (String, Int)? {
        guard let amount = quantity(t, i) else { return nil }
        let c = i + amount.consumed
        guard c < t.count else { return nil }
        let unit = t[c].core

        if unit == "euro" {
            var last = c
            var value = amount.text
            if amount.isInteger, t[c].trail.isEmpty, c + 1 < t.count {
                var j = c + 1
                let saidAnd = t[j].core == "und" && t[j].trail.isEmpty
                if saidAnd { j += 1 }
                if j < t.count, let cents = cardinal(t[j].core), (1 ... 99).contains(cents) {
                    let saidCent = j + 1 < t.count && t[j].trail.isEmpty && t[j + 1].core == "cent"
                    if saidCent {
                        value += "," + String(format: "%02d", cents)
                        last = j + 1
                    } else if !saidAnd, !nounFollows(t, j) {
                        value += "," + String(format: "%02d", cents)
                        last = j
                    }
                }
            }
            return (t[i].lead + value + "\u{00A0}€" + t[last].trail, last - i + 1)
        }
        if wordCurrencies.contains(unit) || (unit == "cent" && amount.isInteger) {
            return (t[i].lead + amount.text + " " + t[c].raw, amount.consumed + 1)
        }
        return nil
    }

    /// "zwanzig Prozent" → "20 %", "drei Komma fünf Prozent" → "3,5 %".
    private static func matchPercent(_ t: [Tok], _ i: Int) -> (String, Int)? {
        guard let amount = quantity(t, i) else { return nil }
        let p = i + amount.consumed
        guard p < t.count, t[p].core == "prozent" else { return nil }
        return (t[i].lead + amount.text + "\u{00A0}%" + t[p].trail, amount.consumed + 1)
    }

    private static func matchDecimal(_ t: [Tok], _ i: Int) -> (String, Int)? {
        guard let (text, n) = decimal(t, i) else { return nil }
        return (t[i].lead + text + t[i + n - 1].trail, n)
    }

    /// A number standing alone: from thirteen up, and not inside a run.
    private static func matchCardinal(_ t: [Tok], _ i: Int) -> (String, Int)? {
        guard let value = cardinal(t[i].core), value >= 13 else { return nil }
        if i > 0, t[i - 1].trail.isEmpty, cardinal(t[i - 1].core) != nil { return nil }
        if i + 1 < t.count, t[i].trail.isEmpty, cardinal(t[i + 1].core) != nil { return nil }
        // "tausend Dank" is thanks, not a quantity.
        if value == 1_000, i + 1 < t.count, t[i + 1].core == "dank" { return nil }
        return (t[i].lead + digits(value) + t[i].trail, 1)
    }
}
