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
        let key: String.LocalizationValue = switch self {
        case .chat: "Chat"
        case .mail: "E-Mail"
        case .code: "Code"
        case .prose: "Text/Prosa"
        case .unknown: "Unbekannt"
        }
        return String(localized: key)
    }

    /// Built-in bundle-id → category table (Spec 03 §3, extended in Spec 31 §3.4).
    ///
    /// Keys are lower-cased bundle identifiers; lookup lower-cases the query so
    /// matching is case-insensitive. Up to Spec 31 it had twenty entries and not a
    /// single browser — measured on this installation, the four apps dictated
    /// into most (Ship Studio, Safari, the Claude app, Ghostty) were all missing,
    /// so nearly every dictation was `.unknown`. Not every identifier below is
    /// verified against an installed app; a wrong one simply never matches, and
    /// the override table in Settings is the answer for anything this misses.
    static let defaultMapping: [String: AppCategory] = [
        // chat — terse, casual, lowercase ok
        "com.tinyspeck.slackmacgap": .chat,
        "com.apple.mobilesms": .chat,
        "net.whatsapp.whatsapp": .chat,
        "com.hnc.discord": .chat,
        "org.telegram.desktop": .chat,
        "com.microsoft.teams": .chat,
        "com.microsoft.teams2": .chat,
        "us.zoom.xos": .chat,
        "org.whispersystems.signal-desktop": .chat,
        "com.facebook.archon.developerid": .chat,
        "mattermost.desktop": .chat,
        "im.riot.app": .chat,

        // mail — full sentences, clean casing, final punctuation
        "com.apple.mail": .mail,
        "com.microsoft.outlook": .mail,
        "com.readdle.smartemail-mac": .mail,
        "com.readdle.sparkdesktop": .mail,
        "com.mimestream.mimestream": .mail,
        "org.mozilla.thunderbird": .mail,
        "it.bloop.airmail2": .mail,

        // code — verbatim, no beautification
        "com.apple.dt.xcode": .code,
        "com.microsoft.vscode": .code,
        "com.googlecode.iterm2": .code,
        "com.apple.terminal": .code,
        "com.jetbrains.intellij": .code,
        "com.jetbrains.pycharm": .code,
        "com.jetbrains.webstorm": .code,
        "com.jetbrains.goland": .code,
        "com.jetbrains.rider": .code,
        "com.jetbrains.clion": .code,
        "com.jetbrains.rustrover": .code,
        "com.jetbrains.fleet": .code,
        "com.google.android.studio": .code,
        "com.todesktop.230313mzl4w4u92": .code, // Cursor
        "com.exafunction.windsurf": .code,
        "dev.zed.zed": .code,
        "com.sublimetext.4": .code,
        "com.panic.nova": .code,
        "com.barebones.bbedit": .code,
        "com.mitchellh.ghostty": .code,
        "dev.warp.warp-stable": .code,
        "net.kovidgoyal.kitty": .code,
        "org.alacritty": .code,

        // prose — standard polishing. A browser is one category (Spec 03 §9):
        // what runs in the tab is not knowable.
        "com.apple.notes": .prose,
        "com.microsoft.word": .prose,
        "com.apple.iwork.pages": .prose,
        "md.obsidian": .prose,
        "net.shinyfrog.bear": .prose,
        "com.apple.safari": .prose,
        "com.google.chrome": .prose,
        "company.thebrowser.browser": .prose, // Arc
        "org.mozilla.firefox": .prose,
        "com.microsoft.edgemac": .prose,
        "com.brave.browser": .prose,
        "notion.id": .prose,
        "com.lukilabs.lukiapp": .prose, // Craft
        "com.ulyssesapp.mac": .prose,
        "pro.writer.mac": .prose, // iA Writer
        "com.agiletortoise.drafts-osx": .prose,
        "com.apple.textedit": .prose,
        "com.anthropic.claudefordesktop": .prose,
        "com.openai.chat": .prose,
        "com.memberstack.shipstudio": .prose,
    ]

    /// What a category does to the text — shown next to the picker, so choosing
    /// one is not a guess (Spec 03 §5).
    var hint: String {
        switch self {
        case .chat: String(localized: "locker, ohne Absätze")
        case .mail: String(localized: "ganze Sätze, Schlusspunkt")
        case .code: String(localized: "wörtlich, nichts geglättet")
        case .prose, .unknown: String(localized: "Standard")
        }
    }

    /// The categories a user can assign. `.unknown` is what an unlisted app
    /// *is*, not something to choose.
    static let assignable: [AppCategory] = [.prose, .chat, .mail, .code]

    // MARK: - User overrides (Spec 03 §5, built in Spec 31 §3.4)

    /// Kept here rather than in `DefaultsKey`, next to the table it overrides —
    /// the same arrangement as `HotkeySpec.storageKey`.
    static let overridesKey = "appCategoryOverrides"

    /// The user's own assignments, keys lower-cased. An unreadable entry is
    /// dropped, never guessed.
    static func loadOverrides(_ store: UserDefaults = .standard) -> [String: AppCategory] {
        guard let raw = store.dictionary(forKey: overridesKey) as? [String: String] else { return [:] }
        return raw.reduce(into: [:]) { result, pair in
            if let category = AppCategory(rawValue: pair.value), category != .unknown {
                result[pair.key.lowercased()] = category
            }
        }
    }

    static func saveOverrides(_ overrides: [String: AppCategory], store: UserDefaults = .standard) {
        let raw = overrides.reduce(into: [String: String]()) { result, pair in
            guard pair.value != .unknown else { return }
            result[pair.key.lowercased()] = pair.value.rawValue
        }
        store.set(raw, forKey: overridesKey)
    }

    /// Sets `category` for `bundleID`, and removes the override again when it
    /// merely restates the built-in table — so the table can still change in a
    /// later version for apps the user never actually reassigned.
    static func assigning(
        _ category: AppCategory, to bundleID: String, in overrides: [String: AppCategory]
    ) -> [String: AppCategory] {
        var result = overrides
        let key = bundleID.lowercased()
        if defaultMapping[key] == category {
            result.removeValue(forKey: key)
        } else {
            result[key] = category
        }
        return result
    }

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
