import SwiftUI

/// Availability, a real test call, and the argument override for one CLI
/// provider.
///
/// Extracted from the dictation section because the *summary* pane needed the
/// same thing and did not have it: `SummarizationProviderID.allCases` has four
/// entries, and that pane only ever showed a status for two of them — pick
/// Gemini or Codex as the meeting provider and the pane went blank, with no
/// path, no availability and no way to try a call. The argument override
/// (`cliArguments.<id>`) had no interface at all, although the invocations for
/// those two are documented rather than verified and the whole point of the
/// setting is fixing one that turns out to be wrong.
struct CLIProviderStatusRow: View {
    let provider: SummarizationProviderID

    @State private var status: String = String(localized: "wird geprüft…")
    @State private var testResult: String?
    @State private var argumentsInput = ""
    @State private var argumentsSaved = false

    /// The tool behind this provider, when it is one of the described CLIs.
    /// `.claudeCodeCLI` has its own locator and no argument override.
    private var tool: AgentCLITool? {
        AgentCLITool.all.first { $0.id == provider.rawValue }
    }

    var body: some View {
        Group {
            LabeledContent("Status", value: status)
            Button("Verbindung testen") { runTest() }
                .buttonStyle(.link)
            if let testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let tool {
                LabeledContent("Aufruf") {
                    HStack {
                        TextField(
                            "Argumente",
                            text: $argumentsInput,
                            prompt: Text(tool.defaultArguments.joined(separator: " "))
                        )
                        .font(.system(.callout, design: .monospaced))
                        Button("Sichern") { saveArguments(for: tool) }
                            .buttonStyle(.link)
                    }
                }
                if argumentsSaved {
                    Text("Gesichert — beim nächsten Aufruf aktiv.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Leer lassen für den Standardaufruf. Anführungszeichen gruppieren, wie in der Shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: provider.rawValue) {
            argumentsInput = tool.map { UserDefaults.standard.string(forKey: $0.argumentsKey) ?? "" } ?? ""
            argumentsSaved = false
            check()
        }
    }

    private func check() {
        testResult = nil
        Task {
            status = switch await DictationEnhancer.provider(named: provider.rawValue).availability() {
            case .available: String(localized: "gefunden und einsatzbereit")
            case .unavailable(let reason): reason
            }
        }
    }

    /// One real round-trip with a throwaway prompt.
    ///
    /// Worth a button rather than a promise: only the Claude CLI could be
    /// verified against a real install while this was written, so the exact
    /// invocation for the other two is documented, not proven. This is how you
    /// find that out in ten seconds instead of during a meeting.
    private func runTest() {
        testResult = String(localized: "läuft…")
        Task {
            do {
                let completion = try await DictationEnhancer.provider(named: provider.rawValue).complete(
                    system: "Antworte mit genau einem Wort.",
                    user: "Sag: bereit"
                )
                testResult = String(localized: "Antwort: \(completion.text.prefix(120))")
            } catch {
                testResult = String(localized: "Fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    private func saveArguments(for tool: AgentCLITool) {
        let trimmed = argumentsInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: tool.argumentsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: tool.argumentsKey)
        }
        argumentsSaved = true
        check()
    }
}
