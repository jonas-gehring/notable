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
        openLabels: Int,
        enabled: Bool,
        outcome: SpeakerNameResolver.Outcome?
    ) -> String {
        guard hasTranscript else { return "keinTranskript" }
        guard remoteLabels > 0 else { return "keineGegenseite" }
        if micSilent { return "mikrofonStumm" }
        let withoutModel = screenNamed + calendarNamed
        if openLabels == 0 { return "benannt: \(withoutModel) von \(remoteLabels) (ohne Modell)" }
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
        }
    }

    static func title(
        eventAtStart: Bool,
        eventAtStop: Bool,
        modelTitled: Bool,
        callSource: Bool,
        calendarAccess: Bool,
        hasTranscript: Bool,
        summaryFailed: Bool
    ) -> String {
        if eventAtStart { return "kalender" }
        if eventAtStop { return "kalenderBeimStopp" }
        if modelTitled { return "modell" }
        let calendar = calendarAccess ? "keinPassenderTermin" : "keinKalenderzugriff"
        let model = !hasTranscript ? "keinTranskript"
            : summaryFailed ? "zusammenfassungFehlgeschlagen"
            : "modellOhneTitel"
        return (callSource ? "callQuelle" : "fallback") + ": \(calendar), \(model)"
    }
}
