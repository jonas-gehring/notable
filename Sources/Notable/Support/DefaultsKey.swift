import Foundation

/// A `UserDefaults` key together with the value it means when nothing is stored.
///
/// The pair is the point. `defaults.bool(forKey:)` answers `false` for "never
/// set", which is the wrong answer for every switch that is on by default — so
/// the readers all wrote `object(forKey:) as? Bool ?? true` and the views wrote
/// `@AppStorage("…") var x = true`, and the two `true`s were separate facts that
/// nothing kept in step.
struct DefaultsEntry<Value: Sendable>: Sendable {
    let key: String
    let fallback: Value

    func value(_ defaults: UserDefaults = .standard) -> Value {
        defaults.object(forKey: key) as? Value ?? fallback
    }
}

/// Every `UserDefaults` key the interface writes, in one place.
///
/// Not for tidiness. A key written as a string literal in a view *and* in the
/// controller that reads it is a key that can be mistyped in one of the two
/// places — and a mistyped key is not a compiler error, it is a switch that
/// silently forgets its value. Six of them stood in two places when this was
/// written; `summarizationProvider` stood in six.
///
/// **These strings only moved; none of them was renamed.** A changed key loses
/// a setting the user made, without a word. So `dictationEnhancementEnabled`
/// stays ugly and stays.
///
/// Keys that already live next to the logic that owns them — `HotkeySpec`,
/// `RetentionPolicy.Key`, `MediaInterrupter`, `ASREngineID.storageKey`,
/// `WhisperModelSize.storageKey`, `MenuBarIcon.storageKey` — stay there. That is
/// the better arrangement; this enum is for the ones that had no home at all.
enum DefaultsKey {
    // MARK: Menüleiste und Statistik

    static let showUsageInMenu = DefaultsEntry(key: "showUsageInMenu", fallback: true)
    static let showNextMeeting = DefaultsEntry(key: "showNextMeeting", fallback: true)
    /// The assumption behind every "gespart" figure — see ``TypingSpeedStepper``.
    static let typingWPM = DefaultsEntry(key: "typingWPM", fallback: 40.0)

    // MARK: Diktat

    static let polishRemoveFillers = DefaultsEntry(key: "polishRemoveFillers", fallback: true)
    static let polishApplyITN = DefaultsEntry(key: "polishApplyITN", fallback: true)
    static let polishParagraphs = DefaultsEntry(key: "polishParagraphs", fallback: true)
    static let polishStructureCommands = DefaultsEntry(key: "polishStructureCommands", fallback: true)
    static let polishFuzzyDictionary = DefaultsEntry(key: "polishFuzzyDictionary", fallback: true)
    static let appContextFormatting = DefaultsEntry(key: "appContextFormatting", fallback: true)
    /// On since Spec 29: with it off, cancel, failure, lock and "too short" all
    /// ended without any signal. Only the unset key changes — a user who switched
    /// the sounds off keeps them off.
    static let dictationSounds = DefaultsEntry(key: "dictationSounds", fallback: true)
    /// 45 s since Spec 29, with hysteresis (`IdleDetector`). Off, a forgotten
    /// hands-free lock stayed open until the ten-minute cap.
    ///
    /// **No interface since Spec 38** — the number was a stepper under
    /// "Erweitert" answering a question the code can answer (§3.1 rule 1). Only
    /// the *switch* is left ("Freihändig bei Stille beenden", 45 ⇄ 0), and a
    /// value someone set by hand is still read and still used.
    static let dictationIdleTimeout = DefaultsEntry(key: "dictationIdleTimeout", fallback: 45.0)
    /// **No interface since Spec 38** (§3.2, Diktat › Erweitert): whether a
    /// stand-in model carries dictation on a cold cache is not a preference —
    /// the alternative is no dictation at all until a gigabyte has come down.
    /// Spec 33's deviation 3 is redeemed here. Still read by
    /// `DictationEngines`, so a stored `false` keeps working.
    static let bootstrapModel = DefaultsEntry(key: "bootstrapModel", fallback: true)
    /// Which app a dictation was pasted into. Stays in the local database and
    /// never goes into a request.
    static let appStatistics = DefaultsEntry(key: "appStatistics", fallback: true)

    // MARK: Meetings

    static let autoRecordMeetings = DefaultsEntry(key: "autoRecordMeetings", fallback: true)
    static let notifyOnMeetingReady = DefaultsEntry(key: "notifyOnMeetingReady", fallback: true)
    static let speakerNamingEnabled = DefaultsEntry(key: "speakerNamingEnabled", fallback: true)
    /// The account holder's full name, for telling their own name apart from a
    /// remote speaker's (Spec 35). macOS often knows only the first name —
    /// measured here, `NSFullUserName()` is "Jonas" — so "Herr Gehring" slipped
    /// past `SpeakerNameResolver.isOwnerName`.
    static let ownerName = DefaultsEntry(key: "ownerName", fallback: "")
    /// Read the call window for who takes part and who is speaking (Spec 24).
    /// On by default — decided 2026-09-11: Accessibility only, which Notable
    /// already holds for pasting, read-only, only during a recording the user
    /// agreed to.
    static let screenSpeakerRecognition = DefaultsEntry(key: "screenSpeakerRecognition", fallback: true)
    /// Remember how named speakers sound, to recognise them in the next meeting
    /// (Spec 36 Stufe 3). **Off by default, decided 2026-09-16**: an embedding
    /// is a biometric feature of another person, sitting on this Mac — a new
    /// class of data deserves a deliberate switching-on, even when nothing can
    /// be reconstructed from it and it never leaves the device.
    static let voiceProfilesEnabled = DefaultsEntry(key: "voiceProfilesEnabled", fallback: false)
    static let meetingEchoCancellation = DefaultsEntry(key: "meetingEchoCancellation", fallback: false)
    static let meetingUseDictationEngine = DefaultsEntry(key: "meetingUseDictationEngine", fallback: false)
    static let openNotesOnMeetingStart = DefaultsEntry(key: "openNotesOnMeetingStart", fallback: true)
    /// **No interface since Spec 38** (§3.2, Meetings › Notizen im Call): the
    /// notes window floats — that is what it is for. A switch turning off the
    /// one property that makes the window useful next to a call is not a
    /// choice worth offering. Still read by `LiveNotesView`.
    static let meetingNotesFloating = DefaultsEntry(key: "meetingNotesFloating", fallback: true)
    static let meetingHookPath = DefaultsEntry(key: "meetingHookPath", fallback: "")
    /// A microphone pinned in Settings, by UID — for meetings and dictation
    /// alike. Empty means automatic (`InputDevicePolicy`).
    static let inputDeviceUID = DefaultsEntry(key: "inputDeviceUID", fallback: "")
    /// Name of the device the last meeting was recorded from, shown in Settings.
    static let lastMeetingInputDevice = DefaultsEntry(key: "lastMeetingInputDevice", fallback: "")

    // MARK: Notizen-Ordner

    /// Notable's mark on the notes folder in Finder (Spec 27).
    static let notesFolderIcon = DefaultsEntry(key: "notesFolderIcon", fallback: true)
    /// Which folder Notable put its icon on — the only way to tell its icon from
    /// one the user designed (`FolderIconRule`). Empty means none.
    static let notesFolderIconPath = DefaultsEntry(key: "notesFolderIconPath", fallback: "")
    /// Which `FolderIcon.designVersion` drew the icon at `notesFolderIconPath`.
    /// Unset means version 1 — the waveform icon every folder carried before the
    /// version was recorded — so those folders get the current design.
    static let notesFolderIconVersion = DefaultsEntry(key: "notesFolderIconVersion", fallback: 1)

    // MARK: Zusammenfassung

    static let summarizationProvider = DefaultsEntry(
        key: "summarizationProvider", fallback: SummarizationProviderID.anthropicAPI.rawValue
    )

    // MARK: Momente (Spec 37)

    /// "✓ · 42 Wörter" after the paste. On, because the sound alone says that
    /// something happened but not how much — and this is the one place Notable
    /// says a dictation worked.
    ///
    /// **No interface yet:** it belongs on Diktat › Anzeige & Ton, which Spec 36
    /// is being built into. A stored `false` is honoured all the same, and the
    /// moment then never appears.
    static let showWordCountAfterDictation = DefaultsEntry(key: "showWordCountAfterDictation", fallback: true)
    /// One notification a week (Allgemein › Mitteilungen). On, because a review
    /// nobody asked for is exactly the moment worth having — and it is one
    /// notification, switchable in one click.
    static let weeklyRecap = DefaultsEntry(key: "weeklyRecap", fallback: true)
    /// The last recap's timestamp, as `timeIntervalSince1970`; 0 means never.
    static let weeklyRecapLastPosted = DefaultsEntry(key: "weeklyRecapLastPosted", fallback: 0.0)
    /// The milestone ids already marked (`Milestone.id`).
    ///
    /// **A missing key is the backfill signal**, which is why the fallback is
    /// empty and nothing else may write it: the first launch after the update
    /// marks every threshold the existing 234 dictations already passed, without
    /// celebrating one of them. With the key present, the app has counted before.
    static let milestonesReached = DefaultsEntry<[String]>(key: "milestonesReached", fallback: [])

    // MARK: Onboarding

    static let didCompleteOnboarding = DefaultsEntry(key: "didCompleteOnboarding", fallback: false)
    static let onboardingPage = DefaultsEntry(key: "onboardingPage", fallback: 0)
}
