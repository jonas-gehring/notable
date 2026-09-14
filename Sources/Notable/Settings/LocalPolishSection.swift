import SwiftUI

/// The on-device text stage (Spec 32). When the model cannot run here, the
/// picker is disabled and the reason stands under it — never a switch that
/// silently does nothing.
struct LocalPolishSection: View {
    @AppStorage(LocalPolish.Mode.storageKey) private var modeRaw = LocalPolish.Mode.fallback.rawValue
    @State private var availability = LocalModelAvailability.current

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
        } header: {
            Text("Textstufe auf dem Gerät")
        } footer: {
            Text("Satzzeichen, Selbstkorrekturen und Listen mit Apples Modell auf diesem Mac. Nichts verlässt das Gerät; das Diktat braucht dafür spürbar länger.")
        }
        .onAppear { availability = LocalModelAvailability.current }
    }
}
