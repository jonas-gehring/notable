import Foundation

struct MeetingContext: Sendable {
    var title: String?
    var date: Date
    var durationSeconds: Double?
    /// The user's own notes — ground truth the summarizer weaves into the
    /// Zusammenfassung and prefers over the transcript on conflict.
    var userNotes: String? = nil
}

/// Token spend of one provider round-trip, and what it cost.
///
/// **`billed` is the whole point of this type.** The Anthropic API charges per
/// token, so its cost is money that actually left the account. The Claude Max
/// plan via the CLI charges nothing per call — but the CLI still reports what
/// the same call *would* have cost on the API. That number is worth showing
/// (it is the only handle on how expensive a summary is), yet presenting it as
/// spend would be a lie the statistics would repeat for years. Every display
/// site has to branch on this flag.
struct SummarizationUsage: Sendable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0
    /// USD for this single call. Real money only when `billed` is true.
    var costUSD: Double = 0
    /// True for the metered API, false for a flat-rate subscription via a CLI.
    var billed: Bool = false

    /// Everything the model read plus everything it wrote.
    var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
}

/// One raw completion: the model's text, plus what the round-trip spent.
///
/// `summarize` returns spend inside its `Summary`; `complete` had no place to
/// put it and simply dropped it, so chat and speaker naming were invisible in
/// the usage statistics while costing real tokens. Same `nil`-means-unknown
/// rule as ``Summary/usage``.
struct Completion: Sendable {
    var text: String
    var usage: SummarizationUsage?
}

struct Summary: Sendable {
    /// Clean Markdown body — the TITLE/TLDR header lines are already stripped.
    var markdown: String
    var providerID: String
    /// Model-proposed meeting title (nil when the model omitted the header).
    var title: String?
    /// One-sentence gist for list views (nil when omitted).
    var subtitle: String?
    /// What the call spent. nil when the provider reported nothing usable —
    /// statistics then simply skip this recording rather than count a zero.
    var usage: SummarizationUsage?

    init(
        markdown: String,
        providerID: String,
        title: String? = nil,
        subtitle: String? = nil,
        usage: SummarizationUsage? = nil
    ) {
        self.markdown = markdown
        self.providerID = providerID
        self.title = title
        self.subtitle = subtitle
        self.usage = usage
    }

    /// Builds a `Summary` from a provider's raw model output by splitting off
    /// the `TITLE:`/`TLDR:` header lines with `SummaryParser`. Both providers
    /// use this so the parsing rule lives in exactly one place.
    init(rawModelOutput raw: String, providerID: String, usage: SummarizationUsage? = nil) {
        let parsed = SummaryParser.parse(raw)
        self.init(
            markdown: parsed.markdown,
            providerID: providerID,
            title: parsed.title,
            subtitle: parsed.subtitle,
            usage: usage
        )
    }
}

enum ProviderAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

enum SummarizationError: Error, LocalizedError {
    case notConfigured(String)
    case requestFailed(String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message): message
        case .requestFailed(let message): message
        case .unexpectedResponse(let message): "Unerwartete Antwort: \(message)"
        }
    }
}

/// The providers the user can pick between.
///
/// Lives here, not in the settings view: since the dictation path had to be able
/// to say "subscription CLIs only", this is a domain rule, not a piece of UI.
enum SummarizationProviderID: String, CaseIterable, Identifiable {
    case anthropicAPI = "anthropic-api"
    case claudeCodeCLI = "claude-code-cli"
    case geminiCLI = "gemini-cli"
    case codexCLI = "codex-cli"

    var id: String { rawValue }

    var label: String {
        let key: String.LocalizationValue = switch self {
        case .anthropicAPI: "Anthropic API (empfohlen)"
        case .claudeCodeCLI: "Anthropic Claude Code CLI (Abo)"
        case .geminiCLI: "Google Gemini CLI (Abo)"
        case .codexCLI: "OpenAI Codex CLI (Abo)"
        }
        return String(localized: key)
    }

    /// The subscription CLIs. These are the only providers the **dictation**
    /// path may use: it must never reach a metered API key, and that rule is
    /// about billing, not about a particular vendor.
    static let cliProviders: [SummarizationProviderID] = [.claudeCodeCLI, .geminiCLI, .codexCLI]

    var isCLI: Bool { Self.cliProviders.contains(self) }
}


/// One protocol, two mandatory v1 implementations (Anthropic API and
/// Claude Max via Claude Code CLI). The user picks in Settings; there is
/// no silent fallback between providers.
protocol SummarizationProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func availability() async -> ProviderAvailability
    func summarize(transcript: String, context: MeetingContext) async throws -> Summary
    /// Raw structured text completion: one system+user round-trip returning the
    /// model's text verbatim. Used by `SpeakerNameResolver` for the strict-JSON
    /// label→name mapping call. Same privacy stance as `summarize` — only text
    /// leaves the device.
    func complete(system: String, user: String) async throws -> Completion
}

/// Provider-independent prompt. Only transcript text ever leaves the device.
enum SummarizationPrompt {
    static let system = """
    Du erstellst hochgradig überfliegbare Meeting-Notizen aus einem Transkript — \
    knapp, redigiert, wie ein sorgfältiger menschlicher Protokollant, kein Wort-für-Wort-Abschrift. \
    Antworte ausschließlich auf Deutsch und ausschließlich im unten vorgegebenen Format.

    Beginne mit genau diesen zwei Kopfzeilen, gefolgt von einer Leerzeile:
    TITLE: <kurze Substantivphrase, die das Meeting benennt, höchstens 6 Wörter>
    TLDR: <ein einziger Satz, höchstens 15 Wörter, der das Wichtigste zusammenfasst>

    Danach ausschließlich Markdown mit genau diesen Abschnitten in exakt dieser \
    Reihenfolge. Zeige jeden Abschnitt immer an; schreibe "Keine.", wenn er leer bleibt:

    ## Zusammenfassung
    (Überfliegbare Stichpunkte, nach Thema gruppiert. Decke den GESAMTEN Verlauf ab — \
    Anfang, Mitte UND Ende, nicht nur den Einstieg. Kurze Fragmente statt Fließtext, \
    zentrale Begriffe **fett**.)

    ## Entscheidungen
    (Ein Stichpunkt je Entscheidung; **fett** die eigentliche Entscheidung.)

    ## Action Items
    (Ein Stichpunkt je Aufgabe im Format "@<Verantwortliche:r> — <Aufgabe> — <Frist, falls genannt>". \
    Verantwortliche nur nennen, wenn aus dem Transkript ableitbar; die Sprecher heißen "Ich" und "Sprecher n".)

    ## Themen
    (Kompakte Liste der behandelten Themen, je Thema ein Stichpunkt.)

    Regeln: Erfinde nichts, was nicht im Transkript steht. Keine Zeitstempel. \
    Kein Vorwort, kein Nachwort, kein Text außerhalb der beiden Kopfzeilen und der Abschnitte. \
    Falls eigene Notizen des Nutzers mitgeliefert werden, sind sie die verlässlichste Quelle: \
    webe sie in die Zusammenfassung ein und bevorzuge sie bei Widersprüchen zum Transkript.
    """

    static func user(transcript: String, context: MeetingContext) -> String {
        var header = "Meeting"
        if let title = context.title, !title.isEmpty {
            header += ": \(title)"
        }
        header += " am \(context.date.formatted(date: .long, time: .shortened))"
        if let duration = context.durationSeconds {
            header += String(format: " (%.0f Minuten)", duration / 60)
        }
        var body = header + "\n\nTranskript:\n\n" + transcript
        // The user's own notes: a clearly labelled, higher-trust block the model
        // weaves INTO the Zusammenfassung (system prompt), not merely echoes.
        if let notes = context.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines),
           !notes.isEmpty {
            body += "\n\nEigene Notizen des Nutzers (Grundwahrheit — in die "
                + "Zusammenfassung einarbeiten, bei Widersprüchen bevorzugen):\n\n"
                + notes
        }
        return body
    }
}
