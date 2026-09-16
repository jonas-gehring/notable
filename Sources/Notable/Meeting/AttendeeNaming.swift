import Foundation

/// Naming the one remote voice from the one invited guest (Spec 35 §3.2, decided
/// 2026-09-16).
///
/// Measured on the meeting of 2026-09-15: one guest in the calendar
/// (`jana.schultze`), one remote voice, and no name at all in the note. The model
/// was asked and declined — correctly, because the only name in the transcript
/// ("Schulze") was said by the local user *about* someone, which attests nothing
/// about who is speaking. The calendar does attest it: a meeting with exactly one
/// other invitee has exactly one other person in it.
///
/// This is the one place where a name is applied **without** being spoken, and it
/// stays hemmed in: exactly one large remote cluster, exactly one guest besides
/// the account holder, and only onto a label nothing else has named. Two voices
/// or two guests, and it does nothing — "lieber anonym als falsch" is untouched
/// everywhere else.
enum OneToOneNaming {
    /// - Parameters:
    ///   - attendees: invited names from the calendar (the local user included;
    ///     they are filtered out here).
    ///   - openLabels: labels nothing has named yet (`ScreenNaming.unnamedLabels`).
    ///   - largeClusters: remote clusters that are not splinters
    ///     (`SpeakerClusterCleanup.largeLabels`).
    static func name(
        attendees: [String],
        openLabels: Set<String>,
        largeClusters: [String],
        ownerTokens: Set<String>
    ) -> (label: String, name: String)? {
        let guests = attendees
            .map(AttendeeName.readable)
            .filter { !$0.isEmpty && !SpeakerNameResolver.isOwnerName($0, ownerTokens: ownerTokens) }
        guard guests.count == 1, largeClusters.count == 1 else { return nil }
        let label = largeClusters[0]
        guard openLabels.contains(label) else { return nil }
        return (label, guests[0])
    }
}

/// What EventKit hands over is not always a name.
enum AttendeeName {
    /// "jana.schultze" → "Jana Schultze"; "Jana Schultze" and anything that does
    /// not look like an address part are returned unchanged.
    ///
    /// EventKit gives a participant's display name, which for many accounts is
    /// the address' local part. `CalendarMonitor` drops anything containing an
    /// `@` as unusable, but `jana.schultze` passes that filter and then reads as
    /// a name nobody has — least of all in a transcript.
    static func readable(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = trimmed.split(separator: "@").first.map(String.init) ?? trimmed
        guard !local.contains(" ") else { return trimmed }
        let parts = local.split(whereSeparator: { $0 == "." || $0 == "_" }).map(String.init)
        guard parts.count >= 2,
              parts.allSatisfy({ part in part.count >= 2 && part.allSatisfy { $0.isLetter || $0 == "-" } })
        else { return trimmed }
        return parts.map(capitalizedName).joined(separator: " ")
    }

    /// "anna-lena" → "Anna-Lena": every part of a double name gets its capital.
    private static func capitalizedName(_ part: String) -> String {
        part.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: "-")
    }
}
