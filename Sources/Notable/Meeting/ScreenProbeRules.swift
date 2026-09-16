import Foundation

/// When the call window measures itself, and when an adapter has gone blind
/// (Spec 36 §3.1) — pure, so both rules are tested rather than believed.
///
/// The Stufe-0 measurement of Spec 24 never happened. Not because it is hard:
/// because it asks someone to press a button in Settings *in the middle of a
/// call*, and nobody does that. So it happens by itself now — once per app and
/// version, a minute into the call, exactly when an adapter would be needed.
enum ScreenProbeRule {
    /// How long after the start of a recording the window is read. The
    /// participant list stands by then, and whoever joined late is in it.
    static let delay: TimeInterval = 60

    /// The probe file holds the names shown in the call window. It lives in
    /// `~/Library/Logs`, which no retention run touches (they only know
    /// `spool-*`), so it has its own age limit.
    static let keep: TimeInterval = 30 * 24 * 3600

    /// One marker per app **and version**: a new Teams release is a new
    /// measurement, because the tree it exposes is exactly what may have
    /// changed.
    static func markerKey(bundleID: String, version: String) -> String {
        "screenProbeTaken.\(bundleID).\(version)"
    }

    static func shouldProbe(bundleID: String, version: String, defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: markerKey(bundleID: bundleID, version: version))
    }

    /// Marked only once a file has actually been written — a failed probe must
    /// be able to happen again.
    static func markProbed(bundleID: String, version: String, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: markerKey(bundleID: bundleID, version: version))
    }

    /// Which probe files have outlived their thirty days.
    static func expired(
        _ files: [(url: URL, modified: Date)], now: Date, keeping: TimeInterval = keep
    ) -> [URL] {
        files.filter { now.timeIntervalSince($0.modified) > keeping }.map(\.url)
    }
}

/// "Der Adapter liefert seit drei Meetings nichts" (Spec 24 §6, built here
/// because from the first adapter on it is needed).
///
/// An adapter that has stopped finding anything is the *good* failure — the
/// other one writes a confident wrong name. It still has to be said, or the
/// speaker names quietly stop appearing and nothing anywhere says why.
enum ScreenDataWatch {
    static let key = "screenAdapterWithoutData"
    /// From here on the finished-note notification says it.
    static let warnAfter = 3

    /// The new count. A meeting without an adapter says nothing either way —
    /// there is no adapter to have gone blind.
    static func next(_ current: Int, adapterRan: Bool, observations: Int) -> Int {
        guard adapterRan else { return current }
        return observations > 0 ? 0 : current + 1
    }

    static func update(
        adapterRan: Bool, observations: Int, defaults: UserDefaults = .standard
    ) -> Int {
        let updated = next(defaults.integer(forKey: key), adapterRan: adapterRan, observations: observations)
        defaults.set(updated, forKey: key)
        return updated
    }
}
