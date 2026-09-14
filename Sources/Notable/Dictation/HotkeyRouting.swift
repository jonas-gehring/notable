import Foundation

/// Which of the two dictation hotkeys is in play.
enum HotkeyRole: String, Sendable, Equatable {
    /// The normal hotkey: offline, fast, nothing leaves the device.
    case plain
    /// The second, optional hotkey: same recording, plus one LLM round-trip on
    /// release. Empty (off) by default.
    case enhanced
    /// The third, optional hotkey (Spec 32 Stufe 2, Spec 04 on the device): the
    /// recording is a spoken command applied to the selected text by the local
    /// model. Off unless the user allowed reading the target app.
    case command
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
        enhance: HotkeySpec?,
        command: HotkeySpec? = nil
    ) -> Event {
        // The same key cannot mean two things. If two settings point at one key,
        // plain wins over enhance, and both win over command — a silent
        // enhancement or a command that rewrites a selection is the wrong surprise.
        let enhance = enhance == plain ? nil : enhance
        let command = command == nil || command == plain || command == enhance ? nil : command

        let role: HotkeyRole
        if keyCode == plain.keyCode {
            role = .plain
        } else if let enhance, keyCode == enhance.keyCode {
            role = .enhanced
        } else if let command, keyCode == command.keyCode {
            role = .command
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
