import Foundation

/// A spoken shorthand and the text it expands to ("meine Adresse" → three lines
/// of postal address).
///
/// Deliberately **not** part of `PersonalDictionary`, even though the two look
/// alike in the UI. The dictionary is a *correction* table — what the ASR misheard
/// mapped to what was said — and both sides mean the same word, which is why it may
/// run through `FuzzyDictionary`. This is an *expansion*: a near-miss there does not
/// cost a word, it writes a paragraph where a similar-sounding word stood. So these
/// entries never see the fuzzy pass.
struct SmartReplacement: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    /// The spoken phrase, one or more words.
    var trigger: String
    /// Arbitrary text; may contain line breaks.
    var replacement: String
    var caseSensitive: Bool
    var enabled: Bool

    init(
        id: UUID = UUID(),
        trigger: String,
        replacement: String,
        caseSensitive: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.trigger = trigger
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.enabled = enabled
    }
}

/// Storage and the (pure) matching for `SmartReplacement`s.
///
/// Stored as an **array**, not a dictionary like `PersonalDictionary`: order is part
/// of the meaning, and an entry has to be switchable off without being deleted.
enum SmartReplace {
    static let defaultsKey = "smartReplacements"

    // MARK: - Storage

    static func load(store: UserDefaults = .standard) -> [SmartReplacement] {
        guard let data = store.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([SmartReplacement].self, from: data)) ?? []
    }

    static func save(_ items: [SmartReplacement], store: UserDefaults = .standard) {
        // A trigger of nothing but whitespace would match everywhere or nowhere
        // depending on the regex engine's mood; it never reaches storage.
        let clean = items.filter { isValidTrigger($0.trigger) }
        guard let data = try? JSONEncoder().encode(clean) else { return }
        store.set(data, forKey: defaultsKey)
    }

    static func isValidTrigger(_ trigger: String) -> Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Entries whose trigger is also a personal-dictionary key. Flagged in the UI
    /// because otherwise one table corrects what the other just inserted.
    static func collisions(_ items: [SmartReplacement], dictionary: [String: String]) -> Set<UUID> {
        let keys = Set(dictionary.keys.map { $0.lowercased() })
        return Set(items.filter { keys.contains($0.trigger.lowercased()) }.map(\.id))
    }

    // MARK: - Matching (pure)

    /// Expands every active trigger, in **one pass over the original text**.
    ///
    /// One pass is the point, not an optimization: replacing sequentially would let
    /// entry B fire inside the text entry A just inserted, and a user could build
    /// himself a loop out of two innocent-looking rows. The result of an expansion
    /// is never examined again.
    static func apply(
        _ items: [SmartReplacement],
        to text: String,
        now: Date = Date(),
        locale: Locale = .current
    ) -> String {
        // Longest trigger first, so "neue Adresse" wins over "Adresse" when both
        // start at the same place.
        let active = items
            .filter { $0.enabled && isValidTrigger($0.trigger) }
            .sorted { $0.trigger.count > $1.trigger.count }
        guard !active.isEmpty, !text.isEmpty else { return text }

        let branches = active.map { item -> String in
            let escaped = NSRegularExpression.escapedPattern(for: item.trigger)
            // Case sensitivity is per entry, so the flag is scoped to its branch.
            return item.caseSensitive ? "(\(escaped))" : "((?i:\(escaped)))"
        }
        // Unicode-safe word boundaries — `\b` misbehaves around umlauts, and
        // "Grüße" is exactly the kind of trigger someone writes.
        let pattern = "(?u)(?<![\\p{L}\\p{N}])(?:" + branches.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        let ns = text as NSString
        var out = ""
        var consumed = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.range.location >= consumed else { return }
            guard let item = active.indices.lazy
                .first(where: { match.range(at: $0 + 1).location != NSNotFound })
                .map({ active[$0] })
            else { return }

            out += ns.substring(with: NSRange(location: consumed, length: match.range.location - consumed))
            out += expanding(item.replacement, now: now, locale: locale)
            consumed = match.range.location + match.range.length
        }
        guard consumed > 0 else { return text }
        return out + ns.substring(from: consumed)
    }

    /// The closed placeholder list. Deliberately three entries and no format
    /// language — a template syntax in a dictation path is a support burden with
    /// no owner.
    static func expanding(_ replacement: String, now: Date = Date(), locale: Locale = .current) -> String {
        guard replacement.contains("{") else { return replacement }
        var result = replacement
        for (token, style) in placeholders {
            guard result.localizedCaseInsensitiveContains(token) else { continue }
            let value = now.formatted(style.locale(locale))
            result = result.replacingOccurrences(of: token, with: value, options: [.caseInsensitive])
        }
        return result
    }

    private static let placeholders: [(String, Date.FormatStyle)] = [
        ("{datum}", .dateTime.day().month(.wide).year()),
        ("{uhrzeit}", .dateTime.hour().minute()),
        ("{wochentag}", .dateTime.weekday(.wide)),
    ]
}
