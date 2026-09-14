import Foundation

/// Every way a dictation can end without its text landing where it was meant
/// to — named, so each one can say what happened and what to do (Spec 29).
///
/// Before this existed, most of these ended in silence: an empty transcript hid
/// the overlay and returned, a denied microphone looked exactly like that, a
/// hotkey pressed during transcription did nothing at all. The rest ended in a
/// raw `localizedDescription`. A case here is a promise that the user hears
/// about it — Spec 30 decides how it looks.
enum DictationFailure: Equatable, Sendable {
    /// TCC says no. Checked on key-down, because a denied device still opens and
    /// delivers zeros — the failure would otherwise only surface after release.
    case microphoneDenied
    /// First use: the system prompt is up. The press that asked does not record.
    case microphoneRequested
    /// A password field has Secure Event Input on: taps see nothing, ⌘V is not
    /// delivered.
    case secureInput
    /// Only the built-in microphone, behind a closed lid — cut off in hardware.
    case lidClosed
    /// The device opened but could not start.
    case microphoneUnavailable
    /// The recording carried no signal at all (peak at digital zero).
    case nothingHeard(device: String?)
    /// There was sound, and the recognizer found no words in it.
    case nothingRecognized
    /// Held too briefly to be a push-to-talk, too long to be a lock tap.
    case tooShort
    /// The frontmost app changed between release and paste. The text is on the
    /// pasteboard instead of in the wrong window.
    case targetChanged(app: String?)
    /// Accessibility is missing; the text is on the pasteboard.
    case pasteBlocked
    /// No model could be reached for this recording.
    case modelMissing
    /// Transcription threw.
    case transcriptionFailed
    /// The input device went away and could not be resumed.
    case deviceLost

    /// One sentence: what happened.
    var title: String {
        switch self {
        case .microphoneDenied: String(localized: "Mikrofonzugriff fehlt.")
        case .microphoneRequested: String(localized: "Mikrofonzugriff wird erfragt.")
        case .secureInput: String(localized: "Sicheres Eingabefeld aktiv.")
        case .lidClosed: String(localized: "Deckel geschlossen — das eingebaute Mikrofon ist dann abgeschaltet.")
        case .microphoneUnavailable: String(localized: "Mikrofon nicht verfügbar.")
        case .nothingHeard(let device):
            if let device {
                String(localized: "Nichts gehört über „\(device)“.")
            } else {
                String(localized: "Nichts gehört.")
            }
        case .nothingRecognized: String(localized: "Nichts verstanden.")
        case .tooShort: String(localized: "Zu kurz gehalten.")
        case .targetChanged(let app):
            if let app {
                String(localized: "App gewechselt zu „\(app)“ — Text in der Zwischenablage.")
            } else {
                String(localized: "App gewechselt — Text in der Zwischenablage.")
            }
        case .pasteBlocked: String(localized: "Einfügen braucht die Bedienungshilfe.")
        case .modelMissing: String(localized: "Kein ASR-Modell verfügbar.")
        case .transcriptionFailed: String(localized: "Transkription fehlgeschlagen.")
        case .deviceLost: String(localized: "Mikrofon verschwunden — bis dahin wird transkribiert.")
        }
    }

    /// One sentence: what to do. `nil` when there is nothing to do.
    var hint: String? {
        switch self {
        case .microphoneDenied: String(localized: "Systemeinstellungen → Datenschutz → Mikrofon.")
        case .microphoneRequested: String(localized: "Nach dem Erlauben die Taste erneut drücken.")
        case .secureInput: String(localized: "In ein normales Textfeld klicken.")
        case .lidClosed: String(localized: "Externes Mikrofon oder Headset verbinden.")
        case .microphoneUnavailable: String(localized: "Anderes Mikrofon in den Einstellungen wählen.")
        case .nothingHeard: String(localized: "Anderes Mikrofon wählen oder Deckel öffnen.")
        case .nothingRecognized: nil
        case .tooShort: String(localized: "Länger halten oder kurz tippen für freihändig.")
        case .targetChanged: String(localized: "⌘V im richtigen Fenster.")
        case .pasteBlocked: String(localized: "Text liegt in der Zwischenablage.")
        case .modelMissing: String(localized: "Modell in den Einstellungen laden, dann im Menü wiederholen.")
        case .transcriptionFailed: String(localized: "Das Diktat ist aufbewahrt — im Menü wiederholen.")
        case .deviceLost: String(localized: "Mikrofon wieder verbinden.")
        }
    }

    /// Title and hint as one line, for surfaces that have only one.
    var message: String {
        guard let hint else { return title }
        return title + " " + hint
    }

    /// Not every case is an error. "Too short" and "nothing recognized" are the
    /// dictation working as designed — a warning triangle for them teaches the
    /// user to ignore the triangle.
    var isNotice: Bool {
        switch self {
        case .tooShort, .nothingRecognized, .microphoneRequested: true
        default: false
        }
    }

    var cue: SoundCue {
        switch self {
        case .tooShort: .cancelled
        default: .failed
        }
    }
}

/// The sounds a dictation makes. Named by meaning, not by file: Spec 30 swaps
/// the files, and nothing that triggers a cue has to change for that.
enum SoundCue: String, Sendable, CaseIterable {
    case start
    case locked
    case done
    case cancelled
    case failed

    /// The system sound standing in until Notable ships its own.
    var systemSoundName: String {
        switch self {
        case .start: "Tink"
        case .locked: "Tink"
        case .done: "Pop"
        case .cancelled: "Bottle"
        case .failed: "Basso"
        }
    }
}
