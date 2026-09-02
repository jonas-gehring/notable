import Foundation
import NaturalLanguage

/// The languages the user actually dictates in.
///
/// Deliberately a list of two, not a picker of a hundred: `TextPolisher` only
/// distinguishes German from English (filler classes and ITN), so a third entry
/// would be a promise nothing downstream keeps.
///
/// The point is not preference, it is **constraint**. `NLLanguageRecognizer`
/// left unconstrained will happily call a short "Ok, dann machen wir das"
/// Danish, and the English filler list then eats "er" out of a German sentence.
/// Told that only German and English are possible, it cannot.
enum SpokenLanguages {
    static let storageKey = "spokenLanguages"

    static let supported: [(code: String, label: String)] = [
        ("de", "Deutsch"),
        ("en", "Englisch"),
    ]

    static let `default` = ["de", "en"]
    /// Never nothing: an empty profile would leave the recognizer unconstrained
    /// again, which is the state this type exists to prevent.
    static let fallback = ["de"]

    static func load(_ store: UserDefaults = .standard) -> [String] {
        let stored = (store.array(forKey: storageKey) as? [String]) ?? Self.default
        let valid = stored.filter { code in supported.contains { $0.code == code } }
        return valid.isEmpty ? fallback : valid
    }

    static func save(_ codes: [String], store: UserDefaults = .standard) {
        let valid = codes.filter { code in supported.contains { $0.code == code } }
        store.set(valid.isEmpty ? fallback : valid, forKey: storageKey)
    }

    /// `NLLanguage` constraints for the recognizer.
    static func constraints(_ codes: [String]) -> [NLLanguage] {
        let valid = codes.isEmpty ? fallback : codes
        return valid.map { NLLanguage($0) }
    }
}
