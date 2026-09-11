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
    static let dictationSounds = DefaultsEntry(key: "dictationSounds", fallback: false)
    static let dictationIdleTimeout = DefaultsEntry(key: "dictationIdleTimeout", fallback: 0.0)
    static let bootstrapModel = DefaultsEntry(key: "bootstrapModel", fallback: true)
    /// Which app a dictation was pasted into. Stays in the local database and
    /// never goes into a request.
    static let appStatistics = DefaultsEntry(key: "appStatistics", fallback: true)

    // MARK: Meetings

    static let autoRecordMeetings = DefaultsEntry(key: "autoRecordMeetings", fallback: true)
    static let notifyOnMeetingReady = DefaultsEntry(key: "notifyOnMeetingReady", fallback: true)
    static let speakerNamingEnabled = DefaultsEntry(key: "speakerNamingEnabled", fallback: true)
    static let meetingEchoCancellation = DefaultsEntry(key: "meetingEchoCancellation", fallback: false)
    static let meetingUseDictationEngine = DefaultsEntry(key: "meetingUseDictationEngine", fallback: false)
    static let openNotesOnMeetingStart = DefaultsEntry(key: "openNotesOnMeetingStart", fallback: true)
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

    // MARK: Zusammenfassung

    static let summarizationProvider = DefaultsEntry(
        key: "summarizationProvider", fallback: SummarizationProviderID.anthropicAPI.rawValue
    )

    // MARK: Onboarding

    static let didCompleteOnboarding = DefaultsEntry(key: "didCompleteOnboarding", fallback: false)
    static let onboardingPage = DefaultsEntry(key: "onboardingPage", fallback: 0)
}
