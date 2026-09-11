import Foundation

/// How an audio device is attached — the one property `InputDevicePolicy` ranks by.
///
/// Free of CoreAudio on purpose: the mapping from `kAudioDeviceTransportType…`
/// lives in `AudioDevices`, so the policy can be tested as a table.
enum AudioTransport: String, Codable, Sendable {
    case builtIn
    /// USB, Thunderbolt, FireWire, PCI — a cable into this Mac.
    case wired
    case bluetooth
    /// An iPhone used as a microphone (Continuity).
    case continuity
    /// A driver, not a microphone: "Microsoft Teams Audio", loopback tools.
    case virtual
    case aggregate
    case other
}

/// One audio device as the policy sees it.
struct AudioDeviceInfo: Equatable, Sendable {
    var id: UInt32
    var uid: String
    var name: String
    var transport: AudioTransport
    /// Some process has the device's IO running right now. For Bluetooth this is
    /// the line between "already in headset mode" and "opening it would switch
    /// the AirPods out of playback quality".
    var isRunningSomewhere: Bool
}

/// Which microphone a recording should open (Spec 23).
///
/// Notable used to inherit the system default input and nothing else. With the
/// lid closed that default is still the built-in microphone — which Apple
/// silicon and T2 laptops disconnect **in hardware** while the lid is shut. It
/// stays listed, stays the default, and delivers exactly 0.0. Call apps pick
/// their own device, so from 2026-08-12 on every call had a working headset in
/// Teams and a closed lid in Notable: a month of meetings without the local
/// user's voice.
///
/// The rules, first match wins:
/// 1. the device pinned in Settings, if it is connected;
/// 2. meetings: the device the call process is recording from — never a
///    virtual or aggregate one ("Microsoft Teams Audio" is not a microphone);
/// 3. the system default — unless it is the built-in microphone with the lid
///    closed;
/// 4. another device: wired > Bluetooth already recording > Continuity already
///    recording > anything else. **Idle wireless devices are not opened for a
///    meeting**: opening an AirPods microphone the call is not using switches
///    them into headset mode and ruins the playback, and waking an iPhone is
///    just as much a reach outside Notable;
/// 5. dictation only: an idle Bluetooth or Continuity device after all — the
///    user just pressed a key to speak, and the alternative is a recording of
///    zeros;
/// 6. the built-in microphone, flagged as known silent when the lid is closed,
///    so the caller can say so at once instead of after 20 s.
enum InputDevicePolicy {
    struct Context: Equatable, Sendable {
        /// Alive, input-capable devices.
        var devices: [AudioDeviceInfo]
        var defaultInputID: UInt32?
        /// UID pinned in Settings; nil or empty means automatic.
        var pinnedUID: String?
        /// Input devices of the call process. Empty for dictation, and whenever
        /// CoreAudio does not say.
        var callDeviceIDs: [UInt32] = []
        var lidClosed: Bool
        /// Rule 5 — dictation only.
        var allowIdleWireless = false
    }

    enum Reason: String, Codable, Sendable {
        case pinned
        case followsCall
        case systemDefault
        case fallback
        /// Nothing but the built-in microphone, and the lid is closed.
        case lidClosedNoAlternative
        case noDevice
    }

    struct Choice: Equatable, Sendable {
        var device: AudioDeviceInfo?
        var reason: Reason

        /// The chosen device is certain to deliver nothing.
        var isKnownSilent: Bool { reason == .lidClosedNoAlternative }
    }

    static func choose(_ context: Context) -> Choice {
        let usable = context.devices.filter { !isDisconnected($0, lidClosed: context.lidClosed) }

        if let uid = context.pinnedUID, !uid.isEmpty,
           let pinned = usable.first(where: { $0.uid == uid }) {
            return Choice(device: pinned, reason: .pinned)
        }
        for id in context.callDeviceIDs {
            if let device = usable.first(where: { $0.id == id }), isMicrophone(device) {
                return Choice(device: device, reason: .followsCall)
            }
        }
        if let id = context.defaultInputID, let device = usable.first(where: { $0.id == id }) {
            return Choice(device: device, reason: .systemDefault)
        }
        if let device = alternatives(usable, allowIdleWireless: false).first {
            return Choice(device: device, reason: .fallback)
        }
        if context.allowIdleWireless, let device = alternatives(usable, allowIdleWireless: true).first {
            return Choice(device: device, reason: .fallback)
        }
        if let builtIn = context.devices.first(where: { $0.transport == .builtIn }) {
            return Choice(device: builtIn, reason: context.lidClosed ? .lidClosedNoAlternative : .fallback)
        }
        return Choice(device: nil, reason: .noDevice)
    }

    /// Whether a running capture should move from `current` to `choice`.
    ///
    /// Deliberately stickier than `choose`: a muted participant may release the
    /// microphone for a moment, and the call device then vanishes from the
    /// evidence. Falling back to the default right then would hop away from the
    /// headset the user is talking into. So a capture only moves on evidence —
    /// its device is gone or known silent, the pin changed, the call reports a
    /// *different* device, or the default changed while it was following the
    /// default.
    static func shouldSwitch(
        from current: (id: UInt32, reason: Reason)?,
        to choice: Choice,
        in context: Context
    ) -> Bool {
        guard let target = choice.device, target.id != current?.id else { return false }
        guard let current,
              let device = context.devices.first(where: { $0.id == current.id })
        else { return true } // unplugged, or nothing chosen yet
        if isDisconnected(device, lidClosed: context.lidClosed) { return !choice.isKnownSilent }
        switch choice.reason {
        case .pinned, .followsCall:
            return true
        case .systemDefault:
            return current.reason == .systemDefault
        case .fallback, .lidClosedNoAlternative, .noDevice:
            return false
        }
    }

    /// The built-in microphone behind a closed lid is listed but cut off.
    static func isDisconnected(_ device: AudioDeviceInfo, lidClosed: Bool) -> Bool {
        device.transport == .builtIn && lidClosed
    }

    static func isMicrophone(_ device: AudioDeviceInfo) -> Bool {
        device.transport != .virtual && device.transport != .aggregate
    }

    /// Rule 4 (and 5), best first. Ties keep the order CoreAudio listed them in.
    private static func alternatives(_ devices: [AudioDeviceInfo], allowIdleWireless: Bool) -> [AudioDeviceInfo] {
        devices.enumerated()
            .compactMap { index, device -> (rank: Int, index: Int, device: AudioDeviceInfo)? in
                let wirelessOK = device.isRunningSomewhere || allowIdleWireless
                switch device.transport {
                case .builtIn, .virtual, .aggregate: return nil
                case .wired: return (0, index, device)
                case .bluetooth: return wirelessOK ? (1, index, device) : nil
                case .continuity: return wirelessOK ? (2, index, device) : nil
                case .other: return (3, index, device)
                }
            }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.device)
    }
}
