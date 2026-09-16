import Foundation

/// Spec 38 §3.5: the pickers that stand for **two** `UserDefaults` keys.
///
/// Two settings that are two expressions of one question became one control
/// with steps — but the keys underneath stay exactly where they were, because a
/// renamed or deleted key loses a setting the user made without a word
/// (`DefaultsKey`). So the mapping between a picker position and a key pair is
/// the load-bearing part, and it lives here: pure, free of `UserDefaults` and of
/// SwiftUI, so every position and every stored combination has a test rather
/// than a click.
///
/// Both types answer the same two questions:
///
/// - **position → keys**: what a choice writes. Total, by construction.
/// - **keys → position**: what a stored pair reads as. *Not* total — there are
///   four combinations and three positions — so a pair that matches no position
///   resolves to the **stronger** one, and the next change writes a clean pair.
///   Showing the weaker one would understate what the app is actually doing,
///   which is the wrong direction for both of these (one reaches outside
///   Notable, the other sends text off the device).

// MARK: - Was während des Diktats mit dem Ton passiert

/// Three toggles became one picker (§3.1 rule 2): "Töne", "Wiedergabe
/// pausieren" and "Systemton stummschalten" were three checkboxes for one
/// question. The sounds Notable makes itself stayed a switch — they are about
/// Notable — and the two that reach *outside* Notable are these.
///
/// Keys: ``MediaInterrupter/Key/pausePlayback`` and
/// ``MediaInterrupter/Key/muteOutput``, both `false` when unset, so the unset
/// state is `nothing` and nothing about the default behaviour moves.
enum DictationAudioMode: String, CaseIterable, Identifiable, Sendable {
    /// Neither key set — the default, and the only position that touches
    /// nothing outside Notable.
    case nothing
    case pausePlayback
    case muteOutput

    var id: String { rawValue }

    var label: String {
        let key: String.LocalizationValue = switch self {
        case .nothing: "Nichts"
        case .pausePlayback: "Wiedergabe pausieren"
        case .muteOutput: "Systemton stummschalten"
        }
        return String(localized: key)
    }

    /// What this position writes into `pauseMediaDuringDictation`.
    var pausePlayback: Bool { self == .pausePlayback }

    /// What this position writes into `muteSystemAudioDuringDictation`.
    var muteOutput: Bool { self == .muteOutput }

    /// What a stored pair reads as.
    ///
    /// `(true, true)` is reachable — both toggles existed side by side until
    /// Spec 38 — and it is not a position. It reads as `muteOutput`, the
    /// stronger of the two: muting the output silences everything, where
    /// pausing only stops whatever app happens to be playing. Reading the
    /// weaker one would tell someone their Mac still makes noise while it does
    /// not.
    init(pausePlayback: Bool, muteOutput: Bool) {
        if muteOutput {
            self = .muteOutput
        } else if pausePlayback {
            self = .pausePlayback
        } else {
            self = .nothing
        }
    }
}

// MARK: - Woher Sprechernamen kommen dürfen

/// Two toggles became one picker, ordered by what leaves the device.
///
/// They were two equal-looking checkboxes with a privacy axis between them:
/// `screenSpeakerRecognition` reads the call window through Accessibility and
/// nothing leaves the Mac, while `speakerNamingEnabled` sends transcript text to
/// the summarization provider so a model can map a spoken name onto a voice.
/// Presented as two ticks, that difference was invisible; as three steps it is
/// the order itself.
///
/// The screen source is the *weaker* one, so it comes on first and stays on for
/// the strong position — `(naming: true, screen: false)` is therefore not a
/// position, and reads as the strong one because it is the one where text
/// leaves.
enum SpeakerNamingMode: String, CaseIterable, Identifiable, Sendable {
    /// Nothing is named automatically; the speaker dialog still works.
    case off
    /// Screen, calendar and voice — all of it on this Mac.
    case onDevice
    /// Additionally the names spoken in the conversation, which means the
    /// transcript reaches the summarization provider.
    case fromConversation

    var id: String { rawValue }

    var label: String {
        let key: String.LocalizationValue = switch self {
        case .off: "Aus"
        case .onDevice: "Nur auf dem Gerät"
        case .fromConversation: "Auch aus dem Gespräch"
        }
        return String(localized: key)
    }

    /// The one line that says what this position costs. Shown under the picker,
    /// so the provider is named at the point of choosing.
    var explanation: String {
        let key: String.LocalizationValue = switch self {
        case .off: "Sprecher heißen „Sprecher 1“, „Sprecher 2“ — benennen kannst du sie jederzeit selbst."
        case .onDevice: "Call-Fenster, Kalender und Stimme. Nichts verlässt das Gerät."
        case .fromConversation: "Zusätzlich die im Gespräch genannten Namen — dafür geht das Transkript an den Anbieter der Zusammenfassung."
        }
        return String(localized: key)
    }

    /// What this position writes into `speakerNamingEnabled` — the key that
    /// sends text out.
    var namesFromConversation: Bool { self == .fromConversation }

    /// What this position writes into `screenSpeakerRecognition`.
    var readsScreen: Bool { self != .off }

    /// What a stored pair reads as. `(naming: true, screen: false)` is not a
    /// position and resolves to `fromConversation`, because that is the pair's
    /// strong half: text is leaving the device, and the picker has to say so.
    init(namesFromConversation: Bool, readsScreen: Bool) {
        if namesFromConversation {
            self = .fromConversation
        } else if readsScreen {
            self = .onDevice
        } else {
            self = .off
        }
    }
}

// MARK: - Aufbewahrung

/// The one retention picker (§3.2, Daten): how long raw meeting audio is kept.
///
/// Six pickers became this one. The other five keys are still read
/// (`RetentionPolicy.fromDefaults`) and still settable under "Erweitert" — what
/// went away is five questions asked of everyone to serve the one person who
/// ever answered them.
///
/// `0` is the stored value for "off" everywhere in `RetentionPolicy`, and here
/// "off" means *keep forever*, which is why the label is "Immer" rather than
/// "Aus": this picker only ever appears under a master switch that is already
/// on, and "Aus" next to "automatisch aufräumen: an" reads as a contradiction.
enum AudioRetentionChoice: Int, CaseIterable, Identifiable, Sendable {
    case week = 7
    case month = 30
    case quarter = 90
    case year = 365
    case forever = 0

    var id: Int { rawValue }

    var label: String {
        let key: String.LocalizationValue = switch self {
        case .week: "7 Tage"
        case .month: "30 Tage"
        case .quarter: "90 Tage"
        case .year: "1 Jahr"
        case .forever: "Immer"
        }
        return String(localized: key)
    }

    /// A stored value that is none of the five — someone's hand-set 45 — keeps
    /// its meaning by rounding **up** to the next offered step, never down: an
    /// audio file deleted earlier than the user asked for is gone.
    static func nearest(days: Int) -> AudioRetentionChoice {
        guard days > 0 else { return .forever }
        let steps: [AudioRetentionChoice] = [.week, .month, .quarter, .year]
        return steps.first { days <= $0.rawValue } ?? .forever
    }
}
