import CoreGraphics
import Foundation

/// Selectable push-to-talk keys. All are modifier keys — they arrive as
/// flagsChanged events and never collide with typing.
enum HotkeySpec: String, CaseIterable, Identifiable, Sendable {
    case rightOption
    case leftOption
    case rightCommand
    case rightControl
    case fnGlobe

    static let storageKey = "dictationHotkey"

    static var current: HotkeySpec {
        UserDefaults.standard.string(forKey: storageKey).flatMap(HotkeySpec.init(rawValue:)) ?? .rightOption
    }

    var id: String { rawValue }

    var label: String {
        let key: String.LocalizationValue = switch self {
        case .rightOption: "Rechte Wahltaste (⌥)"
        case .leftOption: "Linke Wahltaste (⌥)"
        case .rightCommand: "Rechte Befehlstaste (⌘)"
        case .rightControl: "Rechte Ctrl-Taste (⌃)"
        case .fnGlobe: "Fn/Globus-Taste (🌐)"
        }
        return String(localized: key)
    }

    var keyCode: Int64 {
        switch self {
        case .rightOption: 61
        case .leftOption: 58
        case .rightCommand: 54
        case .rightControl: 62
        case .fnGlobe: 63
        }
    }

    var flags: CGEventFlags {
        switch self {
        case .rightOption, .leftOption: .maskAlternate
        case .rightCommand: .maskCommand
        case .rightControl: .maskControl
        case .fnGlobe: .maskSecondaryFn
        }
    }

    /// Device-specific NX_DEVICE…KEYMASK bit — distinguishes left/right so
    /// holding the twin modifier cannot mask the hotkey's release.
    var deviceMask: UInt64? {
        switch self {
        case .rightOption: 0x40   // NX_DEVICERALTKEYMASK
        case .leftOption: 0x20    // NX_DEVICELALTKEYMASK
        case .rightCommand: 0x10  // NX_DEVICERCMDKEYMASK
        case .rightControl: 0x2000 // NX_DEVICERCTLKEYMASK
        case .fnGlobe: nil        // no side variants
        }
    }

    func isPressed(in flags: CGEventFlags) -> Bool {
        guard flags.contains(self.flags) else { return false }
        guard let deviceMask else { return true }
        return flags.rawValue & deviceMask != 0
    }
}
