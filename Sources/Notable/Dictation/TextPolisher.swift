import Foundation
import NaturalLanguage

/// Post-ASR cleanup toward polished, ready-to-paste text: filler removal, ITN,
/// personal dictionary (exact + fuzzy), whitespace/casing tidy-up. Pure and unit-tested.
///
/// ITN note: FluidAudio's `TextNormalizer` only works when the native NeMo
/// `libnemo_text_processing` (a Rust library) is dlopen-able in the process. SPM does
/// **not** bundle it and building/linking it is out of scope for this personal tool, so
/// `isNativeAvailable` is always false and the FluidAudio path was pure pass-through.
/// `EnglishITN` below is a conservative pure-Swift replacement — English only, gated by
/// `applyITN`, and designed to never mangle correct prose (it declines ambiguous cases).
struct TextPolisher: Sendable {
    struct Options: Sendable {
        var removeFillers = true
        var applyITN = true
        var applyFuzzyDictionary = true
        var dictionary: [String: String] = [:]
        /// Verbatim mode (code/terminal): skip filler removal, ITN and casing —
        /// keep exactly what was said. The personal dictionary still applies so
        /// names/jargon stay correct.
        var verbatim = false
        /// Capitalize the first letter of the result (off for casual chat).
        var capitalizeStart = true
        /// Append a sentence-final period when the text ends without punctuation
        /// (on for mail, off elsewhere).
        var enforceFinalPunctuation = false
        /// Group sentences into paragraphs instead of one endless line
        /// (off for chat, where one line is the point).
        var paragraphs = true
        /// Honour spoken structure commands ("neue Zeile", "Stichpunkt", …).
        var structureCommands = true
        /// Spoken shorthands that expand to arbitrary (possibly multi-line) text.
        /// Separate from `dictionary` on purpose — see `SmartReplacement`.
        var replacements: [SmartReplacement] = []
        /// Which languages the language detector is allowed to choose between.
        /// Passed in rather than read from `UserDefaults` so this stays pure and
        /// the tests can set a profile without touching global state.
        var spokenLanguages: [String] = SpokenLanguages.default

        static func fromDefaults() -> Options {
            let defaults = UserDefaults.standard
            var options = Options()
            if defaults.object(forKey: "polishRemoveFillers") != nil {
                options.removeFillers = defaults.bool(forKey: "polishRemoveFillers")
            }
            if defaults.object(forKey: "polishApplyITN") != nil {
                options.applyITN = defaults.bool(forKey: "polishApplyITN")
            }
            if defaults.object(forKey: "polishFuzzyDictionary") != nil {
                options.applyFuzzyDictionary = defaults.bool(forKey: "polishFuzzyDictionary")
            }
            if defaults.object(forKey: "polishParagraphs") != nil {
                options.paragraphs = defaults.bool(forKey: "polishParagraphs")
            }
            if defaults.object(forKey: "polishStructureCommands") != nil {
                options.structureCommands = defaults.bool(forKey: "polishStructureCommands")
            }
            options.dictionary = PersonalDictionary.load()
            options.replacements = SmartReplace.load()
            options.spokenLanguages = SpokenLanguages.load(defaults)
            return options
        }
    }

    /// Safe in every language (longest first, so "ähm" wins over "äh").
    static let universalFillers = ["ähem", "ähm", "ähh", "äh", "mhm", "hmm"]
    /// "um" and "er" are ordinary German words — these apply to English text only.
    static let englishFillers = ["uhm", "um", "uh", "erm", "er"]

    static func polish(_ text: String, options: Options = Options()) -> String {
        var result = text
        let english = isEnglish(result, languages: options.spokenLanguages)

        // Verbatim skips the "beautifying" passes; filler removal and ITN are
        // exactly the transformations a code/terminal dictation must not get.
        if !options.verbatim {
            if options.removeFillers {
                result = removing(fillers: universalFillers, from: result)
                if english {
                    result = removing(fillers: englishFillers, from: result)
                }
            }
            // ITN rules (spoken-form numbers, currency, dates) are English-specific.
            if options.applyITN, english {
                result = EnglishITN.normalize(result)
            }
        }

        // Expansions run *before* the dictionary, and in verbatim mode too: a
        // shorthand is a deliberate instruction, not a beautification, and in a
        // terminal an abbreviation for a long path is precisely the win. They stay
        // ahead of the dictionary so a correction rule can still fix a name inside
        // an expanded signature — and behind filler removal, so an "ähm" in the
        // middle of a trigger does not tear the phrase apart.
        result = SmartReplace.apply(options.replacements, to: result)

        // Exact dictionary first (handles multi-word keys, longest key wins), then a
        // conservative fuzzy pass for near-miss single-word spellings of the same keys.
        // Runs in every mode — names/jargon should be corrected even verbatim.
        for (wrong, right) in options.dictionary.sorted(by: { $0.key.count > $1.key.count }) {
            result = replacingWord(wrong, with: right, in: result)
        }
        if options.applyFuzzyDictionary {
            result = FuzzyDictionary.apply(options.dictionary, to: result)
        }

        if options.verbatim {
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var tidied = tidy(result, capitalizeStart: options.capitalizeStart)
        if options.enforceFinalPunctuation {
            tidied = ensuringFinalPunctuation(tidied)
        }
        // Last, deliberately: `tidy` collapses every whitespace run, so the
        // structure has to be put back *after* it. Verbatim never gets here —
        // it returned above.
        guard options.paragraphs || options.structureCommands else { return tidied }
        return ParagraphFormatter.format(tidied, options: ParagraphFormatter.Options(
            paragraphs: options.paragraphs,
            structureCommands: options.structureCommands
        ))
    }

    /// Guided, not guessing.
    ///
    /// Unconstrained, `NLLanguageRecognizer` picks from every language it knows,
    /// and a short German sentence can come back Dutch or Danish — at which
    /// point it is neither German (no English fillers, correct) nor English
    /// (fillers stripped), it is simply wrong. Constrained to the profile, the
    /// answer can only be one of the languages the user actually speaks.
    ///
    /// A profile without English therefore never reports English, which is the
    /// intended consequence, not a side effect: English fillers and ITN are then
    /// switched off for good.
    static func isEnglish(_ text: String, languages: [String] = SpokenLanguages.default) -> Bool {
        let constraints = SpokenLanguages.constraints(languages)
        guard constraints.contains(.english) else { return false }
        // Only English is possible — asking the recognizer would be theatre.
        guard constraints.count > 1 else { return true }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = constraints
        recognizer.processString(text)
        return recognizer.dominantLanguage == .english
    }

    private static func removing(fillers: [String], from text: String) -> String {
        var result = text
        for filler in fillers {
            let escaped = NSRegularExpression.escapedPattern(for: filler)
            let pattern = "(?iu)(^|\\s)\(escaped)[,.]?(?=\\s|$)"
            result = result.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }
        return result
    }

    private static func replacingWord(_ word: String, with replacement: String, in text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        // Unicode-safe word boundaries (\b misbehaves around umlauts).
        let pattern = "(?iu)(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        return text.replacingOccurrences(
            of: pattern,
            with: NSRegularExpression.escapedTemplate(for: replacement),
            options: .regularExpression
        )
    }

    /// Collapses whitespace runs and tightens punctuation.
    ///
    /// **Horizontal** whitespace only: line breaks survive. They can only come from a
    /// smart-replace expansion (the ASR never emits one), and a multi-line building
    /// block that arrives as a single line is not a building block any more. A run of
    /// blank lines is still capped at one, and spaces sitting against a break go away.
    private static func tidy(_ text: String, capitalizeStart: Bool = true) -> String {
        var result = text.replacingOccurrences(of: "[^\\S\\n]+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        result = result.replacingOccurrences(of: " ([.,!?;:])", with: "$1", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard capitalizeStart, let first = result.first, first.isLowercase else { return result }
        return first.uppercased() + result.dropFirst()
    }

    /// Appends a period when the text ends without sentence-final punctuation.
    private static func ensuringFinalPunctuation(_ text: String) -> String {
        guard let last = text.last, !".!?:;…".contains(last) else { return text }
        return text + "."
    }
}

// MARK: - Per-app polishing profiles (offline, rule-based — Spec 03)

/// Maps an `AppCategory` to a `TextPolisher.Options`, starting from the user's
/// global toggles (`fromDefaults`) and overlaying only what the category changes.
/// Fully offline; dictation text never leaves the device.
enum PolishProfile {
    static func options(for category: AppCategory) -> TextPolisher.Options {
        var options = TextPolisher.Options.fromDefaults()
        switch category {
        case .code:
            // Exactly what was said: no fillers stripped, no ITN, no re-casing.
            options.verbatim = true
        case .mail:
            options.enforceFinalPunctuation = true
            options.capitalizeStart = true
        case .chat:
            // Casual: allow a lowercase start, no forced final period. One chat
            // line stays one line — but a spoken "neue Zeile" is still honoured.
            options.capitalizeStart = false
            options.paragraphs = false
        case .prose, .unknown:
            break // identical to today's default polishing
        }
        return options
    }
}

// MARK: - Personal dictionary

/// User-maintained replacements (misheard → correct), e.g. names and jargon.
///
/// The stored map (`personalDictionary`) is the exact-match source of truth edited in
/// Settings. `TextPolisher` applies it exactly and then fuzzily (`FuzzyDictionary`).
///
/// Auto-learn is *record-only* scaffolding (`recordCorrection`/`learnedSuggestions`): it
/// tallies observed corrections but never edits the active dictionary automatically — a
/// wrong auto-correction is worse than none, so promotion stays a manual, deliberate act.
enum PersonalDictionary {
    static let defaultsKey = "personalDictionary"
    static let learnedKey = "personalDictionaryLearned"
    static let dismissedKey = "personalDictionaryDismissed"

    static func load() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
    }

    static func save(_ dictionary: [String: String]) {
        UserDefaults.standard.set(dictionary, forKey: defaultsKey)
    }

    // MARK: Auto-learn scaffolding (dormant — never auto-applied)

    /// Tally an observed correction (heard form → user-corrected form). Stored separately
    /// from the active dictionary; surfaced only as *suggestions* the user may promote.
    static func recordCorrection(heard: String, corrected: String, store: UserDefaults = .standard) {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !corrected.isEmpty,
            heard.caseInsensitiveCompare(corrected) != .orderedSame
        else { return }
        var learned = (store.dictionary(forKey: learnedKey) as? [String: [String: Int]]) ?? [:]
        var counts = learned[heard] ?? [:]
        counts[corrected, default: 0] += 1
        learned[heard] = counts
        store.set(learned, forKey: learnedKey)
    }

    /// Heard forms the user explicitly rejected — never suggested again.
    static func dismissed(store: UserDefaults = .standard) -> Set<String> {
        Set((store.array(forKey: dismissedKey) as? [String]) ?? [])
    }

    /// The most-frequent corrected form per heard form seen at least `minCount` times,
    /// excluding forms already in the active dictionary or explicitly dismissed. These
    /// are *suggestions* only; nothing is applied until the user promotes them.
    static func learnedSuggestions(minCount: Int = 2, store: UserDefaults = .standard) -> [String: String] {
        let learned = (store.dictionary(forKey: learnedKey) as? [String: [String: Int]]) ?? [:]
        let active = (store.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        let rejected = dismissed(store: store)
        var result: [String: String] = [:]
        for (heard, counts) in learned {
            if rejected.contains(heard) { continue }
            if active.keys.contains(where: { $0.caseInsensitiveCompare(heard) == .orderedSame }) { continue }
            if let best = counts.max(by: { $0.value < $1.value }), best.value >= minCount {
                result[heard] = best.key
            }
        }
        return result
    }

    /// Promote a learned suggestion into the active dictionary and forget the candidate.
    static func promote(heard: String, corrected: String, store: UserDefaults = .standard) {
        var active = (store.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        active[heard] = corrected
        store.set(active, forKey: defaultsKey)
        forgetLearned(heard, store: store)
    }

    /// Reject a suggestion: drop the candidate and tombstone it so it never returns.
    static func dismiss(heard: String, store: UserDefaults = .standard) {
        var rejected = dismissed(store: store)
        rejected.insert(heard)
        store.set(Array(rejected), forKey: dismissedKey)
        forgetLearned(heard, store: store)
    }

    private static func forgetLearned(_ heard: String, store: UserDefaults) {
        var learned = (store.dictionary(forKey: learnedKey) as? [String: [String: Int]]) ?? [:]
        learned[heard] = nil
        store.set(learned, forKey: learnedKey)
    }
}

// MARK: - Fuzzy dictionary

/// Conservative fuzzy correction for near-miss ASR spellings of single-word dictionary
/// keys (names/jargon). Word-boundary-safe, case-insensitive, and deliberately timid: it
/// only fires on longer keys with a clearly-best, high-similarity match.
enum FuzzyDictionary {
    /// Normalized-similarity threshold (1 - editDistance/maxLen).
    static let threshold = 0.85
    /// Keys shorter than this are too fuzzy to match safely (e.g. "Jon" vs "Jan").
    static let minKeyLength = 4
    /// Absolute edit-distance cap regardless of length — no wild rewrites.
    static let maxDistance = 2

    static func apply(_ dictionary: [String: String], to text: String) -> String {
        // Only single-word keys of a safe length participate.
        let entries = dictionary.compactMap { (key, value) -> (lower: String, value: String)? in
            guard !key.contains(" "), key.count >= minKeyLength else { return nil }
            return (key.lowercased(), value)
        }
        guard !entries.isEmpty else { return text }

        return mapWords(in: text) { word in
            let lower = word.lowercased()
            var best: (score: Double, value: String)?
            var ambiguous = false
            for entry in entries {
                if lower == entry.lower { return nil }  // exact — already handled upstream
                let distance = levenshtein(lower, entry.lower)
                guard distance > 0, distance <= maxDistance else { continue }
                let score = 1.0 - Double(distance) / Double(max(lower.count, entry.lower.count))
                guard score >= threshold else { continue }
                if let current = best {
                    if score > current.score {
                        best = (score, entry.value)
                        ambiguous = false
                    } else if score == current.score, entry.value != current.value {
                        ambiguous = true
                    }
                } else {
                    best = (score, entry.value)
                }
            }
            guard let match = best, !ambiguous else { return nil }
            return match.value
        }
    }

    /// Apply `transform` to every word token, preserving all surrounding characters.
    /// Returning nil keeps the original word.
    static func mapWords(in text: String, transform: (String) -> String?) -> String {
        let pattern = "[\\p{L}\\p{N}']+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let word = ns.substring(with: range)
            result += transform(word) ?? word
            cursor = range.location + range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Classic iterative Levenshtein (two-row) over Characters.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

// MARK: - Pure-Swift English ITN

/// Conservative inverse text normalization for English dictation: spoken numbers,
/// ordinals, currency, percentages, "point" decimals, simple times, and month+day dates.
///
/// Design rule: **never mangle correct text.** Every matcher declines ambiguous input
/// (e.g. non-canonical number runs like "two thirty" outside a time, bare "one".."nine",
/// "a second") rather than risk a wrong rewrite. Callers gate this to English-detected text.
enum EnglishITN {

    static func normalize(_ text: String) -> String {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            if let (s, n) = matchTime(tokens, i) { out.append(s); i += n; continue }
            if let (s, n) = matchDate(tokens, i) { out.append(s); i += n; continue }
            if let (s, n) = matchCurrency(tokens, i) { out.append(s); i += n; continue }
            if let (s, n) = matchPercent(tokens, i) { out.append(s); i += n; continue }
            if let (s, n) = matchPointDecimal(tokens, i) { out.append(s); i += n; continue }
            if let (s, n) = matchOrdinal(tokens, i) { out.append(s); i += n; continue }
            if let (s, n) = matchCardinal(tokens, i) { out.append(s); i += n; continue }
            out.append(tokens[i].raw)
            i += 1
        }
        return out.joined(separator: " ")
    }

    // MARK: Tokenization

    struct Tok {
        let raw: String    // original token, verbatim
        let lead: String   // leading punctuation/quotes
        let core: String   // lowercased word (interior apostrophes/periods kept)
        let trail: String  // trailing punctuation
    }

    static func tokenize(_ text: String) -> [Tok] {
        let raws = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return raws.map { raw in
            let chars = Array(raw)
            let firstAlnum = chars.firstIndex { $0.isLetter || $0.isNumber }
            let lastAlnum = chars.lastIndex { $0.isLetter || $0.isNumber }
            guard let first = firstAlnum, let last = lastAlnum else {
                return Tok(raw: raw, lead: raw, core: "", trail: "")
            }
            let lead = String(chars[0..<first])
            let core = String(chars[first...last]).lowercased()
            let trail = String(chars[(last + 1)...])
            return Tok(raw: raw, lead: lead, core: core, trail: trail)
        }
    }

    // MARK: Number word tables

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = [
        "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]
    /// Single-digit words used after "point" (0-9 only).
    private static let singleDigit: [String: Int] = units.merging(["oh": 0, "o": 0]) { a, _ in a }

    /// Every word that can appear inside a cardinal run (excludes "and", handled separately).
    private static let numberWords: Set<String> = {
        var set = Set(units.keys)
        set.formUnion(teens.keys)
        set.formUnion(tens.keys)
        set.formUnion(scales.keys)
        set.insert("hundred")
        return set
    }()

    // Ordinal → cardinal value.
    private static let ordinalUnits: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
    ]
    private static let ordinalWords: [String: Int] = {
        var map = ordinalUnits
        map["tenth"] = 10; map["eleventh"] = 11; map["twelfth"] = 12; map["thirteenth"] = 13
        map["fourteenth"] = 14; map["fifteenth"] = 15; map["sixteenth"] = 16; map["seventeenth"] = 17
        map["eighteenth"] = 18; map["nineteenth"] = 19; map["twentieth"] = 20; map["thirtieth"] = 30
        map["fortieth"] = 40; map["fiftieth"] = 50; map["sixtieth"] = 60; map["seventieth"] = 70
        map["eightieth"] = 80; map["ninetieth"] = 90; map["hundredth"] = 100; map["thousandth"] = 1_000
        return map
    }()

    /// Months eligible to trigger date normalization. "march" and "may" are deliberately
    /// excluded — they collide with the verb/modal ("you may first…", "march third into…"),
    /// and a wrong date is worse than an unformatted one.
    private static let months: [String: String] = [
        "january": "January", "february": "February", "april": "April",
        "june": "June", "july": "July", "august": "August",
        "september": "September", "october": "October", "november": "November", "december": "December",
    ]

    // MARK: Cardinal parsing

    private enum Kind { case unit, teen, ten, hundred, scale }

    private static func classify(_ core: String) -> (Kind, Int)? {
        if let v = units[core] { return (.unit, v) }
        if let v = teens[core] { return (.teen, v) }
        if let v = tens[core] { return (.ten, v) }
        if core == "hundred" { return (.hundred, 100) }
        if let v = scales[core] { return (.scale, v) }
        return nil
    }

    /// Parse a canonical spoken cardinal (e.g. ["two","hundred","fifty"] → 250). Returns
    /// nil for non-canonical sequences ("two thirty", "twenty ten") so they stay as words.
    private static func parseCardinal(_ cores: [String]) -> Int? {
        enum Sub { case empty, unit, teen, ten }
        var result = 0, current = 0
        var sub: Sub = .empty
        var saw = false
        for core in cores {
            if core == "and" { continue }
            guard let (kind, val) = classify(core) else { return nil }
            saw = true
            switch kind {
            case .unit:
                if sub == .empty || sub == .ten { current += val; sub = .unit } else { return nil }
            case .teen:
                if sub == .empty { current += val; sub = .teen } else { return nil }
            case .ten:
                if sub == .empty { current += val; sub = .ten } else { return nil }
            case .hundred:
                if sub == .empty { current = 100 }
                else if sub == .unit || sub == .teen { current *= 100 }
                else { return nil }
                sub = .empty
            case .scale:
                result += (current == 0 ? 1 : current) * val
                current = 0
                sub = .empty
            }
        }
        return saw ? result + current : nil
    }

    /// Greedily gather a cardinal run starting at `start`; returns its value and the
    /// exclusive end index, shrinking from the right until a canonical parse succeeds.
    private static func gatherCardinal(_ tokens: [Tok], _ start: Int) -> (value: Int, end: Int)? {
        var end = start
        while end < tokens.count {
            let core = tokens[end].core
            guard numberWords.contains(core) || core == "and" else { break }
            end += 1
            if !tokens[end - 1].trail.isEmpty { break }  // punctuation ends the run
        }
        guard end > start else { return nil }
        var e = end
        while e > start {
            let slice = tokens[start..<e].map { $0.core }
            if slice.last == "and" { e -= 1; continue }
            if let value = parseCardinal(slice) { return (value, e) }
            e -= 1
        }
        return nil
    }

    /// Numeric value at `i` as either a "point" decimal or a plain cardinal run.
    private static func numericString(_ tokens: [Tok], _ i: Int) -> (string: String, consumed: Int)? {
        if let (s, n) = pointDecimal(tokens, i) { return (s, n) }
        if let (v, e) = gatherCardinal(tokens, i) { return (String(v), e - i) }
        return nil
    }

    private static func ordinalValue(_ tokens: [Tok], _ i: Int) -> (value: Int, consumed: Int)? {
        // matchDate calls this with i+1, which can be one past the end when a
        // month word is the last token ("…in September") — guard or crash.
        guard i < tokens.count else { return nil }
        // Compound: cardinal prefix + unit ordinal ("twenty first" → 21).
        if let (base, e) = gatherCardinal(tokens, i), base > 0,
            e < tokens.count, let ov = ordinalUnits[tokens[e].core] {
            return (base + ov, e - i + 1)
        }
        // Standalone ordinal word ("third" → 3, "twentieth" → 20).
        if let ov = ordinalWords[tokens[i].core] { return (ov, 1) }
        return nil
    }

    private static func ordinalSuffix(_ n: Int) -> String {
        let mod100 = n % 100
        if (11...13).contains(mod100) { return "th" }
        switch n % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    private static func meridiem(_ core: String) -> String? {
        switch core.replacingOccurrences(of: ".", with: "") {
        case "am": return "a.m."
        case "pm": return "p.m."
        default: return nil
        }
    }

    // MARK: Matchers (each returns replacement text + tokens consumed, or nil)

    private static func matchTime(_ tokens: [Tok], _ i: Int) -> (String, Int)? {
        guard let (hour, e) = gatherCardinal(tokens, i), (1...12).contains(hour) else { return nil }
        // "<hour> <am|pm>"
        if e < tokens.count, let mer = meridiem(tokens[e].core) {
            return (tokens[i].lead + String(hour) + " " + mer + tokens[e].trail, e - i + 1)
        }
        // "<hour> <minute> <am|pm>"
        if let (minute, me) = gatherCardinal(tokens, e), (0...59).contains(minute),
            me < tokens.count, let mer = meridiem(tokens[me].core) {
            let s = tokens[i].lead + String(hour) + ":" + String(format: "%02d", minute) + " " + mer + tokens[me].trail
            return (s, me - i + 1)
        }
        return nil
    }

    private static func matchDate(_ tokens: [Tok], _ i: Int) -> (String, Int)? {
        guard let month = months[tokens[i].core] else { return nil }
        guard let (day, n) = ordinalValue(tokens, i + 1), (1...31).contains(day) else { return nil }
        let last = i + n
        return (tokens[i].lead + month + " " + String(day) + tokens[last].trail, 1 + n)
    }

    private static func matchCurrency(_ tokens: [Tok], _ i: Int) -> (String, Int)? {
        guard let (dollars, e) = gatherCardinal(tokens, i) else {
            return matchCentsOnly(tokens, i)
        }
        guard e < tokens.count, tokens[e].core == "dollar" || tokens[e].core == "dollars" else { return nil }
        var last = e
        var centsPart = ""
        // optional "[and] <n> cents"
        var k = e + 1
        if k < tokens.count, tokens[k].core == "and" { k += 1 }
        if let (cents, ce) = gatherCardinal(tokens, k), (0...99).contains(cents),
            ce < tokens.count, tokens[ce].core == "cent" || tokens[ce].core == "cents" {
            centsPart = "." + String(format: "%02d", cents)
            last = ce
        }
        let value = "$" + String(dollars) + centsPart
        return (tokens[i].lead + value + tokens[last].trail, last - i + 1)
    }

    private static func matchCentsOnly(_ tokens: [Tok], _ i: Int) -> (String, Int)? {
        guard let (cents, e) = gatherCardinal(tokens, i), (0...99).contains(cents),
            e < tokens.count, tokens[e].core == "cent" || tokens[e].core == "cents" else { return nil }
        return (tokens[i].lead + "$0." + String(format: "%02d", cents) + tokens[e].trail, e - i + 1)
    }

    private static func matchPercent(_ tokens: [Tok], _ i: Int) -> (String, Int)? {
        guard let (valueStr, n) = numericString(tokens, i) else { return nil }
        let after = i + n
        guard after < tokens.count, tokens[after].core == "percent" || tokens[after].core == "percentage"
        else { return nil }
        return (tokens[i].lead + valueStr + "%" + tokens[after].trail, n + 1)
    }

    private static func pointDecimal(_ tokens: [Tok], _ i: Int) -> (String, Int)? {
        guard let (intPart, e) = gatherCardinal(tokens, i), e < tokens.count, tokens[e].core == "point"
        else { return nil }
        var digits = ""
        var last = e + 1
        var k = e + 1
        while k < tokens.count, let d = singleDigit[tokens[k].core] {
            digits += String(d)
            last = k
            if !tokens[k].trail.isEmpty { k += 1; break }
            k += 1
        }
        guard !digits.isEmpty else { return nil }
        return (String(intPart) + "." + digits, last - i + 1)
    }

    private static func matchPointDecimal(_ tokens: [Tok], _ i: Int) -> (String, Int)? {
        guard let (s, n) = pointDecimal(tokens, i) else { return nil }
        let last = i + n - 1
        return (tokens[i].lead + s + tokens[last].trail, n)
    }

    private static func matchOrdinal(_ tokens: [Tok], _ i: Int) -> (String, Int)? {
        // Skip "a second"/"an eighth" — those are usually fractions/nouns, not ordinals.
        if i > 0, tokens[i - 1].core == "a" || tokens[i - 1].core == "an" { return nil }
        guard let (value, n) = ordinalValue(tokens, i) else { return nil }
        let last = i + n - 1
        return (tokens[i].lead + String(value) + ordinalSuffix(value) + tokens[last].trail, n)
    }

    private static func matchCardinal(_ tokens: [Tok], _ i: Int) -> (String, Int)? {
        guard classify(tokens[i].core) != nil else { return nil }
        // Don't convert when an adjacent token (either side) is also a number/ordinal/"point"
        // word — that pattern is usually a year/phone/sequence read we'd only mangle
        // ("nineteen eighty four", "one two three").
        if i > 0 {
            let prev = tokens[i - 1].core
            if numberWords.contains(prev) || prev == "point" || ordinalWords[prev] != nil { return nil }
        }
        guard let (value, end) = gatherCardinal(tokens, i) else { return nil }
        if end < tokens.count {
            let next = tokens[end].core
            if numberWords.contains(next) || next == "point" || ordinalWords[next] != nil { return nil }
        }
        // Conservative gate: bare "one".."nine" stay as words; convert compounds and ≥10.
        guard (end - i) >= 2 || value >= 10 else { return nil }
        return (tokens[i].lead + String(value) + tokens[end - 1].trail, end - i)
    }
}
