import XCTest

final class SummarizationPromptTests: XCTestCase {
    func testUserPromptCarriesContextAndTranscript() {
        let context = MeetingContext(
            title: "Weekly Sync",
            date: Date(timeIntervalSince1970: 1_780_000_000),
            durationSeconds: 1800
        )
        let prompt = SummarizationPrompt.user(transcript: "Hallo zusammen.", context: context)
        XCTAssertTrue(prompt.contains("Weekly Sync"))
        XCTAssertTrue(prompt.contains("30 Minuten"))
        XCTAssertTrue(prompt.contains("Hallo zusammen."))
    }
}

/// Real end-to-end call through the locally installed, logged-in Claude Code
/// CLI. One small transcript — verifies the headless
/// `claude -p --output-format json` contract actually holds on the
/// installed CLI version.
final class ClaudeCodeCLIProviderTests: XCTestCase {
    func testSummarizesTinyTranscriptViaCLI() async throws {
        let provider = ClaudeCodeCLIProvider()

        let availability = await provider.availability()
        try XCTSkipIf(
            availability != .available,
            "Claude Code CLI nicht installiert — Test übersprungen."
        )

        let transcript = """
        Alex: Kurzes Standup. Ich habe gestern das Diktat-Feature fertig gebaut.
        Anna: Super. Ich übernehme das Testing bis Freitag.
        Alex: Dann entscheiden wir: Release am Montag.
        """
        let summary = try await provider.summarize(
            transcript: transcript,
            context: MeetingContext(title: "Standup", date: .now, durationSeconds: 120)
        )

        XCTAssertFalse(summary.markdown.isEmpty)
        XCTAssertTrue(
            summary.markdown.contains("Zusammenfassung"),
            "Erwartete Markdown-Struktur fehlt: \(summary.markdown.prefix(200))"
        )
    }
}
