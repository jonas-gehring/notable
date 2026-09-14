import SwiftUI

/// The on-device text stage (Spec 32). When the model cannot run here, the
/// picker is disabled and the reason stands under it — never a switch that
/// silently does nothing.
struct LocalPolishSection: View {
    @AppStorage(LocalPolish.Mode.storageKey) private var modeRaw = LocalPolish.Mode.fallback.rawValue
    @State private var availability = LocalModelAvailability.current
    @AppStorage(LocalPolish.readsTargetTextKey) private var readsTargetText = false
    @AppStorage(LocalPolish.commandHotkeyKey) private var commandHotkeyRaw = ""

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
            // The consent for everything that reads the target app (Stufe 2):
            // context for the stage above, commands on a selection, learning
            // from corrections. Local in all three; off until switched on.
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
        } header: {
            Text("Textstufe auf dem Gerät")
        } footer: {
            Text("Mit Apples Modell auf diesem Mac: Satzzeichen, Selbstkorrekturen, Listen — und mit Lesen auch Befehle auf markiertem Text. Nichts verlässt das Gerät.")
        }
        .onAppear { availability = LocalModelAvailability.current }
    }
}
