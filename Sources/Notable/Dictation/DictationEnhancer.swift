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
        return (try? JSONDecoder().decode([EnhancementProfile].self, from: data)) ?? []
    }

    static func saveCustom(_ profiles: [EnhancementProfile], store: UserDefaults = .standard) {
        let clean = profiles.filter {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let data = try? JSONEncoder().encode(clean.map { var p = $0; p.isCustom = true; return p }) else { return }
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
    /// returning it.
    static let metaPrefixes = [
        "hier ist", "hier die", "hier der", "here is", "here's",
        "überarbeitete version", "überarbeiteter text", "revised", "sure,", "certainly",
        "gerne", "natürlich,",
    ]

    /// The text to paste, or `nil` when the answer must be discarded.
    static func accept(_ output: String, forInput input: String) -> String? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        text = strippingCodeFence(text)
        guard !text.isEmpty else { return nil }

        let lowered = text.lowercased()
        guard !metaPrefixes.contains(where: { lowered.hasPrefix($0) }) else { return nil }
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
                try await provider.complete(system: profile.systemPrompt, user: trimmed)
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
            return Result(text: text, didEnhance: false, failure: "Verbesserung fehlgeschlagen: \(error.localizedDescription)")
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
