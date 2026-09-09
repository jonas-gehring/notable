import SwiftUI

// MARK: - Zusammenfassung


struct SummarizationSettingsView: View {
    @AppStorage(DefaultsKey.summarizationProvider.key) private var providerRaw = DefaultsKey.summarizationProvider.fallback

    @State private var apiKeyInput = ""
    @State private var apiKeyStored = false
    @State private var confirmKeyRemoval = false
    @State private var keyTestResult: String?
    @State private var cliPath: String?

    private var provider: SummarizationProviderID {
        SummarizationProviderID(rawValue: providerRaw) ?? .anthropicAPI
    }

    var body: some View {
        Form {
            Section {
                Picker("Zusammenfassung über", selection: $providerRaw) {
                    ForEach(SummarizationProviderID.allCases) { provider in
                        Text(provider.label).tag(provider.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            if provider == .anthropicAPI {
                Section("Anthropic API") {
                    SecureField("API-Key", text: $apiKeyInput, prompt: Text("sk-ant-…"))
                    HStack {
                        Button("Im Schlüsselbund sichern") {
                            let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            apiKeyStored = KeychainStore.write(trimmed, account: KeychainStore.anthropicAPIKeyAccount)
                            // Only drop the typed key once it is safely stored —
                            // a failed write used to clear the field and leave
                            // the user with nothing but "Kein Key hinterlegt".
                            if apiKeyStored {
                                apiKeyInput = ""
                                keyTestResult = nil
                            } else {
                                keyTestResult = String(localized: "Schlüsselbund-Zugriff fehlgeschlagen — Key nicht gesichert.")
                            }
                        }
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if apiKeyStored {
                            Label("Key im Schlüsselbund hinterlegt", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            // Confirmed: the key is not recoverable from here,
                            // and the button sits one row under "Sichern".
                            Button("Entfernen", role: .destructive) { confirmKeyRemoval = true }
                                .confirmationDialog(
                                    "API-Key entfernen?",
                                    isPresented: $confirmKeyRemoval
                                ) {
                                    Button("Entfernen", role: .destructive) {
                                        KeychainStore.delete(account: KeychainStore.anthropicAPIKeyAccount)
                                        apiKeyStored = false
                                    }
                                    Button("Abbrechen", role: .cancel) {}
                                } message: {
                                    Text("Der Schlüssel wird aus dem Schlüsselbund gelöscht. Zusammenfassungen über die API sind danach nicht mehr möglich.")
                                }
                        } else {
                            Label("Kein Key hinterlegt", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if apiKeyStored {
                        HStack {
                            Button("Verbindung testen") {
                                keyTestResult = String(localized: "Prüfe…")
                                Task { keyTestResult = await AnthropicAPIProvider.validateKey() }
                            }
                            if let keyTestResult {
                                Text(keyTestResult)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Modell: claude-sonnet-5. Der Key wird ausschließlich im macOS-Schlüsselbund gespeichert.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // Every CLI provider, not just Claude Code: picking Gemini or Codex
            // here used to leave the pane blank — no path, no availability, no
            // way to try a call, and no interface at all for the argument
            // override those two exist for.
            if let cli = SummarizationProviderID(rawValue: providerRaw), cli.isCLI {
                Section(cli.label) {
                    CLIProviderStatusRow(provider: cli)
                    Text("Nutzt die lokal installierte, eingeloggte CLI — ohne API-Schlüssel. Aufrufe zählen auf dein Abo-Kontingent.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apiKeyStored = KeychainStore.read(account: KeychainStore.anthropicAPIKeyAccount) != nil
            cliPath = ClaudeCodeCLILocator.locate()
        }
    }
}
