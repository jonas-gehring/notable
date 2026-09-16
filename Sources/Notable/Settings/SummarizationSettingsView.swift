import SwiftUI

// MARK: - Zusammenfassung

/// A **section** of the meetings page since Spec 38, not a page.
///
/// It had one of its own because `SummarizationProvider` is a module — the
/// clearest case of a page following the code rather than a question somebody
/// asks. Summarizing is what happens to a meeting after it stops, so it belongs
/// to meetings.
struct SummarizationSection: View {
    @AppStorage(DefaultsKey.summarizationProvider.key) private var providerRaw = DefaultsKey.summarizationProvider.fallback

    @State private var apiKeyInput = ""
    @State private var apiKeyStored = false
    @State private var confirmKeyRemoval = false
    @State private var keyTestResult: String?

    private var provider: SummarizationProviderID {
        SummarizationProviderID(rawValue: providerRaw) ?? .anthropicAPI
    }

    var body: some View {
        Section {
            Picker("Zusammenfassung über", selection: $providerRaw) {
                ForEach(SummarizationProviderID.allCases) { provider in
                    Text(provider.label).tag(provider.rawValue)
                }
            }

            if provider == .anthropicAPI {
                SecureField("API-Key", text: $apiKeyInput, prompt: Text(verbatim: "sk-ant-…"))
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
            }

            // Every CLI provider, not just Claude Code: picking Gemini or Codex
            // here used to leave the pane blank — no path, no availability, no
            // way to try a call.
            if provider.isCLI {
                CLIProviderStatusRow(provider: provider)
            }
        } header: {
            Text("Zusammenfassung")
        } footer: {
            Text(provider.isCLI
                 ? "Nutzt die lokal installierte, eingeloggte CLI — ohne API-Schlüssel. Aufrufe zählen auf dein Abo-Kontingent. Dieselbe CLI verbessert auf Wunsch auch Diktate."
                 : "Der Key liegt ausschließlich im macOS-Schlüsselbund. Diktattext erreicht ihn nie — dafür wird immer eine CLI benutzt.")
        }
        .onAppear {
            apiKeyStored = KeychainStore.read(account: KeychainStore.anthropicAPIKeyAccount) != nil
        }
    }
}
