import SwiftUI

/// The rows of the KI section that concern the on-request LLM pass
/// (issue #1 Stufe 2), inside ``AISection`` since Spec 38.
///
/// **The switch is the consent.** The spec asked for a one-time confirmation
/// dialog on the first use; a dialog plus a setting says the same thing twice,
/// and the setting is the one that can be revoked later. The sentence the
/// dialog would have carried is the KI section's footer.
///
/// Three controls went away here (Spec 38 §3.2):
///
/// - **Dienst** — a second picker for a question the summarization provider
///   already answers. Derived now (`DictationEnhancer.resolvedProviderID`),
///   with `dictationEnhanceProvider` still read so whoever set it keeps it.
///   The line under the toggle names the provider, so the rule that the
///   destination is stated at the point of choosing survives the picker.
/// - **Zeitbudget** — a slider over a number the code knows
///   (`EnhancementSettings.fixedDeadlineSeconds`).
/// - The **status row and CLI arguments** moved to Meetings › Erweitert, where
///   the provider is chosen.
struct EnhancementRows: View {
    @AppStorage(EnhancementSettings.enabledKey) private var enabled = false
    @AppStorage(EnhancementSettings.hotkeyKey) private var hotkeyRaw = ""
    @AppStorage(EnhancementSettings.profileKey) private var profileID = ""
    @AppStorage(DefaultsKey.summarizationProvider.key) private var summarizationRaw = DefaultsKey.summarizationProvider.fallback

    @State private var customProfiles: [EnhancementProfile] = EnhancementProfile.custom()
    @State private var editing: EnhancementProfile?
    @State private var pendingDeletion: EnhancementProfile?

    /// The tag that opens the editor instead of selecting anything.
    private static let newProfileTag = "__eigenes__"

    let onHotkeyChange: () -> Void

    /// Which CLI this would use right now. Re-derived on every body evaluation,
    /// so changing the summarization provider one page over is visible here
    /// without a refresh.
    private var providerLabel: String {
        DictationEnhancer.resolvedProviderID(summarization: summarizationRaw).label
    }

    var body: some View {
        // The editor and the delete confirmation hang off the first row: these
        // are loose `Form` rows, not a container, so there is nothing else to
        // attach them to — and a presentation modifier works from any view in
        // the hierarchy.
        Toggle("Verbesserung auf Abruf erlauben", isOn: $enabled)
            .onChange(of: enabled) { _, _ in onHotkeyChange() }
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

        if enabled {
            // Where the text goes, named at the point of choosing — the one
            // thing the removed "Dienst" picker was carrying.
            Text("Text geht an: \(providerLabel) — aus Meetings › Zusammenfassung.")
                .font(.caption)
                .foregroundStyle(.secondary)

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

            Picker("Profil", selection: profileSelection) {
                Text("Automatisch nach Ziel-App").tag("")
                ForEach(EnhancementProfile.builtIn + customProfiles) { profile in
                    Text(profile.title).tag(profile.id)
                }
                Divider()
                Text("Eigenes…").tag(Self.newProfileTag)
            }

            // Only for profiles someone wrote: a prompt with no way to change
            // or remove it is worse than one more row.
            ForEach(customProfiles) { profile in
                HStack {
                    Text(profile.title).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Bearbeiten") { editing = profile }
                        .buttonStyle(.link)
                    Button("Löschen", role: .destructive) { pendingDeletion = profile }
                        .buttonStyle(.link)
                }
            }
        }
    }

    /// The picker writes the profile id, except for the sentinel, which opens
    /// the editor and leaves the selection where it was.
    private var profileSelection: Binding<String> {
        Binding(
            get: { profileID },
            set: { chosen in
                guard chosen != Self.newProfileTag else {
                    editing = EnhancementProfile(id: UUID().uuidString, title: "", systemPrompt: "", isCustom: true)
                    return
                }
                profileID = chosen
            }
        )
    }
}

/// The prompt editor. A profile is a prompt someone wrote, so deleting one is
/// confirmed and editing one never rewrites what they typed.
struct ProfileEditor: View {
    @State var profile: EnhancementProfile
    let onSave: (EnhancementProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Verbesserungs-Profil")
                .font(.headline)
            Form {
                TextField("Titel", text: $profile.title, prompt: Text("Protokollstil"))
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Anweisung an das Modell")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $profile.systemPrompt)
                        .frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).stroke(.separator))
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
        .padding(Theme.Spacing.l)
        .frame(width: 480)
    }
}
