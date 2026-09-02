import Foundation

/// A remembered per-source consent choice. `nil` (absence from the store) means
/// "ask every time" — the default state, so only the two persistent outcomes are
/// modelled here.
enum MeetingConsentDecision: String, Sendable, CaseIterable {
    case always
    case never
}

/// Stable identity keys for remembering per-source consent.
///
/// A native meeting app keys on its bundle id. A browser call keys on the
/// *service*, not the browser (`web:zoom`, `web:google-meet`, `web:teams`), so
/// "immer für diese App" holds whether the service is native or a tab, and no
/// matter which browser hosts it. This logic is pure so it can be unit-tested
/// without the live-window signals in `MeetingDetector`.
enum MeetingIdentity {
    /// A browser holds the microphone but its window title gives no clue which
    /// service it is (no Screen Recording permission, or a service we don't know).
    /// The call is still worth offering — but the choice must never be
    /// remembered as "always", or every voice search in that browser would
    /// silently start a recording.
    static let unknownWebKey = "web:unknown"

    /// False for identities too coarse to remember a standing decision for.
    static func isRememberable(_ identityKey: String) -> Bool {
        identityKey != unknownWebKey && identityKey != "unknown"
    }

    /// Maps a browser window title to `(stable key, display name)`, or `nil` when
    /// the title carries no call evidence. Matching mirrors
    /// `MeetingDetector.detectBrowserMeeting` and is the single source of truth
    /// for both the display string and the storage key.
    static func webService(forWindowTitle title: String) -> (key: String, display: String)? {
        let lowered = title.lowercased()
        if lowered.contains("meet.google.com") || lowered.hasPrefix("meet – ") || lowered.hasPrefix("meet - ") {
            return ("web:google-meet", "Google Meet")
        }
        if lowered.contains("zoom meeting") {
            return ("web:zoom", "Zoom")
        }
        if lowered.contains("microsoft teams") {
            return ("web:teams", "Microsoft Teams")
        }
        return nil
    }
}

/// Persistent map `identityKey → .always | .never` over `UserDefaults`, keyed at
/// `"meetingConsentByApp"`. Pure and injectable (`defaults:`) so it is testable
/// against a throwaway suite. Absence of a key is the "ask" state.
enum MeetingConsentStore {
    static let defaultsKey = "meetingConsentByApp"

    /// The remembered decision for a source, or `nil` to ask.
    static func decision(for identityKey: String, defaults: UserDefaults = .standard) -> MeetingConsentDecision? {
        guard let raw = rawMap(defaults)[identityKey] else { return nil }
        return MeetingConsentDecision(rawValue: raw)
    }

    /// Persists `.always`/`.never` for a source, overwriting any prior choice.
    static func remember(_ decision: MeetingConsentDecision, for identityKey: String, defaults: UserDefaults = .standard) {
        var map = rawMap(defaults)
        map[identityKey] = decision.rawValue
        defaults.set(map, forKey: defaultsKey)
    }

    /// Reverts a source back to "ask" by removing its remembered choice.
    static func forget(_ identityKey: String, defaults: UserDefaults = .standard) {
        var map = rawMap(defaults)
        map.removeValue(forKey: identityKey)
        defaults.set(map, forKey: defaultsKey)
    }

    /// All remembered decisions, for the Settings list. Unknown raw values are
    /// dropped defensively.
    static func all(defaults: UserDefaults = .standard) -> [String: MeetingConsentDecision] {
        rawMap(defaults).reduce(into: [:]) { acc, pair in
            if let decision = MeetingConsentDecision(rawValue: pair.value) {
                acc[pair.key] = decision
            }
        }
    }

    private static func rawMap(_ defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }
}
