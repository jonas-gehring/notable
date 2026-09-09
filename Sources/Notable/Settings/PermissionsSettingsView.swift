import SwiftUI

// MARK: - Berechtigungen

struct PermissionsSettingsView: View {
    @EnvironmentObject private var permissions: PermissionsManager

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                ForEach(PermissionsManager.Kind.allCases) { kind in
                    permissionRow(kind)
                }
            } footer: {
                // No count: there were six kinds behind a sentence claiming
                // five, and the onboarding said next door that only the
                // microphone is required. Both cannot be true, and the number
                // was the part that had to go.
                Text("Zwingend ist nur das Mikrofon. Fehlt eine der anderen, meldet das jeweilige Feature es und arbeitet eingeschränkt weiter.")
            }

            Section {
                HStack {
                    Button("Status aktualisieren") { permissions.refresh() }
                    Button("Notable neu starten") { Self.relaunch() }
                }
            } footer: {
                Text("Eingabeüberwachung und Bedienungshilfen werden erst nach einem Neustart grün. Die Systemaudio-Aufnahme lässt sich nicht auslesen — macOS fragt sie beim ersten Mitschnitt ab. Häkchen bleiben über Updates erhalten.")
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
        .onReceive(refreshTimer) { _ in permissions.refresh() }
    }

    /// Relaunch a fresh instance, then quit this one — the only way to pick up
    /// TCC grants macOS caches per-process (input monitoring, accessibility).
    private static func relaunch() { AppRelauncher.relaunch() }

    @ViewBuilder
    private func permissionRow(_ kind: PermissionsManager.Kind) -> some View {
        let status = permissions.status(of: kind)
        HStack(alignment: .top) {
            Image(systemName: status.symbolName)
                .foregroundStyle(status.color)
                .accessibilityLabel(status.label)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.name)
                Text(kind.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if permissions.canPrompt(kind) {
                Button("Erlauben") {
                    Task { await permissions.request(kind) }
                }
            } else {
                Button("Systemeinstellungen…") {
                    permissions.openSystemSettings(for: kind)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
