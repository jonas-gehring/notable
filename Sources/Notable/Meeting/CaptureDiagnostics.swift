import Foundation

/// What the microphone side of a meeting was actually recording from — written
/// into the spool's `meta.json` at the start and at every device change
/// (Spec 23).
///
/// It exists because a month of silent microphone tracks could only be
/// reconstructed afterwards by measuring every archived recording: nowhere did
/// it say which device was recorded, which one the call used, or that the lid
/// was shut. The values are strings rather than enums on purpose — `Meta` is
/// what crash recovery decodes, and a diagnostic field that no longer decodes
/// after an update must never cost the meeting it describes.
struct CaptureDiagnostics: Codable, Sendable, Equatable {
    struct Device: Codable, Sendable, Equatable {
        var name: String
        var uid: String
        /// `AudioTransport.rawValue`.
        var transport: String

        var isBuiltIn: Bool { transport == AudioTransport.builtIn.rawValue }
        var isMicrophone: Bool {
            transport != AudioTransport.virtual.rawValue && transport != AudioTransport.aggregate.rawValue
        }
    }

    var at: Date
    /// "start", "switch", "configurationChange", "selfHeal".
    var event: String
    var recorded: Device?
    /// `InputDevicePolicy.Reason.rawValue`.
    var reason: String?
    var defaultInput: Device?
    var defaultOutput: Device?
    var lidClosed: Bool
    var callApp: String?
    var callInputDevices: [Device]
    var echoCancellation: Bool
}

extension CaptureDiagnostics.Device {
    init(_ device: AudioDeviceInfo) {
        self.init(name: device.name, uid: device.uid, transport: device.transport.rawValue)
    }
}

/// Why a microphone track is silent — the second half of the warning.
///
/// Both warnings used to blame the permission, unconditionally. For a month of
/// silent calls the permission was granted; the lid was closed. A message
/// nobody can act on is barely better than none, so the permission is named
/// **only** when it is actually missing, and otherwise the cause is stated with
/// the real device names — or, when nothing is known, just the device, without
/// a guess.
enum SilenceDiagnosis {
    static func cause(of diagnostics: CaptureDiagnostics?, micAuthorized: Bool) -> String? {
        guard micAuthorized else {
            return String(localized: "Mikrofon-Berechtigung für Notable prüfen (Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon).")
        }
        guard let diagnostics, let recorded = diagnostics.recorded else { return nil }

        // The call's own device — only with an app to name, and never a driver.
        let callDevice = diagnostics.callApp == nil
            ? nil
            : diagnostics.callInputDevices.first { $0.isMicrophone && $0.uid != recorded.uid }

        if recorded.isBuiltIn, diagnostics.lidClosed {
            let lid = String(localized: "Deckel geschlossen — das eingebaute Mikrofon ist dann abgeschaltet.")
            guard let callDevice, let app = diagnostics.callApp else { return lid }
            return lid + " " + String(localized: "\(app) benutzt „\(callDevice.name)“.")
        }
        if let callDevice, let app = diagnostics.callApp {
            return String(localized: "Notable hört „\(recorded.name)“, \(app) benutzt „\(callDevice.name)“.")
        }
        return String(localized: "Aufgenommen wurde „\(recorded.name)“.")
    }
}
