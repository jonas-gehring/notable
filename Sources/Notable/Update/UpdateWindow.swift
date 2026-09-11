import Foundation

/// When an update may replace the running app (Spec 25) — pure, table-tested.
///
/// The old rule was a single line: install when no Notable window is visible.
/// In daily use that is the exception, not the rule — the notes, statistics and
/// settings windows are built to stay open — so a found update waited, silently,
/// six hours at a time. And two states in which a restart destroys work were not
/// checked at all: a dictation in flight, and a meeting note still being
/// produced (whose API summary would then be paid for twice).
///
/// So the question is split in two. **Hard locks** are states where quitting
/// loses something; nothing overrides them, and ⌘Q and the manual install
/// button ask the same function. Everything else is about *attention*: open
/// windows only hold an update back while someone is actually using the Mac.
enum UpdateWindow {
    struct Inputs: Equatable {
        var isRecording = false
        var processingNotes = 0
        /// Recording, transcribing, enhancing or pasting a dictation.
        var dictationBusy = false
        /// "Eigene Notizen" of a meeting open for editing in the notes window.
        var draftOpen = false
        var windowVisible = false
        /// Seconds since the last keyboard or mouse event, system-wide.
        var idleSeconds: TimeInterval = 0
        var screenLocked = false
    }

    enum Reason: String, Equatable, Sendable {
        case recording
        case processing
        case dictation
        case draft
        case windowsInUse

        /// The end of "wartet auf einen ruhigen Moment — gerade: …".
        var label: String {
            switch self {
            case .recording: String(localized: "ein Meeting wird aufgenommen")
            case .processing: String(localized: "eine Meeting-Notiz wird erstellt")
            case .dictation: String(localized: "ein Diktat läuft")
            case .draft: String(localized: "eigene Notizen sind in Bearbeitung")
            case .windowsInUse: String(localized: "ein Notable-Fenster ist in Benutzung")
            }
        }
    }

    enum Decision: Equatable {
        case installNow
        case wait(Reason)
    }

    /// Ten minutes without a keystroke or a mouse move: nobody is reading.
    static let idleThreshold: TimeInterval = 10 * 60
    /// After this long, an update held back only by open windows asks once.
    static let nudgeAfter: TimeInterval = 72 * 60 * 60

    /// A state in which quitting now would lose work, or `nil`.
    static func hardLock(_ inputs: Inputs) -> Reason? {
        if inputs.isRecording { return .recording }
        if inputs.processingNotes > 0 { return .processing }
        if inputs.dictationBusy { return .dictation }
        if inputs.draftOpen { return .draft }
        return nil
    }

    static func decide(_ inputs: Inputs) -> Decision {
        if let lock = hardLock(inputs) { return .wait(lock) }
        if !inputs.windowVisible { return .installNow }
        // The windows come back a second later (`UpdateMarkers`), so an open
        // window only counts while someone is in front of it.
        if inputs.idleSeconds >= idleThreshold || inputs.screenLocked { return .installNow }
        return .wait(.windowsInUse)
    }

    /// Whether to offer "Jetzt installieren" once: the update has waited three
    /// days and the reason is open windows during active use. A hard lock never
    /// triggers it — the answer there is already "not now".
    static func shouldNudge(waitingSince: Date?, now: Date, reason: Reason, alreadyNudged: Bool) -> Bool {
        guard reason == .windowsInUse, !alreadyNudged, let waitingSince else { return false }
        return now.timeIntervalSince(waitingSince) >= nudgeAfter
    }
}
