import Darwin
import Foundation

/// Option 2: the locally installed, logged-in Claude
/// Code CLI, headless (`claude -p --output-format json`). Zero marginal
/// cost, but no API contract — the parser is deliberately defensive and
/// failures name the CLI as the culprit. Usage counts against the shared
/// Max limits.
struct ClaudeCodeCLIProvider: SummarizationProvider {
    let id = "claude-code-cli"
    let displayName = "Anthropic Claude Code CLI (Abo)"

    /// The transcript is untrusted input: it contains whatever anyone said in
    /// the meeting, and whatever the ASR made of it. Summarizing is pure text
    /// work, so the agent gets no tools at all — a prompt injection hidden in a
    /// transcript then has nothing to reach for. (The scratch cwd already keeps
    /// it away from any project; this closes the door entirely.)
    ///
    /// `--tools ""` instead of `--disallowed-tools <list>`: the exclusion list
    /// could only name the built-ins it knew about, while the MCP servers from
    /// `~/.claude.json` were loaded all the same and *their* tools were on no
    /// list at all. `--tools ""` disables the built-in set wholesale, and the
    /// two MCP flags make sure no server is configured to begin with.
    ///
    /// `--no-session-persistence` is a privacy rule, not a performance one:
    /// `claude -p` otherwise writes the full prompt — transcript included — to
    /// `~/.claude/projects/`, a second copy of every meeting that no retention
    /// run ever sees and that "SQLite is the truth" does not account for.
    private static let hardening = [
        "--tools", "",
        "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
        "--no-session-persistence",
    ]

    func availability() async -> ProviderAvailability {
        guard ClaudeCodeCLILocator.locate() != nil else {
            return .unavailable(reason: String(localized: "Claude Code CLI nicht gefunden."))
        }
        return .available
    }

    func summarize(transcript: String, context: MeetingContext) async throws -> Summary {
        guard let cliPath = ClaudeCodeCLILocator.locate() else {
            throw SummarizationError.notConfigured(String(localized: "Claude Code CLI nicht gefunden."))
        }

        // The note is written in the language of the meeting, not of the app.
        let prompt = SummarizationPrompt.messages(transcript: transcript, context: context)
        let response = try await Self.runAndParse(
            cliPath: cliPath,
            system: prompt.system,
            user: prompt.user
        )
        return Summary(rawModelOutput: response.text, providerID: id, usage: response.usage)
    }

    func complete(system: String, user: String) async throws -> Completion {
        guard let cliPath = ClaudeCodeCLILocator.locate() else {
            throw SummarizationError.notConfigured(String(localized: "Claude Code CLI nicht gefunden."))
        }
        let response = try await Self.runAndParse(cliPath: cliPath, system: system, user: user)
        return Completion(text: response.text, usage: response.usage)
    }

    /// Runs the headless CLI (tools locked down) and returns the `result`
    /// field. The parser is deliberately defensive and names the CLI as the
    /// culprit on any surprise. Shared by `summarize` and `complete`.
    ///
    /// The system prompt goes through `--system-prompt`, not concatenated into
    /// stdin: glued together with a `---` separator, "ignore previous
    /// instructions" inside a transcript sat on exactly the same footing as the
    /// instructions themselves.
    private static func runAndParse(
        cliPath: String,
        system: String,
        user: String,
        timeout: TimeInterval = 300
    ) async throws -> (text: String, usage: SummarizationUsage?) {
        let output = try await CLIProcessRunner.run(
            tool: "Claude Code CLI",
            executable: cliPath,
            arguments: ["-p", "--output-format", "json", "--system-prompt", system] + hardening,
            stdin: user,
            timeout: timeout
        )

        // Expected shape: {"result": "...", ...} — defensive against CLI updates.
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SummarizationError.unexpectedResponse(
                String(localized: "Claude Code CLI lieferte kein JSON — CLI-Update? Ausgabe: \(String(output.prefix(200)))")
            )
        }
        if let isError = object["is_error"] as? Bool, isError {
            let subtype = object["subtype"] as? String ?? "unbekannt"
            throw SummarizationError.requestFailed(String(localized: "Claude Code CLI meldet Fehler (\(subtype)) — ggf. Max-Limit erreicht."))
        }
        guard let result = object["result"] as? String,
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SummarizationError.unexpectedResponse(String(localized: "Feld \"result\" fehlt oder ist leer — CLI-Update?"))
        }
        return (result.trimmingCharacters(in: .whitespacesAndNewlines), usage(from: object))
    }

    /// Pulls token counts and the reported dollar figure out of a CLI result.
    ///
    /// `total_cost_usd` is what the call *would* have cost on the metered API;
    /// on a flat-rate subscription nothing is charged, so `billed` is false and every
    /// display site must say so. Usage reporting is not part of any contract —
    /// missing or reshaped fields yield nil rather than a wrong number, which
    /// costs a statistics row and nothing else.
    private static func usage(from object: [String: Any]) -> SummarizationUsage? {
        let usage = object["usage"] as? [String: Any]
        let cost = object["total_cost_usd"] as? Double
        guard usage != nil || cost != nil else { return nil }
        func count(_ key: String) -> Int { (usage?[key] as? Int) ?? 0 }
        return SummarizationUsage(
            inputTokens: count("input_tokens"),
            outputTokens: count("output_tokens"),
            cacheCreationTokens: count("cache_creation_input_tokens"),
            cacheReadTokens: count("cache_read_input_tokens"),
            costUSD: cost ?? 0,
            billed: false
        )
    }

}
