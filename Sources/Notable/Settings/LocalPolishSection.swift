import SwiftUI

/// Diktat › **KI** (Spec 38 §3.2).
///
/// Two sections became one. "Textstufe auf dem Gerät" and "Textverbesserung"
/// were two headings, two toggles, five pickers, a slider and a text field for
/// what is one question with a privacy order inside it: *may a model touch this
/// text, and where does it run?* The order is the section itself — the local
/// model first, because nothing leaves the device for it, then the on-request
/// pass, which does.
struct AISection: View {
    @AppStorage(LocalPolish.Mode.storageKey) private var modeRaw = LocalPolish.Mode.fallback.rawValue
    @State private var availability = LocalModelAvailability.current

    let onHotkeyChange: () -> Void

    var body: some View {
        Section {
            Picker("Lokal formatieren", selection: $modeRaw) {
                ForEach(LocalPolish.Mode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .disabled(!availability.isAvailable)
            .onChange(of: modeRaw) { _, _ in
                AppContainer.shared.dictation.localPolishModeChanged()
            }
            if let reason = availability.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            EnhancementRows(onHotkeyChange: onHotkeyChange)
        } header: {
            Text("KI")
        } footer: {
            Text("""
            „Lokal formatieren“ läuft mit Apples Modell auf diesem Mac — Satzzeichen, \
            Selbstkorrekturen, Listen. Nichts verlässt dabei das Gerät.

            Die Verbesserung auf Abruf ist das Gegenteil und sagt es ohne Beschönigung: \
            eingeschaltet geht der Text pro Diktat, nur wenn du es auslöst, an den Anbieter \
            der gewählten CLI. Lokal ist daran nur, dass der Prozess auf deinem Rechner \
            startet, und die Abrechnung — der Text selbst geht ins Netz. Der bezahlte \
            API-Schlüssel wird dafür nie benutzt, auch nicht, wenn er für Meetings \
            eingestellt ist. Jeder Lauf wird gezählt, damit nachzählbar bleibt, wie oft das \
            passiert ist. Audio verlässt das Gerät weiterhin nie.
            """)
        }
        .onAppear { availability = LocalModelAvailability.current }
    }
}

/// Diktat › Erweitert: the consent for everything that reads the target app
/// (Spec 32 Stufe 2) — context for the local stage, commands on a selection,
/// learning from corrections. Local in all three; off until switched on.
///
/// It sits under "Erweitert" rather than over the fold because it is a consent
/// nobody should find by accident, and everybody should be able to find.
struct TargetTextRows: View {
    @AppStorage(LocalPolish.readsTargetTextKey) private var readsTargetText = false
    @AppStorage(LocalPolish.commandHotkeyKey) private var commandHotkeyRaw = ""

    var body: some View {
        Toggle("Text aus der Ziel-App lesen (lokal)", isOn: $readsTargetText)
            .onChange(of: readsTargetText) { _, _ in
                AppContainer.shared.dictation.hotkeyChanged()
            }
        if readsTargetText {
            Picker("Befehl-Taste", selection: $commandHotkeyRaw) {
                Text("Keine").tag("")
                ForEach(HotkeySpec.allCases.filter { $0 != HotkeySpec.current && $0 != EnhancementSettings.hotkey() }) { spec in
                    Text(spec.label).tag(spec.rawValue)
                }
            }
            .onChange(of: commandHotkeyRaw) { _, _ in
                AppContainer.shared.dictation.hotkeyChanged()
            }
        }
        Text("Erlaubt Befehle auf markiertem Text und gibt der lokalen Textstufe Kontext. Nie in Passwortfeldern, nichts wird gespeichert, nichts verlässt das Gerät.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
