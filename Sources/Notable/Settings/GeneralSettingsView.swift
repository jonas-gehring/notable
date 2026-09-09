import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Allgemein

struct GeneralSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var notesFolder: NotesFolderManager
    @EnvironmentObject private var updateChecker: UpdateChecker
    @EnvironmentObject private var updateInstaller: UpdateInstaller
    @State private var launchAtLogin = false
    @State private var loginItemError: String?
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.system.rawValue
    @AppStorage(UpdateInstaller.automaticInstallKey) private var automaticInstall = true
    @State private var showRelaunchHint = false

    var body: some View {
        Form {
            Section {
                Picker("Sprache", selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                if showRelaunchHint {
                    HStack {
                        Text("Wirkt nach einem Neustart von Notable.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Jetzt neu starten") { relaunch() }
                    }
                }
            } footer: {
                Text("„Systemsprache“ folgt der Sprachreihenfolge in den Systemeinstellungen; kennt Notable die Sprache nicht, zeigt es English.")
            }

            Section {
                LabeledContent("Notizen-Ordner") {
                    HStack {
                        Text(notesFolder.folderURL.path)
                            .truncationMode(.middle)
                            .lineLimit(1)
                        Button("Ändern…") {
                            notesFolder.chooseFolder()
                        }
                    }
                }
            }

            Section {
                Toggle("Bei Anmeldung starten", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginItemError = nil
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            loginItemError = error.localizedDescription
                        }
                    }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("Einführung zeigen") {
                    openWindow(id: "onboarding")
                    NSApp.activate(ignoringOtherApps: true)
                }
            } footer: {
                Text("Öffnet die Willkommens-Tour mit Hotkey-Erklärung und Berechtigungen.")
            }

            updatesSection
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// Writing the choice is not enough — the bundle resolves its string tables
    /// once per process, so a switch only becomes visible after a relaunch. The
    /// hint appears the moment the picker changes and says so, instead of leaving
    /// the user to wonder why nothing happened.
    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: languageRaw) ?? .system },
            set: { language in
                guard language.rawValue != languageRaw else { return }
                AppLanguage.apply(language)
                languageRaw = language.rawValue
                showRelaunchHint = true
            }
        )
    }

    private func relaunch() { AppRelauncher.relaunch() }

    @ViewBuilder
    private var updatesSection: some View {
        Section {
            if let update = updateChecker.available {
                LabeledContent("Neue Version") {
                    Text(update.versionString).foregroundStyle(Theme.accent)
                }
                if !update.notes.isEmpty {
                    // Scrolls rather than truncates: cutting the notes at six lines
                    // hid exactly the part that says what changed.
                    ScrollView {
                        Text(ReleaseNotes.attributed(update.notes))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                installRow(update)
            } else {
                LabeledContent("Aktuelle Version") {
                    Text(currentVersionString).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Nach Updates suchen") {
                        Task { await updateChecker.check() }
                    }
                    .disabled(updateChecker.isChecking)
                    if updateChecker.isChecking {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Text(lastCheckedLabel).font(.caption).foregroundStyle(.secondary)
                }
                if let error = updateChecker.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            Toggle("Automatisch nach Updates suchen", isOn: automaticChecks)
            Toggle("Updates automatisch installieren", isOn: $automaticInstall)
                .disabled(!updateChecker.automaticChecks)
        } header: {
            Text("Updates")
        } footer: {
            Text("""
            Prüft GitHub-Releases beim Start und dann alle sechs Stunden. Automatisch \
            installiert wird nur, wenn nichts dabei verloren geht: kein laufendes Meeting, \
            kein offenes Notable-Fenster. Vorher wird die Signatur des Downloads geprüft — \
            eine fremd signierte Datei wird nie installiert. Danach startet Notable neu; \
            das dauert etwa eine Sekunde.
            """)
        }
    }

    /// `UpdateChecker.automaticChecks` reads and writes UserDefaults directly, so
    /// the binding goes through the object rather than a second `@AppStorage` that
    /// could drift out of sync with it.
    private var automaticChecks: Binding<Bool> {
        Binding(
            get: { updateChecker.automaticChecks },
            set: { updateChecker.automaticChecks = $0 }
        )
    }

    @ViewBuilder
    private func installRow(_ update: UpdateInfo) -> some View {
        switch updateInstaller.phase {
        case .downloading:
            if let fraction = updateInstaller.downloadProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: fraction)
                    Text("Wird geladen — \(Int(fraction * 100)) %")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                statusRow("Wird geladen…")
            }
        case .unpacking:
            statusRow("Wird entpackt…")
        case .installing:
            statusRow("Wird installiert, Neustart folgt…")
        case let .failed(message):
            Text("Fehlgeschlagen: \(message)").font(.callout).foregroundStyle(.red)
            Button("Erneut versuchen") { Task { await updateInstaller.installAndRelaunch(update) } }
        case .idle:
            HStack {
                Button("Installieren & neu starten") {
                    Task { await updateInstaller.installAndRelaunch(update) }
                }
                .buttonStyle(.borderedProminent)
                // Per-version, not a blanket mute: whoever does not want *this*
                // build should still hear about the next one.
                Button("Diese Version überspringen") { updateChecker.skip(update) }
            }
        }
    }

    private func statusRow(_ text: String) -> some View {
        HStack {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var currentVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var lastCheckedLabel: String {
        guard let date = updateChecker.lastChecked else { return String(localized: "Noch nicht geprüft") }
        return "Zuletzt: " + date.formatted(date: .abbreviated, time: .shortened)
    }
}
