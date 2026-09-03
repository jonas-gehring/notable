import SwiftUI

/// Diktat → „Textverbesserung" (issue #1 Stufe 2).
///
/// This section carries the sentence that the one-time consent dialog was
/// supposed to carry, and it carries it permanently rather than once: switching
/// this on is the consent, and it can be revoked here at any time. The wording
/// is deliberately blunt — the Claude Code CLI is a locally started process that
/// sends text to Anthropic; only the billing is local.
struct EnhancementSettingsSection: View {
    @AppStorage(EnhancementSettings.enabledKey) private var enabled = false
    @AppStorage(EnhancementSettings.hotkeyKey) private var hotkeyRaw = ""
    @AppStorage(EnhancementSettings.profileKey) private var profileID = ""
    @AppStorage(EnhancementSettings.deadlineKey) private var deadline = 15.0
    @AppStorage(EnhancementSettings.providerKey) private var providerRaw = SummarizationProviderID.claudeCodeCLI.rawValue

    @State private var customProfiles: [EnhancementProfile] = EnhancementProfile.custom()
    @State private var editing: EnhancementProfile?
    @State private var cliStatus = "wird geprüft…"
    @State private var testResult: String?

    let onHotkeyChange: () -> Void

    var body: some View {
        Section {
            Toggle("Verbesserung auf Abruf erlauben", isOn: $enabled)
                .onChange(of: enabled) { _, _ in onHotkeyChange() }

            if enabled {
                Picker("Dienst", selection: $providerRaw) {
                    ForEach(SummarizationProviderID.cliProviders) { id in
                        Text(id.label).tag(id.rawValue)
                    }
                }
                .onChange(of: providerRaw) { _, _ in checkProvider() }

                Picker("Taste für „Diktat mit Verbesserung\u{201C}", selection: $hotkeyRaw) {
                    Text("Keine — nur über das Menü").tag("")
                    ForEach(HotkeySpec.allCases) { spec in
                        Text(spec.label).tag(spec.rawValue)
                    }
                }
                .onChange(of: hotkeyRaw) { _, _ in onHotkeyChange() }

                Picker("Profil", selection: $profileID) {
                    Text("Automatisch nach Ziel-App").tag("")
                    ForEach(EnhancementProfile.builtIn + customProfiles) { profile in
                        Text(profile.title).tag(profile.id)
                    }
                }

                LabeledContent("Zeitbudget") {
                    HStack {
                        Slider(value: $deadline, in: 5...60, step: 5)
                            .frame(width: 160)
                        Text("\(Int(deadline)) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Status", value: cliStatus)
                Button("Verbindung testen") { runTest() }
                    .buttonStyle(.link)
                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                ForEach(customProfiles) { profile in
                    HStack {
                        Text(profile.title)
                        Spacer()
                        Button("Bearbeiten") { editing = profile }
                            .buttonStyle(.link)
                        Button {
                            customProfiles.removeAll { $0.id == profile.id }
                            EnhancementProfile.saveCustom(customProfiles)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Eigenes Profil…") {
                    editing = EnhancementProfile(id: UUID().uuidString, title: "", systemPrompt: "", isCustom: true)
                }
            }
        } header: {
            Text("Textverbesserung")
        } footer: {
            Text("""
            Aus, solange dieser Schalter aus ist — dann verlässt kein diktiertes Zeichen \
            das Gerät. Eingeschaltet passiert es weiterhin nur, wenn du es pro Diktat \
            auslöst: über die zweite Taste oder „Letztes Diktat verbessern\u{201C} im Menü. \
            Ein normales Diktat bleibt unverändert schnell und offline.

            Wohin der Text dann geht, ohne Beschönigung: an den Anbieter der oben \
            gewählten CLI — Anthropic, Google oder OpenAI. Lokal ist daran nur, dass \
            der Prozess auf deinem Rechner startet, und die Abrechnung (Abo-Kontingent \
            statt Rechnung pro Token) — der Text selbst geht ins Netz. \
            Der bezahlte API-Schlüssel wird dafür nie benutzt, auch nicht, wenn er für \
            Meetings eingestellt ist. Jeder Lauf wird in der Statistik gezählt, damit \
            nachzählbar bleibt, wie oft das passiert ist.

            Audio verlässt das Gerät weiterhin nie.
            """)
        }
        .sheet(item: $editing) { profile in
            ProfileEditor(profile: profile) { saved in
                if let index = customProfiles.firstIndex(where: { $0.id == saved.id }) {
                    customProfiles[index] = saved
                } else {
                    customProfiles.append(saved)
                }
                EnhancementProfile.saveCustom(customProfiles)
                customProfiles = EnhancementProfile.custom()
            }
        }
        .task(id: enabled) { checkProvider() }
        .task(id: providerRaw) { checkProvider() }
    }

    private func checkProvider() {
        guard enabled else { return }
        testResult = nil
        Task {
            cliStatus = switch await DictationEnhancer.provider(named: providerRaw).availability() {
            case .available: "gefunden und einsatzbereit"
            case .unavailable(let reason): reason
            }
        }
    }

    /// One real round-trip with a throwaway prompt.
    ///
    /// Worth a button rather than a promise: only the Claude CLI could be
    /// verified against a real install while this was written, so the exact
    /// invocation for the other two is documented, not proven. This is how you
    /// find that out in ten seconds instead of during a dictation.
    private func runTest() {
        testResult = "läuft…"
        Task {
            let provider = DictationEnhancer.provider(named: providerRaw)
            do {
                let completion = try await provider.complete(
                    system: "Antworte mit genau einem Wort.",
                    user: "Sag: bereit"
                )
                testResult = "Antwort: \(completion.text.prefix(120))"
            } catch {
                testResult = "Fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
}

private struct ProfileEditor: View {
    @State var profile: EnhancementProfile
    let onSave: (EnhancementProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Verbesserungs-Profil")
                .font(.headline)
            Form {
                TextField("Titel", text: $profile.title, prompt: Text("Protokollstil"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Anweisung an das Modell")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $profile.systemPrompt)
                        .frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                }
            }
            .formStyle(.grouped)
            Text("Die gemeinsamen Regeln (nichts erfinden, nur den Text ausgeben, Sprache behalten) werden automatisch angehängt.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Sichern") {
                    var saved = profile
                    saved.systemPrompt += EnhancementProfile.commonRules
                    saved.isCustom = true
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.title.isEmpty || profile.systemPrompt.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 480)
    }
}
