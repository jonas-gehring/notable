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
                Text("Wörter, Meetings und gesparte Zeit von heute, direkt im Menü.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
