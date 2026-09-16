import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Allgemein

/// *Wie ist Notable eingerichtet?* (Spec 38 §3.2)
///
/// The page absorbed "Menüleiste", which was a symbol and a stepper, and grew a
/// "Mitteilungen" section so that everything Notable says unasked is decided in
/// one place instead of one switch per feature page.
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
    @AppStorage(DefaultsKey.notesFolderIcon.key) private var folderIcon = DefaultsKey.notesFolderIcon.fallback
    @AppStorage(DefaultsKey.showUsageInMenu.key) private var showUsageInMenu = DefaultsKey.showUsageInMenu.fallback
    @AppStorage(DefaultsKey.notifyOnMeetingReady.key) private var notifyOnReady = DefaultsKey.notifyOnMeetingReady.fallback
    @AppStorage(DefaultsKey.weeklyRecap.key) private var weeklyRecap = DefaultsKey.weeklyRecap.fallback
    @State private var relocationPlan: NotesFolderManager.RelocationPlan?
    @State private var relocationError: String?
    @State private var relocating = false

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
            } footer: {
                Text("„Systemsprache“ folgt der Sprachreihenfolge in den Systemeinstellungen; kennt Notable die Sprache nicht, zeigt es English.")
            }

            menuBarSection
            notificationsSection
            notesFolderSection
            updatesSection
            advancedSection
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

    // MARK: - Menüleiste

    /// What was a page of its own. The typing-speed stepper that stood here is
    /// gone from the settings entirely — it lives in the statistics window,
    /// where the number it changes is on screen while you change it.
    private var menuBarSection: some View {
        Section {
            MenuBarIconPicker()
            Toggle("Heute-Zeile im Menü", isOn: $showUsageInMenu)
        } header: {
            Text("Menüleiste")
        } footer: {
            Text("Die Heute-Zeile nennt Wörter, Meetings und gesparte Zeit und führt in die Statistik.")
        }
    }

    // MARK: - Mitteilungen

    /// One place for everything Notable says without being asked. The first
    /// switch came from the meetings page, where it sat among nine others.
    private var notificationsSection: some View {
        Section {
            Toggle("Benachrichtigen, wenn die Notiz fertig ist", isOn: $notifyOnReady)
            // Spec 37 §3.4: eine Mitteilung pro Woche, montags.
            Toggle("Wochenrückblick", isOn: $weeklyRecap)
            Text("Montags: was die vergangene Woche gebracht hat. Unter 100 Wörtern kommt keiner.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Mitteilungen")
        } footer: {
            Text("Ohne Mitteilungsrecht bleibt es still — der Status steht dann unter Daten › Berechtigungen.")
        }
    }

    // MARK: - Notizen-Ordner (Spec 27)

    /// Where the notes are, in Finder's names, and whether they reach other
    /// devices — instead of the raw path, which here read
    /// `/Users/…/Library/Mobile Documents/com~apple~CloudDocs/Codus/Meetings`.
    private var notesFolderSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(nsImage: notesFolder.icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notesFolder.readablePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(notesFolder.sync.label)
                        .font(.caption)
                        .foregroundStyle(notesFolder.sync == .iCloudDriveOff ? .red : .secondary)
                }
                Spacer()
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([notesFolder.folderURL])
                }
                .disabled(!notesFolder.exists)
                Button("Ändern…") { notesFolder.chooseFolder() }
            }
            if let error = notesFolder.lastError, notesFolder.sync != .iCloudDriveOff {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            if notesFolder.canMoveToICloudDrive {
                HStack {
                    Button("In iCloud Drive verschieben…") { relocationPlan = notesFolder.relocationPlan() }
                        .disabled(relocating)
                    if relocating { ProgressView().controlSize(.small) }
                }
            }
            if let relocationError {
                Text(relocationError).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Notizen-Ordner")
        } footer: {
            Text("Jede Meeting-Notiz landet hier als Markdown-Datei.")
        }
        // The plan first, like the cleanup: what moves, and where to.
        .confirmationDialog("Notizen in iCloud Drive verschieben?", isPresented: relocationBinding, presenting: relocationPlan) { plan in
            Button("Verschieben") { relocate(plan) }
            Button("Abbrechen", role: .cancel) {}
        } message: { plan in
            Text("\(plan.noteCount) Notizen und \(plan.folderCount) Ordner ziehen nach iCloud Drive › \(plan.target.lastPathComponent). Gespeicherte Pfade werden mitgeführt.")
        }
    }

    private var relocationBinding: Binding<Bool> {
        Binding(get: { relocationPlan != nil }, set: { if !$0 { relocationPlan = nil } })
    }

    /// Never while a note may be written into the folder being moved.
    private func relocate(_ plan: NotesFolderManager.RelocationPlan) {
        guard AppContainer.shared.meeting.state == .idle else {
            relocationError = String(localized: "Während eines Meetings oder einer Notiz in Arbeit wird nichts verschoben.")
            return
        }
        relocating = true
        relocationError = nil
        Task {
            do {
                try await notesFolder.relocate(plan)
                await AppContainer.shared.notes.reload()
            } catch {
                relocationError = error.localizedDescription
            }
            relocating = false
        }
    }

    // MARK: - Updates

    /// **One** switch since Spec 38. There were two, and the first one governed
    /// the second: without "suchen" there is nothing to install, so "installieren"
    /// implies it. Searching happens either way and the menu says so when it
    /// finds something; `updateAutomaticChecks` is still read
    /// (`UpdateChecker.automaticChecks`), it simply has no checkbox any more.
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
                // Why it has not installed itself yet (Spec 25 §3.8) — waiting
                // used to be silent, which read as "there is no updater".
                if let reason = updateInstaller.waitReason,
                   updateInstaller.prepared?.versionString == update.versionString,
                   updateInstaller.phase == .idle {
                    Text("\(update.versionString) wartet auf einen ruhigen Moment — gerade: \(reason.label).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
            if let last = UpdateMarkers.lastUpdate() {
                LabeledContent("Zuletzt aktualisiert") {
                    Text(lastUpdateLabel(last)).foregroundStyle(.secondary)
                }
                // Where the "aktualisiert" notification leads: what changed.
                if updateChecker.available == nil, !last.notes.isEmpty {
                    DisclosureGroup("Neu in \(last.version)") {
                        Text(ReleaseNotes.attributed(last.notes))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Toggle("Updates automatisch installieren", isOn: $automaticInstall)
        } header: {
            Text("Updates")
        } footer: {
            Text("Installiert wird im nächsten ruhigen Moment — nie während einer Aufnahme, eines Diktats oder offener Notizen.")
        }
    }

    @ViewBuilder
    private func installRow(_ update: UpdateInfo) -> some View {
        switch updateInstaller.phase {
        case .downloading:
            DownloadProgressRow(fraction: updateInstaller.downloadProgress)
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

    private func statusRow(_ text: LocalizedStringKey) -> some View {
        HStack {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }

    // MARK: - Erweitert

    /// The one folded group on this page (Spec 33 rule 1): a cosmetic mark on a
    /// folder, the tour, and the restart that TCC grants need.
    private var advancedSection: some View {
        Section {
            DisclosureGroup("Erweitert") {
                Toggle("Symbol am Notizen-Ordner", isOn: $folderIcon)
                    .onChange(of: folderIcon) { _, _ in notesFolder.applyIcon() }
                Text("Kommt nur auf Ordner ohne eigenes Symbol.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Einführung zeigen") {
                    openWindow(id: "onboarding")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Notable neu starten") { relaunch() }
                Text("Eingabeüberwachung und Bedienungshilfen werden erst nach einem Neustart grün.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var currentVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private func lastUpdateLabel(_ record: UpdateMarkers.Record) -> String {
        let how = record.unattended ? String(localized: "automatisch") : String(localized: "von Hand")
        return "\(record.version) · " + record.at.formatted(date: .abbreviated, time: .shortened) + " — " + how
    }

    private var lastCheckedLabel: String {
        guard let date = updateChecker.lastChecked else { return String(localized: "Noch nicht geprüft") }
        return "Zuletzt: " + date.formatted(date: .abbreviated, time: .shortened)
    }
}
