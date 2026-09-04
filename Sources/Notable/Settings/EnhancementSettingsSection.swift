import SwiftUI

/// Diktat → „Textverbesserung" (issue #1 Stufe 2).
///
/// This section carries the sentence that the one-time consent dialog was
/// supposed to carry, and it carries it permanently rather than once: switching
/// this on is the consent, and it can be revoked here at any time. The wording
/// is deliberately blunt — the chosen CLI is a locally started process that sends
/// the text to its vendor; only the billing is local.
struct EnhancementSettingsSection: View {
    @AppStorage(EnhancementSettings.enabledKey) private var enabled = false
    @AppStorage(EnhancementSettings.hotkeyKey) private var hotkeyRaw = ""
    @AppStorage(EnhancementSettings.profileKey) private var profileID = ""
    @AppStorage(EnhancementSettings.deadlineKey) private var deadline = 15.0
    @AppStorage(EnhancementSettings.providerKey) private var providerRaw = SummarizationProviderID.claudeCodeCLI.rawValue

    @State private var customProfiles: [EnhancementProfile] = EnhancementProfile.custom()
    @State private var editing: EnhancementProfile?
    @State private var pendingDeletion: EnhancementProfile?

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

                // The plain dictation key is not on offer here. `HotkeyRouting`
                // treats one key configured for both roles as "no enhancement
                // key", so choosing it silently switched the whole feature off —
                // the picker said one thing and the tap did another.
                Picker("Taste für „Diktat mit Verbesserung\u{201C}", selection: $hotkeyRaw) {
                    Text("Keine — nur über das Menü").tag("")
                    ForEach(HotkeySpec.allCases.filter { $0 != HotkeySpec.current }) { spec in
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

                // Shared with the summary pane — same provider, same three
                // questions (is it there, does a call work, what is the exact
                // invocation).
                if let cli = SummarizationProviderID(rawValue: providerRaw) {
                    CLIProviderStatusRow(provider: cli)
                }

                ForEach(customProfiles) { profile in
                    HStack {
                        Text(profile.title)
                        Spacer()
                        Button("Bearbeiten") { editing = profile }
                            .buttonStyle(.link)
                        Button {
                            pendingDeletion = profile
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Profil löschen")
                        .accessibilityLabel("Profil löschen")
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
        // A profile is a prompt someone wrote; a one-click trash icon with no
        // undo is the wrong trade.
        .confirmationDialog(
            "Profil löschen?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { profile in
            Button("Löschen", role: .destructive) {
                customProfiles.removeAll { $0.id == profile.id }
                EnhancementProfile.saveCustom(customProfiles)
            }
            Button("Abbrechen", role: .cancel) { pendingDeletion = nil }
        } message: { profile in
            Text("„\(profile.title)“ wird endgültig entfernt.")
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
                    // No `+= commonRules` here: they are appended at use time
                    // (`resolvedSystemPrompt`). Appending them on save put them
                    // into the editor the next time the sheet opened — below a
                    // footnote calling them "automatically appended" — so every
                    // edit added one more copy to the prompt.
                    var saved = profile
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
