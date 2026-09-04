import Foundation

/// A named way of rewriting a dictation, as a system prompt.
///
/// Built-ins plus free-form custom entries, stored as JSON in `UserDefaults`.
struct EnhancementProfile: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var title: String
    var systemPrompt: String
    /// False for the four built-ins, which cannot be deleted.
    var isCustom: Bool = false

    /// What actually goes to the model.
    ///
    /// The built-ins bake `commonRules` into their literal; a custom profile
    /// stores only what the user typed and gets the rules appended here. They
    /// used to be appended at *save* time instead, which put them into the
    /// TextEditor the next time the sheet opened — under a footnote calling
    /// them "automatically appended" — so every edit added another copy.
    var resolvedSystemPrompt: String {
        isCustom ? systemPrompt + EnhancementProfile.commonRules : systemPrompt
    }
}

extension EnhancementProfile {
    /// Shared rules, appended to every profile. Same stance as
    /// `SummarizationPrompt`: invent nothing, no meta sentences, output the
    /// revised text and nothing else. The guardrails below still assume the
    /// model will occasionally ignore this.
    static let commonRules = """

    Regeln, ausnahmslos:
    - Gib ausschließlich den überarbeiteten Text aus. Keine Einleitung, keine \
    Erklärung, keine Anführungszeichen um das Ganze, keine Code-Fences.
    - Erfinde nichts. Füge keine Inhalte hinzu, die nicht im Original stehen.
    - Behalte die Sprache des Originals bei.
    - Behalte Namen, Zahlen, Termine und Fachbegriffe exakt bei.
    """

    static let mail = EnhancementProfile(
        id: "mail",
        title: "E-Mail",
        systemPrompt: """
        Du überarbeitest einen diktierten Text zu einer klaren, höflichen E-Mail-Nachricht. \
        Vollständige Sätze, saubere Absätze, sachlicher Ton. Keine Anrede und keine \
        Grußformel ergänzen, wenn sie nicht diktiert wurden.
        """ + commonRules
    )

    static let notes = EnhancementProfile(
        id: "notes",
        title: "Notiz / Stichpunkte",
        systemPrompt: """
        Du überarbeitest einen diktierten Text zu knappen Stichpunkten. Ein Punkt je \
        Gedanke, jeweils mit "- " beginnend, ohne Füllwörter, ohne Wiederholungen.
        """ + commonRules
    )

    static let chat = EnhancementProfile(
        id: "chat",
        title: "Chat-Nachricht",
        systemPrompt: """
        Du überarbeitest einen diktierten Text zu einer kurzen, direkten Chat-Nachricht. \
        Locker im Ton, eine bis drei Zeilen, keine Absätze, keine Grußformeln.
        """ + commonRules
    )

    static let tighten = EnhancementProfile(
        id: "tighten",
        title: "Straffen",
        systemPrompt: """
        Du straffst einen diktierten Text. Entferne Wiederholungen, Füllwörter und \
        Umwege, ohne eine einzige Aussage zu verlieren. Der Ton bleibt, wie er ist.
        """ + commonRules
    )

    static let builtIn: [EnhancementProfile] = [.mail, .notes, .chat, .tighten]

    static let defaultsKey = "enhancementProfiles"

    /// Built-ins first, then the user's own.
    static func all(store: UserDefaults = .standard) -> [EnhancementProfile] {
        builtIn + custom(store: store)
    }

    static func custom(store: UserDefaults = .standard) -> [EnhancementProfile] {
        guard let data = store.data(forKey: defaultsKey) else { return [] }
        let stored = (try? JSONDecoder().decode([EnhancementProfile].self, from: data)) ?? []
        return stored.map(withoutCommonRules)
    }

    /// Strips every copy of `commonRules` out of a stored prompt.
    ///
    /// Self-healing rather than a migration: profiles saved by earlier builds
    /// carry one copy per time they were edited, and there is no version to key
    /// a migration off. Stripping on load is idempotent and makes the editor
    /// show what the user wrote.
    static func withoutCommonRules(_ profile: EnhancementProfile) -> EnhancementProfile {
        guard profile.systemPrompt.contains(commonRules) else { return profile }
        var clean = profile
        clean.systemPrompt = profile.systemPrompt
            .replacingOccurrences(of: commonRules, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean
    }

    static func saveCustom(_ profiles: [EnhancementProfile], store: UserDefaults = .standard) {
        let clean = profiles.filter {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let normalized = clean.map { profile -> EnhancementProfile in
            var p = withoutCommonRules(profile)
            p.isCustom = true
            return p
        }
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        store.set(data, forKey: defaultsKey)
    }

    /// The profile a target app suggests. Reuses the category the dictation path
    /// already determined — no second classification.
    static func suggested(for category: AppCategory, store: UserDefaults = .standard) -> EnhancementProfile {
        switch category {
        case .mail: return .mail
        case .chat: return .chat
        case .code, .prose, .unknown: return .tighten
        }
    }
}

/// What survives the model's answer.
///
/// A language model asked to polish text will occasionally answer *about* the
/// text instead ("Hier ist die überarbeitete Version:"), wrap it in a code fence,
/// or quietly drop half of it. None of that may reach a foreign app's text field,
/// and there is no undo for a synthesized ⌘V — so anything suspicious is rejected
/// and the rule-polished original is pasted instead. Pure and unit-tested.
enum EnhancementGuard {
    /// Ratio bounds from the spec. Below `ratioFloor` the model dropped content;
    /// above `ratioCeiling` it started writing its own.
    static let minimumRatio = 0.4
    static let maximumRatio = 2.5
    /// Below this, the ratios say nothing useful — "ja" → "Ja." is 150 % and
    /// perfectly correct — so length is only judged on real sentences.
    static let ratioThreshold = 12

    /// Openings that mean the model is talking about the text rather than
    /// returning it — but **only** in front of a colon.
    ///
    /// Every one of these is also a perfectly ordinary way to start a dictated
    /// sentence: "Hier ist der Bericht, den du wolltest", "Gerne schicke ich dir
    /// die Unterlagen", "Certainly worth a look". Rejecting on the prefix alone
    /// threw those away silently — after the text had already left the device —
    /// and pasted the unimproved original with no explanation. A model
    /// announcing its work ends that announcement with a colon
    /// ("Hier ist die überarbeitete Version:"); a person dictating does not.
    /// `gerne` and `natürlich,` are gone from the list entirely: they are the
    /// two most common first words of a dictated German mail, and no colon rule
    /// makes them worth the risk.
    static let metaPrefixes = [
        "hier ist", "hier die", "hier der", "here is", "here's",
        "überarbeitete version", "überarbeiteter text", "revised", "sure,", "certainly",
    ]

    /// True when `text` opens with a meta prefix *and* its first line carries a
    /// colon — the shape of an announcement, not of a dictation.
    ///
    /// The colon is what the announcement always has and the dictation usually
    /// does not: "Hier ist die überarbeitete Version:" and "Sure, here's the
    /// improved text:" both have one, while "Hier ist der Bericht, den du
    /// wolltest" does not — and that sentence used to be thrown away.
    static func looksLikeCommentary(_ text: String) -> Bool {
        let lowered = text.lowercased()
        guard let prefix = metaPrefixes.first(where: { lowered.hasPrefix($0) }) else { return false }
        let firstLine = text.prefix { $0 != "\n" }
        return firstLine.dropFirst(prefix.count).contains(":")
    }

    /// The text to paste, or `nil` when the answer must be discarded.
    static func accept(_ output: String, forInput input: String) -> String? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        text = strippingCodeFence(text)
        guard !text.isEmpty else { return nil }

        guard !looksLikeCommentary(text) else { return nil }
        // A fence anywhere in the body means the model formatted rather than
        // rewrote — dictated prose does not contain them.
        guard !text.contains("```") else { return nil }

        if input.count >= ratioThreshold {
            let ratio = Double(text.count) / Double(input.count)
            guard ratio >= minimumRatio, ratio <= maximumRatio else { return nil }
        }
        return text
    }

    /// A single fence wrapping the whole answer is a formatting habit, not a
    /// content problem — unwrap it and judge what is inside.
    private static func strippingCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return text }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs one enhancement round-trip.
///
/// Deliberately thin: `SummarizationProvider.complete` already does exactly this
/// (system + user in, text and spend out), so there is **no new provider**. The
/// provider is injected, and the dictation path wires it to the Claude Code CLI
/// and nothing else — see ``DictationEnhancer/dictationProvider``.
struct DictationEnhancer: Sendable {
    let provider: any SummarizationProvider
    /// Generous compared to the core path, because the user is deliberately
    /// waiting here.
    var deadline: Duration = .seconds(15)

    /// **Where the scope decision is implemented.** Dictation text may reach a
    /// subscription CLI and nothing else — never `AnthropicAPIProvider`, not
    /// even when that is the chosen *meeting* provider.
    ///
    /// The rule was always about **billing**, not about a vendor: a metered key
    /// turns every dictation into an invoice line, a flat-rate CLI does not. So
    /// the choice is open among the CLI providers (Claude, Gemini, Codex) and
    /// closed against everything else — anything unrecognised falls back to the
    /// Claude CLI rather than to whatever the meeting provider happens to be.
    /// Pinned by `DictationEnhancerTests`.
    static var dictationProvider: any SummarizationProvider {
        provider(named: UserDefaults.standard.string(forKey: EnhancementSettings.providerKey))
    }

    static func provider(named raw: String?) -> any SummarizationProvider {
        guard let raw,
              let id = SummarizationProviderID(rawValue: raw), id.isCLI,
              let provider = SummarizationService.provider(withID: id.rawValue)
        else { return ClaudeCodeCLIProvider() }
        return provider
    }

    static func forDictation() -> DictationEnhancer {
        DictationEnhancer(provider: dictationProvider, deadline: EnhancementSettings.deadline())
    }

    struct Result: Sendable {
        /// The text to paste — the model's, or the original when the answer was
        /// rejected.
        var text: String
        /// False when a guardrail or an error sent us back to the original.
        var didEnhance: Bool
        var usage: SummarizationUsage?
        /// Set when something went wrong, for the message shown afterwards.
        var failure: String?
    }

    /// Never throws: a failed enhancement must still paste the polished original.
    /// Losing a dictation because a network call failed would be the worst
    /// possible trade.
    func enhance(_ text: String, profile: EnhancementProfile) async -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(text: text, didEnhance: false) }

        do {
            let completion = try await withDeadline(deadline) {
                try await provider.complete(system: profile.resolvedSystemPrompt, user: trimmed)
            }
            guard let accepted = EnhancementGuard.accept(completion.text, forInput: trimmed) else {
                return Result(
                    text: text,
                    didEnhance: false,
                    usage: completion.usage,
                    failure: String(localized: "Verbesserung verworfen — Originaltext eingefügt.")
                )
            }
            return Result(text: accepted, didEnhance: true, usage: completion.usage)
        } catch is DeadlineExceeded {
            return Result(text: text, didEnhance: false,
                      failure: String(localized: "Verbesserung dauerte zu lange — Originaltext eingefügt."))
        } catch {
            return Result(text: text, didEnhance: false,
                          failure: String(localized: "Verbesserung fehlgeschlagen: \(error.localizedDescription)"))
        }
    }
}

struct DeadlineExceeded: Error {}

/// Runs `work`, throwing `DeadlineExceeded` when it outlasts `duration`.
func withDeadline<T: Sendable>(
    _ duration: Duration,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw DeadlineExceeded()
        }
        guard let first = try await group.next() else { throw DeadlineExceeded() }
        group.cancelAll()
        return first
    }
}

/// The user-facing switches for the enhancement feature.
///
/// **The switch is the consent.** The spec asked for a one-time confirmation
/// dialog on the first use; a dialog plus a setting says the same thing twice,
/// and the setting is the one that can be revoked later. Its explanatory text
/// carries the sentence the dialog would have carried — where the text goes, to
/// whom, and on what plan.
enum EnhancementSettings {
    static let enabledKey = "dictationEnhancementEnabled"
    /// Which subscription CLI the dictation path uses. Only CLI providers are
    /// accepted; anything else falls back to Claude.
    static let providerKey = "dictationEnhanceProvider"
    static let hotkeyKey = "dictationEnhanceHotkey"
    static let profileKey = "dictationEnhanceProfile"
    static let deadlineKey = "dictationEnhanceDeadline"

    /// Off until switched on. Nothing about this feature exists until then —
    /// the second hotkey is not even installed.
    static func isEnabled(_ store: UserDefaults = .standard) -> Bool {
        store.bool(forKey: enabledKey)
    }

    static var isEnabled: Bool { isEnabled(.standard) }

    /// The second hotkey, or `nil` when the feature is off or no key is chosen.
    /// Returning `nil` here is what makes "off" mean off at the tap level rather
    /// than at the call site.
    static func hotkey(_ store: UserDefaults = .standard) -> HotkeySpec? {
        guard isEnabled(store) else { return nil }
        guard let raw = store.string(forKey: hotkeyKey), !raw.isEmpty else { return nil }
        return HotkeySpec(rawValue: raw)
    }

    /// Empty means "choose from the target app" — the same `AppCategory` the
    /// polishing profile already used.
    static func profile(for category: AppCategory, store: UserDefaults = .standard) -> EnhancementProfile {
        if let id = store.string(forKey: profileKey), !id.isEmpty,
           let match = EnhancementProfile.all(store: store).first(where: { $0.id == id }) {
            return match
        }
        return EnhancementProfile.suggested(for: category, store: store)
    }

    static func deadline(_ store: UserDefaults = .standard) -> Duration {
        let seconds = store.object(forKey: deadlineKey) as? Double ?? 15
        return .seconds(max(3, min(60, seconds)))
    }
}
