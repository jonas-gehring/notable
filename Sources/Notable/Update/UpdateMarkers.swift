import Foundation

/// What an update leaves behind for the next launch (Spec 25 §3.6–3.8).
///
/// An unattended update used to be invisible: no message afterwards, no line in
/// Settings, no trace of why one was waiting. From the outside it looked as if
/// the feature did not exist. These markers are the before/after: written right
/// before the app quits for the swap, read once by the version that starts.
enum UpdateMarkers {
    // The attempt, written before quitting.
    static let attemptFromKey = "updateInstalledFrom"
    static let attemptToKey = "updateInstallingTo"
    static let attemptAtKey = "updateInstalledAt"
    static let attemptUnattendedKey = "updateInstalledUnattended"
    static let attemptNotesKey = "updateInstallingNotes"
    static let restoreWindowsKey = "updateRestoreWindows"
    // The last update that actually took, for Settings.
    static let lastVersionKey = "updateLastVersion"
    static let lastAtKey = "updateLastAt"
    static let lastUnattendedKey = "updateLastUnattended"
    static let lastNotesKey = "updateLastNotes"
    // The 72-hour nudge.
    static let waitingVersionKey = "updateWaitingVersion"
    static let waitingSinceKey = "updateWaitingSince"
    static let nudgedVersionKey = "updateNudgedVersion"

    enum Outcome: Equatable {
        case installed(from: String, to: String)
        /// Still the old version after the swap: the move failed or the copy
        /// rolled back, and the script relaunched what was there.
        case failed(target: String, running: String)
    }

    struct Record: Equatable {
        var version: String
        var at: Date
        var unattended: Bool
        var notes: String
    }

    static func recordBeforeQuit(
        from: String,
        to: String,
        notes: String,
        unattended: Bool,
        windows: [String],
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        defaults.set(from, forKey: attemptFromKey)
        defaults.set(to, forKey: attemptToKey)
        defaults.set(now.timeIntervalSince1970, forKey: attemptAtKey)
        defaults.set(unattended, forKey: attemptUnattendedKey)
        defaults.set(notes, forKey: attemptNotesKey)
        defaults.set(windows, forKey: restoreWindowsKey)
    }

    /// Once per update, at launch: did it take? A success becomes the "last
    /// update" record; either way the attempt is cleared, so it is said once.
    static func consumeOutcome(running: String, defaults: UserDefaults = .standard) -> Outcome? {
        guard let from = defaults.string(forKey: attemptFromKey),
              let to = defaults.string(forKey: attemptToKey) else { return nil }
        let at = defaults.double(forKey: attemptAtKey)
        let unattended = defaults.bool(forKey: attemptUnattendedKey)
        let notes = defaults.string(forKey: attemptNotesKey) ?? ""
        for key in [attemptFromKey, attemptToKey, attemptAtKey, attemptUnattendedKey, attemptNotesKey] {
            defaults.removeObject(forKey: key)
        }
        guard let runningVersion = SemanticVersion(running), let fromVersion = SemanticVersion(from),
              runningVersion > fromVersion
        else { return .failed(target: to, running: running) }
        defaults.set(running, forKey: lastVersionKey)
        defaults.set(at, forKey: lastAtKey)
        defaults.set(unattended, forKey: lastUnattendedKey)
        defaults.set(notes, forKey: lastNotesKey)
        return .installed(from: from, to: running)
    }

    static func lastUpdate(defaults: UserDefaults = .standard) -> Record? {
        guard let version = defaults.string(forKey: lastVersionKey) else { return nil }
        return Record(
            version: version,
            at: Date(timeIntervalSince1970: defaults.double(forKey: lastAtKey)),
            unattended: defaults.bool(forKey: lastUnattendedKey),
            notes: defaults.string(forKey: lastNotesKey) ?? ""
        )
    }

    /// The windows that were open when the app quit for the update — read once.
    static func consumeRestoreWindows(defaults: UserDefaults = .standard) -> [String] {
        defer { defaults.removeObject(forKey: restoreWindowsKey) }
        return defaults.stringArray(forKey: restoreWindowsKey) ?? []
    }

    /// Since when `version` has been waiting, starting the clock on first ask.
    static func waitingSince(_ version: String, defaults: UserDefaults = .standard, now: Date = Date()) -> Date {
        if defaults.string(forKey: waitingVersionKey) != version {
            defaults.set(version, forKey: waitingVersionKey)
            defaults.set(now.timeIntervalSince1970, forKey: waitingSinceKey)
        }
        return Date(timeIntervalSince1970: defaults.double(forKey: waitingSinceKey))
    }

    static func wasNudged(_ version: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: nudgedVersionKey) == version
    }

    static func markNudged(_ version: String, defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: nudgedVersionKey)
    }
}
