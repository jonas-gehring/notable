import Foundation

/// A locally installed AI CLI, described rather than reimplemented.
///
/// Claude Code, Gemini CLI and Codex CLI all do the same thing for our purposes:
/// a logged-in process on this machine takes a prompt and hands back text, billed
/// against a subscription instead of per token. What differs is the binary name,
/// the arguments, and whether the answer arrives as JSON or as plain text — so
/// that is all this type holds.
///
/// **None of these are local.** Each one ships the text to its vendor; only the
/// billing stays here. Every display site says so.
struct AgentCLITool: Sendable {
    let id: String
    let displayName: String
    /// Vendor the text reaches — named plainly wherever the user chooses one.
    let destination: String
    /// Binary names to look for, in order.
    let binaries: [String]
    /// Arguments before stdin. Overridable per tool (see `arguments(store:)`),
    /// because these could not be verified against a real install here.
    let defaultArguments: [String]
    /// Keys that may carry the answer when the CLI emits JSON. Tried in order;
    /// plain stdout is the fallback, so a CLI that ignores JSON entirely still
    /// works.
    let textKeys: [String]

    static let gemini = AgentCLITool(
        id: "gemini-cli",
        displayName: "Google Gemini CLI",
        destination: "Google",
        binaries: ["gemini"],
        // Prompt on stdin: a meeting transcript is far too long to be comfortable
        // as an argv entry, and every one of these CLIs reads stdin when it is
        // not a terminal.
        defaultArguments: [],
        textKeys: ["response", "text", "output", "result"]
    )

    static let codex = AgentCLITool(
        id: "codex-cli",
        displayName: "OpenAI Codex CLI",
        destination: "OpenAI",
        binaries: ["codex"],
        // `exec` is the non-interactive subcommand; `-` reads the prompt from
        // stdin.
        defaultArguments: ["exec", "-"],
        textKeys: ["last_agent_message", "message", "text", "output", "result"]
    )

    static let all: [AgentCLITool] = [.gemini, .codex]

    /// The escape hatch. These invocations are the documented ones but could not
    /// be run against a real install on the machine this was built on, and a
    /// wrong guess that needs a rebuild to fix would be worse than a settings
    /// field nobody touches.
    var argumentsKey: String { "cliArguments.\(id)" }

    func arguments(store: UserDefaults = .standard) -> [String] {
        guard let custom = store.string(forKey: argumentsKey), !custom.isEmpty else {
            return defaultArguments
        }
        return custom.split(separator: " ").map(String.init)
    }

    func locate() -> String? { CLIToolLocator.locate(binaries) }
}

/// `SummarizationProvider` for any `AgentCLITool`.
struct AgentCLIProvider: SummarizationProvider {
    let tool: AgentCLITool

    var id: String { tool.id }
    var displayName: String { "\(tool.displayName) — Text geht an \(tool.destination)" }

    func availability() async -> ProviderAvailability {
        guard tool.locate() != nil else {
            return .unavailable(reason: "\(tool.displayName) nicht gefunden.")
        }
        return .available
    }

    func summarize(transcript: String, context: MeetingContext) async throws -> Summary {
        let prompt = SummarizationPrompt.system
            + "\n\n---\n\n"
            + SummarizationPrompt.user(transcript: transcript, context: context)
        let response = try await run(prompt: prompt)
        return Summary(rawModelOutput: response.text, providerID: id, usage: response.usage)
    }

    func complete(system: String, user: String) async throws -> Completion {
        let response = try await run(prompt: system + "\n\n---\n\n" + user)
        return Completion(text: response.text, usage: response.usage)
    }

    private func run(prompt: String) async throws -> (text: String, usage: SummarizationUsage?) {
        guard let path = tool.locate() else {
            throw SummarizationError.notConfigured("\(tool.displayName) nicht gefunden.")
        }
        let output = try await CLIProcessRunner.run(
            tool: tool.displayName,
            executable: path,
            arguments: tool.arguments(),
            stdin: prompt
        )
        return try Self.parse(output, tool: tool)
    }

    /// Pure, and deliberately forgiving.
    ///
    /// These CLIs change their output shape between releases and only some of
    /// them emit JSON at all. So: take JSON if it parses and carries one of the
    /// known text fields, otherwise treat stdout as the answer. Anything else
    /// would turn a cosmetic CLI update into a broken feature.
    static let commonTextKeys = ["response", "result", "text", "output", "message", "content"]

    static func parse(_ output: String, tool: AgentCLITool) throws -> (text: String, usage: SummarizationUsage?) {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SummarizationError.unexpectedResponse("\(tool.displayName) lieferte keine Ausgabe.")
        }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // The tool's own keys first, then the names every one of these CLIs
            // has used at some point. All of them mean "this is the answer", so
            // trying them is forgiving rather than guessing.
            let keys = tool.textKeys + Self.commonTextKeys.filter { !tool.textKeys.contains($0) }
            if let text = keys.lazy.compactMap({ object[$0] as? String }).first,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (text.trimmingCharacters(in: .whitespacesAndNewlines), usage(from: object))
            }
            // JSON without a text field is a shape we do not know — do not guess
            // at which key is the answer.
            throw SummarizationError.unexpectedResponse(
                "\(tool.displayName) lieferte JSON ohne bekanntes Textfeld: \(String(trimmed.prefix(200)))"
            )
        }
        return (trimmed, nil)
    }

    /// Token counts where the CLI happens to report them.
    ///
    /// `billed` is always false: these are subscription CLIs, so nothing is
    /// charged per call and a reported dollar figure — if one appears at all —
    /// is what the call *would* have cost. The same rule as the Claude CLI, and
    /// for the same reason: a shadow cost must never be summed with real spend.
    static func usage(from object: [String: Any]) -> SummarizationUsage? {
        let usage = (object["usage"] as? [String: Any]) ?? (object["token_usage"] as? [String: Any])
        guard let usage else { return nil }
        func count(_ keys: [String]) -> Int {
            for key in keys {
                if let value = usage[key] as? Int { return value }
            }
            return 0
        }
        let input = count(["input_tokens", "prompt_tokens", "promptTokenCount", "input"])
        let output = count(["output_tokens", "completion_tokens", "candidatesTokenCount", "output"])
        guard input > 0 || output > 0 else { return nil }
        return SummarizationUsage(
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: count(["cache_creation_input_tokens", "cachedContentTokenCount"]),
            cacheReadTokens: count(["cache_read_input_tokens", "cached_tokens"]),
            costUSD: (object["total_cost_usd"] as? Double) ?? 0,
            billed: false
        )
    }
}

/// GUI apps do not inherit a shell PATH, so CLIs are searched at the usual
/// install locations.
enum CLIToolLocator {
    static let searchPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin", "/usr/bin"]
    }()

    static func locate(_ binaries: [String]) -> String? {
        for binary in binaries {
            for directory in searchPaths {
                let path = "\(directory)/\(binary)"
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }
}
