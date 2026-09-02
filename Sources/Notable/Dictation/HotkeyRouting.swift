import Foundation

/// Which of the two dictation hotkeys is in play.
enum HotkeyRole: String, Sendable, Equatable {
    /// The normal hotkey: offline, fast, nothing leaves the device.
    case plain
    /// The second, optional hotkey: same recording, plus one LLM round-trip on
    /// release. Empty (off) by default.
    case enhanced
}

/// Turns a modifier-key event into a press/release for one of the two hotkeys.
///
/// Extracted from `HotkeyMonitor` because that lives inside a CGEventTap callback
/// on the main run loop and cannot be tested — while this is exactly the part
/// that can go wrong: two keys, one recording, and a release that must be matched
/// to the key that actually started it.
enum HotkeyRouting {
    enum Event: Equatable {
        case down(HotkeyRole)
        case up(HotkeyRole)
        case ignore
    }

    static func event(
        keyCode: Int64,
        isPressed: Bool,
        held: HotkeyRole?,
        plain: HotkeySpec,
        enhance: HotkeySpec?
    ) -> Event {
        // The same key cannot mean two things. If both settings point at one
        // key, the plain role wins — a silent enhancement is the wrong surprise.
        let enhance = enhance == plain ? nil : enhance

        let role: HotkeyRole
        if keyCode == plain.keyCode {
            role = .plain
        } else if let enhance, keyCode == enhance.keyCode {
            role = .enhanced
        } else {
            return .ignore
        }

        if isPressed {
            // A second hotkey pressed during a recording is ignored, not
            // stacked: releasing it would otherwise end a recording it never
            // started, and the two would disagree about whether to enhance.
            return held == nil ? .down(role) : .ignore
        }
        return held == role ? .up(role) : .ignore
    }
}
