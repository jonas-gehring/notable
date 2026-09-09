import SwiftUI

// MARK: - Menüleiste

struct MenuBarSettingsView: View {
    @AppStorage(DefaultsKey.showUsageInMenu.key) private var showUsageInMenu = DefaultsKey.showUsageInMenu.fallback

    var body: some View {
        Form {
            Section {
                IconPickerView()
            } header: {
                Text("Menüleisten-Symbol")
            }

            Section {
                Toggle("Statistik im Menü anzeigen", isOn: $showUsageInMenu)
                TypingSpeedStepper()
                    .disabled(!showUsageInMenu)
            } header: {
                Text("Statistik")
            } footer: {
                Text("Zeigt die heutigen Zahlen direkt im Menü — Wörter, Meetings und die gegenüber dem Tippen gesparte Zeit. An Tagen ohne Aktivität bleibt die Zeile weg.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
