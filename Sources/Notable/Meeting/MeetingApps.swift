import Foundation

/// The meeting clients Notable knows, in one table.
///
/// It used to be two. `MeetingDetector` held bundle id → name → tier for
/// detection, and the settings pane had a hand-written `displayName(for:)`
/// switch over the same bundle ids for the remembered-consent list. Adding a
/// client meant editing both, and nothing said so — the second one would simply
/// keep showing a raw `Cisco-Systems.Spark` in the settings window until someone
/// noticed.
///
/// Pure and free of any detection machinery, so the settings pane can ask it
/// without pulling in the CoreAudio polling behind the detector.
enum MeetingApps {
    /// How a client's audio behaves, which decides how a call may end.
    ///
    /// `dedicated` apps are only running when there is a call, so their output
    /// falling silent is evidence. `ambient` ones (Slack, browsers) play audio
    /// all day, so only their microphone counts.
    enum Tier: Sendable, Equatable { case dedicated, browser, ambient }

    struct Known: Sendable, Equatable {
        let bundleID: String
        let name: String
        let tier: Tier
    }

    /// Native clients. Match by **prefix** at the call site — Electron and
    /// Chromium do audio in a `…​.helper` process.
    static let native: [Known] = [
        Known(bundleID: "us.zoom.xos", name: "Zoom", tier: .dedicated),
        Known(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", tier: .dedicated),
        Known(bundleID: "com.microsoft.teams", name: "Microsoft Teams", tier: .dedicated),
        Known(bundleID: "com.apple.FaceTime", name: "FaceTime", tier: .dedicated),
        Known(bundleID: "Cisco-Systems.Spark", name: "Webex", tier: .dedicated),
        Known(bundleID: "com.webex.meetingmanager", name: "Webex", tier: .dedicated),
        Known(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", tier: .ambient),
    ]

    /// A name for an identity key — a native bundle id or a `web:` service tag.
    ///
    /// Falls back to the key itself: a raw identifier is ugly but it is the
    /// truth, and it is what lets someone recognise an entry the app no longer
    /// knows about instead of hiding it behind a guess.
    static func displayName(for identityKey: String) -> String {
        if let app = native.first(where: { $0.bundleID == identityKey }) { return app.name }
        if let service = MeetingIdentity.displayName(forKey: identityKey) {
            return String(localized: "\(service) (Browser)")
        }
        return identityKey
    }
}
