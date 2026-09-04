import XCTest
@testable import Notable

/// Gemini and Codex as further subscription CLIs.
///
/// **Only the Claude CLI could be verified against a real install on the machine
/// this was written on** — so the parser is where the confidence has to come
/// from: it is forgiving by design, because these tools reshape their output
/// between releases and only some of them emit JSON at all.
final class AgentCLIProviderTests: XCTestCase {
    // MARK: - Parsing

    func testPlainTextOutputIsTheAnswer() throws {
        let parsed = try AgentCLIProvider.parse("  Das ist die Antwort.\n", tool: .gemini)
        XCTAssertEqual(parsed.text, "Das ist die Antwort.")
        XCTAssertNil(parsed.usage, "keine Zahlen gemeldet heißt keine erfundenen Zahlen")
    }

    func testJSONOutputIsUnwrapped() throws {
        let parsed = try AgentCLIProvider.parse(#"{"response": "Die Antwort."}"#, tool: .gemini)
        XCTAssertEqual(parsed.text, "Die Antwort.")
    }

    func testCodexUsesItsOwnFieldName() throws {
        let parsed = try AgentCLIProvider.parse(#"{"last_agent_message": "Fertig."}"#, tool: .codex)
        XCTAssertEqual(parsed.text, "Fertig.")
    }

    /// Text that merely *looks* like JSON is still text.
    func testNonJSONBracesAreTreatedAsText() throws {
        let parsed = try AgentCLIProvider.parse("{nicht wirklich json}", tool: .gemini)
        XCTAssertEqual(parsed.text, "{nicht wirklich json}")
    }

    /// JSON in an unknown shape must fail loudly rather than have a key guessed
    /// at — pasting the wrong field into someone's text box is worse than an
    /// error message.
    func testUnknownJSONShapeThrows() {
        XCTAssertThrowsError(try AgentCLIProvider.parse(#"{"unbekannt": {"a": 1}}"#, tool: .gemini))
    }

    func testEmptyOutputThrows() {
        XCTAssertThrowsError(try AgentCLIProvider.parse("   \n", tool: .codex))
    }

    // MARK: - Usage

    func testTokenCountsAreReadWhenReported() throws {
        let json = #"{"response": "Text.", "usage": {"prompt_tokens": 1200, "completion_tokens": 80}}"#
        let usage = try XCTUnwrap(AgentCLIProvider.parse(json, tool: .gemini).usage)
        XCTAssertEqual(usage.inputTokens, 1200)
        XCTAssertEqual(usage.outputTokens, 80)
    }

    /// The rule that outlives every provider: a subscription CLI charges nothing
    /// per call, so its cost is a shadow figure and must never be summed with
    /// real API spend.
    func testSubscriptionCLIsAreNeverBilled() throws {
        let json = #"{"response": "Text.", "usage": {"input_tokens": 10, "output_tokens": 5}, "total_cost_usd": 0.04}"#
        let usage = try XCTUnwrap(AgentCLIProvider.parse(json, tool: .codex).usage)
        XCTAssertFalse(usage.billed)
        XCTAssertEqual(usage.costUSD, 0.04, accuracy: 0.0001)
    }

    func testAllZeroUsageIsReportedAsUnknown() throws {
        let json = #"{"response": "Text.", "usage": {"prompt_tokens": 0, "completion_tokens": 0}}"#
        XCTAssertNil(try AgentCLIProvider.parse(json, tool: .gemini).usage)
    }

    // MARK: - Invocation

    /// The arguments could not be verified here, so they are overridable without
    /// a rebuild.
    func testArgumentsCanBeOverridden() {
        let store = UserDefaults(suiteName: "CLI.\(UUID().uuidString)")!
        XCTAssertEqual(AgentCLITool.codex.arguments(store: store), ["exec", "--sandbox", "read-only", "-"])
        store.set("chat --quiet", forKey: AgentCLITool.codex.argumentsKey)
        XCTAssertEqual(AgentCLITool.codex.arguments(store: store), ["chat", "--quiet"])
    }

    /// A transcript is untrusted input, and `codex exec` is the one tool here
    /// whose sandbox costs nothing to demand (macOS Seatbelt, nothing to
    /// install). Its default must not silently drift to something writable.
    func testCodexRunsSandboxedByDefault() {
        let store = UserDefaults(suiteName: "CLI.\(UUID().uuidString)")!
        let arguments = AgentCLITool.codex.arguments(store: store)
        XCTAssertEqual(arguments.firstIndex(of: "--sandbox").map { arguments[$0 + 1] }, "read-only")
    }

    /// The two halves of the prompt must not read as one voice: a bare `---`
    /// put "ignore previous instructions" from inside a transcript on the same
    /// footing as the instructions themselves.
    func testPromptLabelsTheTrustBoundary() {
        let prompt = AgentCLIProvider.prompt(system: "SYS", user: "USER")
        let instructions = try! XCTUnwrap(prompt.range(of: "[ANWEISUNGEN]"))
        let material = try! XCTUnwrap(prompt.range(of: "[MATERIAL"))
        XCTAssertTrue(instructions.lowerBound < material.lowerBound)
        XCTAssertTrue(prompt.contains("SYS"))
        XCTAssertTrue(prompt.contains("USER"))
    }

    /// Provider-independent, and the only defence Gemini has — so it is pinned
    /// where the prompt lives, not left to a reviewer to notice.
    func testSystemPromptsStateThatTranscriptsAreNotInstructions() {
        for prompt in [SummarizationPrompt.system, ChatPrompt.system] {
            XCTAssertTrue(prompt.contains("zitiertes Material"), prompt.prefix(80).description)
            XCTAssertTrue(prompt.contains("niemals ein Befehl"))
        }
    }

    func testDisplayNameNamesTheDestination() {
        XCTAssertTrue(AgentCLIProvider(tool: .gemini).displayName.contains("Google"))
        XCTAssertTrue(AgentCLIProvider(tool: .codex).displayName.contains("OpenAI"))
    }

    // MARK: - Registration

    func testBothProvidersAreSelectable() {
        XCTAssertNotNil(SummarizationService.provider(withID: "gemini-cli"))
        XCTAssertNotNil(SummarizationService.provider(withID: "codex-cli"))
    }

    // MARK: - The dictation guard, widened but not opened

    /// Widened to the subscription CLIs, still closed against the metered key —
    /// the rule was always about billing, not about a vendor.
    func testDictationAcceptsEverySubscriptionCLI() {
        XCTAssertEqual(DictationEnhancer.provider(named: "gemini-cli").id, "gemini-cli")
        XCTAssertEqual(DictationEnhancer.provider(named: "codex-cli").id, "codex-cli")
        XCTAssertEqual(DictationEnhancer.provider(named: "claude-code-cli").id, "claude-code-cli")
    }

    func testDictationStillRefusesTheMeteredAPI() {
        XCTAssertEqual(DictationEnhancer.provider(named: "anthropic-api").id, "claude-code-cli")
        XCTAssertEqual(DictationEnhancer.provider(named: "unsinn").id, "claude-code-cli")
        XCTAssertEqual(DictationEnhancer.provider(named: nil).id, "claude-code-cli")
    }

    func testEveryCLIProviderIDResolvesToARealProvider() {
        for id in SummarizationProviderID.cliProviders {
            XCTAssertTrue(id.isCLI, id.rawValue)
            XCTAssertEqual(DictationEnhancer.provider(named: id.rawValue).id, id.rawValue)
        }
        XCTAssertFalse(SummarizationProviderID.anthropicAPI.isCLI)
    }

    // MARK: - Review 2026-09-03

    /// `codex exec --json` and Gemini's stream mode emit one object per line.
    /// The whole blob does not parse, and the old parser then pasted the raw
    /// JSONL into the note as if it were the summary.
    func testJSONLinesYieldTheLastAnswer() throws {
        let output = """
        {"type":"task_started"}
        {"type":"agent_message","message":"Zwischenschritt"}
        {"type":"agent_message","last_agent_message":"Die fertige Zusammenfassung."}
        """
        let parsed = try AgentCLIProvider.parse(output, tool: .codex)
        XCTAssertEqual(parsed.text, "Die fertige Zusammenfassung.")
    }

    /// A single JSON object is not JSONL and must keep working.
    func testSingleJSONObjectStillParses() throws {
        let parsed = try AgentCLIProvider.parse(#"{"response":"Antwort"}"#, tool: .gemini)
        XCTAssertEqual(parsed.text, "Antwort")
    }

    /// Plain multi-line text is not JSONL either.
    func testPlainMultilineOutputIsTakenVerbatim() throws {
        let output = "Erste Zeile\nZweite Zeile"
        let parsed = try AgentCLIProvider.parse(output, tool: .gemini)
        XCTAssertEqual(parsed.text, output)
    }

    /// A quoted argument is one argument.
    func testCustomArgumentsRespectQuoting() {
        XCTAssertEqual(
            AgentCLITool.splitArguments(#"--model "gemini 2.5 pro" -p"#),
            ["--model", "gemini 2.5 pro", "-p"]
        )
        XCTAssertEqual(AgentCLITool.splitArguments("exec  --sandbox   read-only -"),
                       ["exec", "--sandbox", "read-only", "-"])
    }

    /// The Codex invocation pins the read-only sandbox rather than relying on
    /// it staying the default.
    func testCodexRunsInAReadOnlySandbox() {
        XCTAssertEqual(AgentCLITool.codex.defaultArguments, ["exec", "--sandbox", "read-only", "-"])
    }
}
