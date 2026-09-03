import Foundation

/// Which language the interface is drawn in.
///
/// **The German text in the source is the key**, not a translation of something
/// else: Notable was written in German, and rewriting two hundred literals to
/// invent an English "original" would have been a large, risky diff for no gain.
/// `en.lproj/Localizable.strings` maps those keys to English; `de.lproj` exists so
/// German is offered as a *choice* rather than only as the fallback, and stays
/// almost empty because a missing key resolves to itself — which is the German.
///
/// `CFBundleDevelopmentRegion` is `en`, so a system in a language Notable does not
/// speak lands on English rather than on German. That is the only reason the
/// development region and the key language differ.
enum AppLanguage: String, CaseIterable, Identifiable {
    /// Follow the system's preferred languages (the default).
    case system
    case german
    case english

    static let storageKey = "appLanguage"

    /// The key macOS itself reads to decide a bundle's language. Writing it into
    /// the app's own defaults domain overrides the system order for this app only.
    static let appleLanguagesKey = "AppleLanguages"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Systemsprache"
        case .german: "Deutsch"
        case .english: "English"
        }
    }

    /// What to write into `AppleLanguages`, or `nil` to remove the override and
    /// let the system order stand again.
    var localeIdentifiers: [String]? {
        switch self {
        case .system: nil
        case .german: ["de"]
        case .english: ["en"]
        }
    }

    /// Reads the stored choice. Anything unrecognised — a hand-edited defaults
    /// entry, a value from a future version — means "follow the system", because
    /// an unreadable preference must not leave the app in no language at all.
    static func current(_ defaults: UserDefaults = .standard) -> AppLanguage {
        defaults.string(forKey: storageKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// Stores the choice and applies it to `AppleLanguages`.
    ///
    /// It does **not** take effect in the running process: the bundle resolves its
    /// string tables once, at first use, so every window already on screen would
    /// keep the old language while new ones came up in the new one. The caller
    /// relaunches — a restart that is announced is better than an interface in two
    /// languages at the same time.
    static func apply(_ language: AppLanguage, to defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: storageKey)
        if let identifiers = language.localeIdentifiers {
            defaults.set(identifiers, forKey: appleLanguagesKey)
        } else {
            defaults.removeObject(forKey: appleLanguagesKey)
        }
    }
}
