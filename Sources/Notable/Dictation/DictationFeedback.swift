import AppKit
import os

/// How a dictation talks back: the HUD's failure lines and the sounds, and the
/// rule that a failure never covers a running recording (Spec 29, Spec 30).
/// Taken out of `DictationController` in Spec 29 §9.
@MainActor
final class DictationFeedback {
    private static let log = Logger(subsystem: "de.jonasgehring.notable", category: "dictation")

    let overlay: DictationOverlayController
    /// Supplied by the controller.
    var isCapturing: () -> Bool = { false }
    /// A failure of an older job that arrived while a new recording ran — said
    /// once nothing runs any more instead of covering the waveform.
    private var deferredFailure: DictationFailure?

    init(overlay: DictationOverlayController) {
        self.overlay = overlay
    }

    /// A sound always; words unless a recording is running, then they wait.
    func report(_ failure: DictationFailure) {
        playCue(failure.cue)
        Self.log.info("Diktat: \(failure.title, privacy: .public)")
        guard !isCapturing() else {
            deferredFailure = failure
            return
        }
        show(failure)
    }

    /// Says the failure that waited for a recording to end.
    func flushDeferred() {
        guard let failure = deferredFailure else { return }
        deferredFailure = nil
        show(failure)
    }

    func show(_ failure: DictationFailure) {
        if failure.isNotice {
            overlay.flashNotice(failure.title, hint: failure.hint)
        } else {
            overlay.flashError(failure.title, hint: failure.hint)
        }
    }

    /// Hides the overlay unless a newer recording is using it.
    func hideIfIdle() {
        guard !isCapturing() else { return }
        overlay.hide()
    }

    /// Plays the sound for a moment of the dictation (on by default since Spec 29).
    func playCue(_ cue: SoundCue) {
        guard DefaultsKey.dictationSounds.value() else { return }
        cue.play()
    }
}
