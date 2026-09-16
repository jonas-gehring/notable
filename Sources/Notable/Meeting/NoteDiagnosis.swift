import Foundation

/// Why a meeting note has no speaker names, and where its title came from
/// (Spec 35) — one short code each, written into `meta.json` and the log.
///
/// Measured on 18 meetings (2026-09-15): one of 23 remote labels carried a
/// correct name, and titles fell back to "Meeting" — but no record said which
/// of half a dozen silent exits had been taken. The mic track may have been
/// silent, the calendar may never have seen the event, the provider may have
/// failed, the model may have proposed nothing, or validation may have dropped
/// everything it proposed. Each wants a different fix, so the note says which.
///
/// Codes, not sentences: they are for the archive and the log, not for the
/// interface, and they stay stable so meetings can be counted by them.
enum NoteDiagnosis {
    static func naming(
        hasTranscript: Bool,
        micSilent: Bool,
        remoteLabels: Int,
        screenNamed: Int,
        calendarNamed: Int = 0,
        voiceNamed: Int = 0,
        openLabels: Int,
        enabled: Bool,
        outcome: SpeakerNameResolver.Outcome?
    ) -> String {
        guard hasTranscript else { return "keinTranskript" }
        guard remoteLabels > 0 else { return "keineGegenseite" }
        if micSilent { return "mikrofonStumm" }
        let withoutModel = screenNamed + calendarNamed + voiceNamed
        // The voice is the source that costs nothing to try and is the easiest
        // to be wrong about, so it is counted separately wherever it fired.
        let voice = voiceNamed > 0 ? ", stimme: \(voiceNamed)" : ""
        if openLabels == 0 { return "benannt: \(withoutModel) von \(remoteLabels) (ohne Modell\(voice))" }
        guard enabled else { return "ausgeschaltet" }
        guard let outcome else { return "nichtVersucht" }
        switch outcome.result {
        case .noLabels:
            return "keineOffenenLabels"
        case .emptyTranscript:
            return "keinTranskript"
        case .providerFailed(let message):
            return "anbieterFehler: " + String(message.prefix(120))
        case .answered:
            if outcome.proposed == 0 { return "modellOhneNamen (\(openLabels) offen)" }
            if outcome.accepted == 0 { return "verworfen: \(outcome.proposed) vorgeschlagen, 0 übernommen" }
            return "benannt: \(outcome.accepted + withoutModel) von \(remoteLabels)"
                + (voice.isEmpty ? "" : " (\(voice.dropFirst(2)))")
        }
    }

    /// Whether the finished note should offer the speaker dialog (Spec 36
    /// §3.2): nothing was named, and there is more than one remote voice to
    /// tell apart. With a single unnamed voice the dialog is one text field
    /// the note list already has a button for.
    static func offersSpeakerNaming(naming: String, remoteLabels: Int) -> Bool {
        !naming.contains("benannt:") && remoteLabels > 1
    }

    /// What the call window contributed (Spec 36 §3.1). `bildschirmOhneDaten`
    /// is the one that matters: an adapter exists for this app and found
    /// nothing, three meetings running — which is what an app update looks like
    /// from here.
    static func screen(adapterRan: Bool, observations: Int, meetingsWithoutData: Int) -> String {
        guard adapterRan else { return "keinAdapter" }
        guard observations > 0 else { return "bildschirmOhneDaten: \(meetingsWithoutData) Meetings" }
        return "gelesen: \(observations) Beobachtungen"
    }

    static func title(
        eventAtStart: Bool,
        eventAtStop: Bool,
        windowTitled: Bool = false,
        modelTitled: Bool,
        callSource: Bool,
        calendarAccess: Bool,
        hasTranscript: Bool,
        summaryFailed: Bool
    ) -> String {
        if eventAtStart { return "kalender" }
        if eventAtStop { return "kalenderBeimStopp" }
        // Before the model (decided 2026-09-16): the window quotes the title the
        // organiser chose, the model invents one from the transcript.
        if windowTitled { return "fenster" }
        if modelTitled { return "modell" }
        let calendar = calendarAccess ? "keinPassenderTermin" : "keinKalenderzugriff"
        let model = !hasTranscript ? "keinTranskript"
            : summaryFailed ? "zusammenfassungFehlgeschlagen"
            : "modellOhneTitel"
        return (callSource ? "callQuelle" : "fallback") + ": \(calendar), \(model)"
    }
}
