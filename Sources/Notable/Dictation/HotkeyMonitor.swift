import CoreGraphics
import Foundation

/// Global push-to-talk hotkey. Two separate CGEventTaps, deliberately:
///
/// - The **flags tap** (modifier keys) is listen-only and always on — it
///   never sits in the synchronous key-delivery path.
/// - The **Esc tap** must swallow the key, so it is an active tap — and
///   therefore exists only while a recording runs. Outside recordings,
///   Notable is not in anyone's keystroke path.
///
/// Requires the Input Monitoring permission; `start()` returns false when
/// the tap cannot be created (typically: permission missing).
@MainActor
final class HotkeyMonitor {
    /// The role says which of the two hotkeys fired — the second one adds an LLM
    /// pass on release and is off unless the user configured it.
    var onKeyDown: ((HotkeyRole) -> Void)?
    var onKeyUp: ((HotkeyRole) -> Void)?
    /// Esc pressed while a recording is active — cancel it.
    var onEscape: (() -> Void)?
    /// Supplied by the controller: is a recording (held or locked) running?
    var isRecordingActive: () -> Bool = { false }

    /// Which modifier key acts as push-to-talk; set before start().
    var spec: HotkeySpec = .rightOption
    /// Optional second push-to-talk key that also runs the enhancement on
    /// release. `nil` (the default) means the feature has no key and can never
    /// fire by accident.
    var enhanceSpec: HotkeySpec?

    private var flagsTap: CFMachPort?
    private var flagsSource: CFRunLoopSource?
    private var escTap: CFMachPort?
    private var escSource: CFRunLoopSource?
    /// Which role is currently held, if any. Replaces the old `isPressed` flag —
    /// with two keys, "something is down" is no longer enough to match a release.
    private var heldRole: HotkeyRole?

    // MARK: - Flags tap (always on, listen-only)

    @discardableResult
    func start() -> Bool {
        guard flagsTap == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    // The tap's run-loop source is scheduled on the main run loop.
                    MainActor.assumeIsolated {
                        monitor.handleFlags(type: type, event: event)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        flagsTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        flagsSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        endEscInterception()
        if let flagsSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), flagsSource, .commonModes)
            CFRunLoopSourceInvalidate(flagsSource)
        }
        if let flagsTap {
            CGEvent.tapEnable(tap: flagsTap, enable: false)
            CFMachPortInvalidate(flagsTap)
        }
        flagsSource = nil
        flagsTap = nil
        heldRole = nil
    }

    private func handleFlags(type: CGEventType, event: CGEvent) {
        // macOS disables taps that stall; re-enable instead of dying silently.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let flagsTap { CGEvent.tapEnable(tap: flagsTap, enable: true) }
            return
        }

        guard type == .flagsChanged else { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let matched: HotkeySpec?
        if keyCode == spec.keyCode {
            matched = spec
        } else if let enhanceSpec, enhanceSpec != spec, keyCode == enhanceSpec.keyCode {
            matched = enhanceSpec
        } else {
            matched = nil
        }
        guard let matched else { return }

        // The decision itself is pure and tested (`HotkeyRoutingTests`); this
        // callback stays a lookup plus a dispatch.
        switch HotkeyRouting.event(
            keyCode: keyCode,
            isPressed: matched.isPressed(in: event.flags),
            held: heldRole,
            plain: spec,
            enhance: enhanceSpec
        ) {
        case .down(let role):
            heldRole = role
            onKeyDown?(role)
        case .up(let role):
            heldRole = nil
            onKeyUp?(role)
        case .ignore:
            break
        }
    }

    // MARK: - Esc tap (active, only while recording)

    /// Called by the controller when a recording begins.
    ///
    /// Returns whether the tap is up. An *active* tap needs Accessibility, and
    /// without it `tapCreate` returns nil — the overlay used to promise "Esc
    /// verwirft" all the same, and Esc then did nothing at all. The caller says
    /// so instead.
    @discardableResult
    func beginEscInterception() -> Bool {
        guard escTap == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                let swallow = MainActor.assumeIsolated {
                    monitor.handleEsc(type: type, event: event)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }

        escTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        escSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Called by the controller when the recording ends (any way).
    ///
    /// `CFMachPortInvalidate` matters: disabling a tap stops it delivering, but
    /// the Mach port and its run-loop source stay alive. One per dictation adds
    /// up over a day of use.
    func endEscInterception() {
        if let escSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), escSource, .commonModes)
            CFRunLoopSourceInvalidate(escSource)
        }
        if let escTap {
            CGEvent.tapEnable(tap: escTap, enable: false)
            CFMachPortInvalidate(escTap)
        }
        escSource = nil
        escTap = nil
    }

    /// Returns true when the event should be swallowed.
    private func handleEsc(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let escTap { CGEvent.tapEnable(tap: escTap, enable: true) }
            return false
        }
        guard type == .keyDown, isRecordingActive(),
              event.getIntegerValueField(.keyboardEventKeycode) == 53
        else { return false }
        onEscape?()
        return true
    }
}
