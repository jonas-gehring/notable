import AVFoundation
import Carbon.HIToolbox
import Foundation
import os

/// The microphone side of a dictation: which device opens, whether it may, and
/// what a route change under a running recording does (Spec 23, Spec 29).
/// Taken out of `DictationController` in Spec 29 §9.
@MainActor
final class DictationInput {
    private static let log = Logger(subsystem: "de.jonasgehring.notable", category: "dictation")

    let recorder = AudioRecorder()
    /// Name of the device the running recording uses, for "nothing heard on …".
    private(set) var deviceName: String?
    private var cachedContext: (context: InputDevicePolicy.Context, at: Date)?
    /// `resume` itself reconfigures the engine and posts another change.
    private var ignoreChangesUntil = Date.distantPast

    enum Opening {
        case opened
        /// First use: the system prompt is up, this press does not record.
        case askedForPermission
        case refused(DictationFailure)
    }

    /// Decides whether this key-down may record, and opens the device if so.
    ///
    /// Permission, secure input and a closed lid are checked *here*, on the press:
    /// a denied device still opens and records zeros, so after the release the
    /// cause could no longer be named (Spec 29 §3.3).
    func open() -> Opening {
        let choice = InputDevicePolicy.choose(context())
        switch DictationPipeline.start(
            permission: Self.microphonePermission(),
            secureInput: IsSecureEventInputEnabled(),
            knownSilent: choice.isKnownSilent
        ) {
        case .start:
            break
        case .requestPermission:
            Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
            return .askedForPermission
        case .refuse(let failure):
            return .refused(failure)
        }
        do {
            try recorder.start(device: choice.device?.id)
        } catch {
            Self.log.error("Mikrofon: \(error.localizedDescription, privacy: .public)")
            return .refused(.microphoneUnavailable)
        }
        deviceName = choice.device?.name
        ignoreChangesUntil = .distantPast
        return .opened
    }

    enum RouteChange {
        case ignored
        case unchanged
        case switched(to: String)
        /// The device went away and could not be resumed.
        case lost
    }

    /// A route change: device unplugged, AirPods connected.
    ///
    /// It used to cancel the recording and discard the audio. `resume` keeps the
    /// buffer, reinstalls the tap on the device the policy picks *now* and pads
    /// the gap with silence — what meetings have done all along.
    func handleRouteChange(isCapturing: Bool) -> RouteChange {
        cachedContext = nil
        guard isCapturing, Date() >= ignoreChangesUntil else { return .ignored }
        let choice = InputDevicePolicy.choose(context(fresh: true))
        ignoreChangesUntil = Date().addingTimeInterval(1.5)
        do {
            try recorder.resume(device: choice.device?.id)
        } catch {
            Self.log.error("Gerätewechsel: \(error.localizedDescription, privacy: .public)")
            return .lost
        }
        guard let name = choice.device?.name, name != deviceName else { return .unchanged }
        deviceName = name
        return .switched(to: name)
    }

    /// The input context, cached for two seconds: enumerating devices and reading
    /// the lid through IORegistry used to happen on every key-down.
    private func context(fresh: Bool = false) -> InputDevicePolicy.Context {
        if !fresh, let cached = cachedContext, Date().timeIntervalSince(cached.at) < 2 {
            return cached.context
        }
        // No call rule for dictation, and an idle headset is allowed as the
        // last resort (Spec 23).
        let context = InputDevicePolicy.Context(
            devices: AudioDevices.inputDevices(),
            defaultInputID: AudioDevices.defaultInputID,
            pinnedUID: DefaultsKey.inputDeviceUID.value(),
            lidClosed: AudioDevices.isLidClosed(),
            allowIdleWireless: true
        )
        cachedContext = (context, Date())
        return context
    }

    private static func microphonePermission() -> DictationPipeline.MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}
