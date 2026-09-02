import Foundation

/// Coarse category of the app that dictated text is being pasted into.
///
/// Drives context-dependent polishing (Spec 03): a terse Slack line, a formal
/// mail, verbatim code, or standard prose. Pure and offline — the category is
/// derived solely from the frontmost app's bundle identifier; dictated text
/// never leaves the device.
enum AppCategory: String, Sendable, CaseIterable {
    case chat
    case mail
    case code
    case prose
    case unknown

    /// Human-readable German label (for Settings, previews).
    var label: String {
        switch self {
        case .chat: return "Chat"
        case .mail: return "E-Mail"
        case .code: return "Code"
        case .prose: return "Text/Prosa"
        case .unknown: return "Unbekannt"
        }
    }

    /// Built-in bundle-id → category table (Spec 03 §3).
    ///
    /// Keys are lower-cased bundle identifiers; lookup lower-cases the query so
    /// matching is case-insensitive. Exposed so it can be inspected/tested and
    /// later surfaced (and extended) in Settings.
    static let defaultMapping: [String: AppCategory] = [
        // chat — terse, casual, lowercase ok
        "com.tinyspeck.slackmacgap": .chat,
        "com.apple.mobilesms": .chat,
        "net.whatsapp.whatsapp": .chat,
        "com.hnc.discord": .chat,
        "org.telegram.desktop": .chat,

        // mail — full sentences, clean casing, final punctuation
        "com.apple.mail": .mail,
        "com.microsoft.outlook": .mail,
        "com.readdle.smartemail-mac": .mail,

        // code — verbatim, no beautification
        "com.apple.dt.xcode": .code,
        "com.microsoft.vscode": .code,
        "com.googlecode.iterm2": .code,
        "com.apple.terminal": .code,
        "com.jetbrains.intellij": .code,
        "com.jetbrains.pycharm": .code,
        "com.jetbrains.webstorm": .code,

        // prose — standard polishing (today's behaviour)
        "com.apple.notes": .prose,
        "com.microsoft.word": .prose,
        "com.apple.iwork.pages": .prose,
        "md.obsidian": .prose,
        "net.shinyfrog.bear": .prose,
    ]

    /// Resolves a bundle identifier to a category.
    ///
    /// - Parameters:
    ///   - bundleID: The frontmost app's bundle id, or `nil` (no frontmost / Notable itself).
    ///   - overrides: User-defined bundle-id → category entries; consulted first
    ///     so they win over the built-in table and can cover apps it doesn't list.
    /// - Returns: The mapped category, or `.unknown` for `nil` and unlisted ids.
    static func of(bundleID: String?, overrides: [String: AppCategory] = [:]) -> AppCategory {
        guard let bundleID else { return .unknown }
        let key = bundleID.lowercased()
        if let override = overrides[bundleID] ?? overrides[key] {
            return override
        }
        return defaultMapping[key] ?? .unknown
    }
}
