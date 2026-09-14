import AppKit
import SwiftUI

/// Which app gets which polish — Spec 03 §5, finally built in Spec 31 §3.4.
///
/// The override parameter of `AppCategory.of` existed since Spec 03 and nothing
/// ever filled it, so the twenty built-in bundle ids were the whole story. This
/// shows the apps that matter — the ones the user reassigned, and the built-in
/// ones actually installed — and adds any running app from a menu, by name and
/// icon. Nobody types a bundle identifier.
struct AppCategorySection: View {
    @State private var overrides: [String: AppCategory] = AppCategory.loadOverrides()
    @State private var runningApps: [RunningApp] = []

    struct Row: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let icon: NSImage?
        let builtIn: AppCategory?
    }

    struct RunningApp: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
    }

    var body: some View {
        Section {
            ForEach(rows) { row in
                HStack(spacing: Theme.Spacing.s) {
                    if let icon = row.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                            .accessibilityHidden(true)
                    }
                    Text(row.name)
                    Spacer()
                    Picker(row.name, selection: binding(for: row)) {
                        ForEach(AppCategory.assignable, id: \.self) { category in
                            Text(category.label).tag(category)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text(category(for: row).hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)
                    if row.builtIn == nil {
                        Button {
                            overrides.removeValue(forKey: row.bundleID)
                            AppCategory.saveOverrides(overrides)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Zuordnung für \(row.name) entfernen")
                    }
                }
            }
            Menu("App hinzufügen…") {
                ForEach(addableApps) { app in
                    Button(app.name) {
                        overrides = AppCategory.assigning(.prose, to: app.bundleID, in: overrides)
                        // A new row with the default category is still a row the
                        // user asked for — keep it even though it restates `.prose`.
                        overrides[app.bundleID.lowercased()] = .prose
                        AppCategory.saveOverrides(overrides)
                    }
                }
            }
            .onAppear { runningApps = Self.loadRunningApps() }
        } header: {
            Text("Apps und Kategorien")
        } footer: {
            Text("Gilt, solange „Text an die Ziel-App anpassen“ an ist. Nicht aufgeführte Apps bekommen den Standard.")
        }
    }

    // MARK: - Rows

    private var rows: [Row] {
        let installedBuiltIns = AppCategory.defaultMapping.keys.filter { Self.appURL(for: $0) != nil }
        let ids = Set(installedBuiltIns).union(overrides.keys)
        return ids.compactMap { id in
            let url = Self.appURL(for: id)
            // An override for an app that is gone still shows, so it can be removed.
            let name = url.map { FileManager.default.displayName(atPath: $0.path) }
                .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 } ?? id
            return Row(
                bundleID: id,
                name: name,
                icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) },
                builtIn: AppCategory.defaultMapping[id]
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var addableApps: [RunningApp] {
        let shown = Set(rows.map(\.bundleID))
        return runningApps.filter { !shown.contains($0.bundleID.lowercased()) }
    }

    private func category(for row: Row) -> AppCategory {
        overrides[row.bundleID] ?? row.builtIn ?? .prose
    }

    private func binding(for row: Row) -> Binding<AppCategory> {
        Binding(
            get: { category(for: row) },
            set: { newValue in
                overrides = AppCategory.assigning(newValue, to: row.bundleID, in: overrides)
                AppCategory.saveOverrides(overrides)
            }
        )
    }

    private static func appURL(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Regular apps with a window and a bundle id, Notable itself excluded.
    private static func loadRunningApps() -> [RunningApp] {
        let own = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> RunningApp? in
            guard app.activationPolicy == .regular,
                  let id = app.bundleIdentifier, id != own,
                  let name = app.localizedName
            else { return nil }
            return RunningApp(bundleID: id, name: name)
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
