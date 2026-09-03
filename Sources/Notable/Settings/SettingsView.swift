import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    /// The six settings sections, shown in a native `NavigationSplitView` sidebar
    /// (resizable, standard macOS System-Settings look). Earlier this was a
    /// hand-rolled top tab bar to dodge `TabView`'s titlebar-overflow inside a
    /// plain `Window`; the sidebar is more native and never crowds long labels.
    enum Section: String, CaseIterable, Identifiable {
        case general, dictation, meetings, menubar, summary, storage, permissions
        var id: String { rawValue }

        var label: String {
            let key: String.LocalizationValue = switch self {
            case .general: "Allgemein"
            case .dictation: "Diktat"
            case .meetings: "Meetings"
            case .menubar: "Menüleiste"
            case .summary: "Zusammenfassung"
            case .storage: "Speicherplatz"
            case .permissions: "Berechtigungen"
            }
            return String(localized: key)
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .dictation: "mic"
            case .meetings: "person.2.wave.2"
            case .menubar: "menubar.rectangle"
            case .summary: "text.justify.left"
            case .storage: "internaldrive"
            case .permissions: "lock.shield"
            }
        }
    }

    @State private var selection: Section? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Section.allCases) { section in
                    Label(section.label, systemImage: section.icon)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            content
                .navigationTitle((selection ?? .general).label)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch selection ?? .general {
        case .general: GeneralSettingsView()
        case .dictation: DictationSettingsView()
        case .meetings: MeetingsSettingsView()
        case .menubar: IconSettingsView()
        case .summary: SummarizationSettingsView()
        case .storage: StorageSettingsView()
        case .permissions: PermissionsSettingsView()
        }
    }
}

// MARK: - Menüleiste

struct IconSettingsView: View {
    @AppStorage("showUsageInMenu") private var showUsageInMenu = true
    @AppStorage("typingWPM") private var typingWPM = 40.0

    var body: some View {
        Form {
            Section {
                IconPickerView()
            } header: {
                Text("Menüleisten-Symbol")
            }

            Section {
                Toggle("Statistik im Menü anzeigen", isOn: $showUsageInMenu)
                Stepper(value: $typingWPM, in: 20...120, step: 5) {
                    LabeledContent("Tippgeschwindigkeit", value: "\(Int(typingWPM)) WPM")
                }
                .disabled(!showUsageInMenu)
                // The line is computed, not stored — recompute it when the
                // assumption behind "gespart" changes.
                .onChange(of: typingWPM) { _, _ in AppContainer.shared.usage.refreshSoon() }
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

// MARK: - Allgemein

struct GeneralSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var notesFolder: NotesFolderManager
    @EnvironmentObject private var updateChecker: UpdateChecker
    @EnvironmentObject private var updateInstaller: UpdateInstaller
    @State private var launchAtLogin = false
    @State private var loginItemError: String?
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.system.rawValue
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

    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

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
            Toggle("Beim Start automatisch nach Updates suchen", isOn: automaticChecks)
        } header: {
            Text("Updates")
        } footer: {
            Text("Prüft GitHub-Releases, höchstens einmal am Tag. „Installieren“ lädt die neue Version, ersetzt Notable in /Applications und startet neu.")
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

// MARK: - Diktat

struct DictationSettingsView: View {
    @EnvironmentObject private var dictation: DictationController
    @AppStorage(HotkeySpec.storageKey) private var hotkeyRaw = HotkeySpec.rightOption.rawValue
    @AppStorage("polishRemoveFillers") private var removeFillers = true
    @AppStorage("polishApplyITN") private var applyITN = true
    @AppStorage("polishParagraphs") private var paragraphs = true
    @AppStorage("polishStructureCommands") private var structureCommands = true
    @AppStorage("polishFuzzyDictionary") private var fuzzyDictionary = true
    @AppStorage("appContextFormatting") private var appContextFormatting = true
    @AppStorage("dictationSounds") private var dictationSounds = false
    @AppStorage("dictationIdleTimeout") private var dictationIdleTimeout = 0.0
    @AppStorage(Paster.Method.storageKey) private var pasteMethodRaw = Paster.Method.pasteboard.rawValue
    @AppStorage(ASREngineID.storageKey) private var engineRaw = ASREngineID.parakeetV3.rawValue
    @AppStorage(WhisperModelSize.storageKey) private var whisperSizeRaw = WhisperModelSize.base.rawValue
    @AppStorage(OverlayStyle.storageKey) private var overlayStyleRaw = OverlayStyle.bottom.rawValue
    @AppStorage("bootstrapModel") private var bootstrapModel = true
    @AppStorage(MediaInterrupter.Key.pausePlayback) private var pauseMedia = false
    @AppStorage(MediaInterrupter.Key.muteOutput) private var muteOutput = false
    @State private var history: [(date: Date, text: String, rawText: String?)] = []
    @State private var dictionary: [String: String] = PersonalDictionary.load()
    @State private var suggestions: [String: String] = PersonalDictionary.learnedSuggestions()
    @State private var newWrong = ""
    @State private var newRight = ""

    var body: some View {
        Form {
            Section {
                Picker("Push-to-talk-Taste", selection: $hotkeyRaw) {
                    ForEach(HotkeySpec.allCases) { spec in
                        Text(spec.label).tag(spec.rawValue)
                    }
                }
                .onChange(of: hotkeyRaw) { _, _ in
                    dictation.hotkeyChanged()
                }
                Picker("ASR-Engine", selection: $engineRaw) {
                    ForEach(ASREngineID.allCases) { engine in
                        Text(engine.label).tag(engine.rawValue)
                    }
                }
                .onChange(of: engineRaw) { _, _ in
                    dictation.engineChanged()
                }
                // Status where the choice is made: what a switch costs, and
                // whether the thing is even loaded, used to be visible only as a
                // line in the menu bar — the one place you are not looking when
                // you change the engine.
                EngineStatusRow(dictation: dictation)
                if engineRaw == ASREngineID.whisper.rawValue {
                    Picker("Whisper-Modell", selection: $whisperSizeRaw) {
                        ForEach(WhisperModelSize.allCases) { size in
                            Text(size.label).tag(size.rawValue)
                        }
                    }
                    .onChange(of: whisperSizeRaw) { _, _ in
                        dictation.whisperModelChanged()
                    }
                }
                Picker("Einfügemethode", selection: $pasteMethodRaw) {
                    Text("Zwischenablage (⌘V, Standard)").tag("pasteboard")
                    Text("Tastatureingabe simulieren").tag("typing")
                }
                Picker("Anzeige während der Aufnahme", selection: $overlayStyleRaw) {
                    ForEach(OverlayStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                Toggle("Beim ersten Start ein kleines Modell vorschalten", isOn: $bootstrapModel)
                Toggle("Wiedergabe während des Diktats pausieren", isOn: $pauseMedia)
                Toggle("Systemton während des Diktats stummschalten", isOn: $muteOutput)
                SpokenLanguagesRow()
            } footer: {
                Text("Halten = Push-to-talk, kurzer Tap = freihändig. Unified: live, nur Englisch. Whisper: mehrsprachig, Modell lädt beim ersten Mal.")
            }

            Section {
                Toggle("Füllwörter entfernen (ähm, äh …)", isOn: $removeFillers)
                Toggle("Zahlen & Daten formatieren (nur Englisch)", isOn: $applyITN)
                Toggle("Absätze setzen", isOn: $paragraphs)
                Toggle("Gesprochene Struktur umsetzen", isOn: $structureCommands)
            } header: {
                Text("Textqualität")
            } footer: {
                Text("Absätze: alle drei Sätze ein Umbruch, nie mitten im Satz — ohne das kommt ein langes Diktat als eine einzige Zeile an. Struktur: „neue Zeile“, „neuer Absatz“ und „Stichpunkt“ werden ausgeführt statt geschrieben, „erstens … zweitens“ wird zur nummerierten Liste (ab zwei Ordnungszahlen, damit ein einzelnes „erstens“ Prosa bleibt). In Code-Editoren passiert beides nicht.")
            }

            Section {
                Toggle("Text an die Ziel-App anpassen", isOn: $appContextFormatting)
            } header: {
                Text("App-Anpassung")
            } footer: {
                Text("Passt Ton und Format an die App an, in die du diktierst: locker in Chats (Slack, Messages), Satzpunkt in E-Mail, wörtlich in Code-Editoren (Xcode, Terminal). Läuft vollständig lokal.")
            }

            Section {
                Toggle("Töne bei Aufnahme-Start und -Ende", isOn: $dictationSounds)
                Stepper(value: $dictationIdleTimeout, in: 0...30, step: 5) {
                    Text(dictationIdleTimeout == 0
                        ? String(localized: "Freihändig bei Stille beenden: aus")
                        : "Freihändig nach \(Int(dictationIdleTimeout)) s Stille beenden")
                }
            } header: {
                Text("Verhalten")
            } footer: {
                Text("Der Idle-Timeout gilt nur für den freihändigen Lock-Modus (kurzer Tap), nicht für gehaltenes Push-to-talk.")
            }

            Section {
                if dictionary.isEmpty {
                    Text("Keine Einträge.")
                        .foregroundStyle(.secondary)
                }
                ForEach(dictionary.keys.sorted(), id: \.self) { wrong in
                    HStack {
                        Text(wrong)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        Text(dictionary[wrong] ?? "")
                        Spacer()
                        Button {
                            dictionary.removeValue(forKey: wrong)
                            PersonalDictionary.save(dictionary)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Eintrag \(wrong) entfernen")
                    }
                }
                HStack {
                    TextField("gehört als …", text: $newWrong)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("ersetzen durch …", text: $newRight)
                    Button {
                        let wrong = newWrong.trimmingCharacters(in: .whitespaces)
                        let right = newRight.trimmingCharacters(in: .whitespaces)
                        guard !wrong.isEmpty, !right.isEmpty else { return }
                        dictionary[wrong] = right
                        PersonalDictionary.save(dictionary)
                        newWrong = ""
                        newRight = ""
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Eintrag hinzufügen")
                }
                Toggle("Ähnliche Schreibweisen automatisch korrigieren", isOn: $fuzzyDictionary)
            } header: {
                Text("Persönliches Wörterbuch")
            }

            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions.keys.sorted(), id: \.self) { heard in
                        HStack {
                            Text(heard)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(suggestions[heard] ?? "")
                            Spacer()
                            Button("Übernehmen") {
                                if let corrected = suggestions[heard] {
                                    PersonalDictionary.promote(heard: heard, corrected: corrected)
                                    dictionary = PersonalDictionary.load()
                                    suggestions = PersonalDictionary.learnedSuggestions()
                                }
                            }
                            .buttonStyle(.link)
                            Button("Verwerfen") {
                                PersonalDictionary.dismiss(heard: heard)
                                suggestions = PersonalDictionary.learnedSuggestions()
                            }
                            .buttonStyle(.link)
                        }
                    }
                } header: {
                    Text("Gelernte Vorschläge")
                } footer: {
                    Text("Aus deinen Korrekturen unter Letzte Diktate gelernt. Übernehmen fügt den Eintrag oben ins Wörterbuch ein.")
                }
            }

            if let latency = dictation.lastLatencyMillis {
                Section("Leistung") {
                    LabeledContent(
                        String(localized: "Letzte Latenz (Loslassen → Einfügen)"),
                        value: String(format: "%d ms bei %.1f s Audio", latency, dictation.lastAudioSeconds ?? 0)
                    )
                }
            }

            EnhancementSettingsSection(onHotkeyChange: { dictation.hotkeyChanged() })

            SmartReplaceSection()

            Section("Letzte Diktate") {
                if history.isEmpty {
                    Text("Noch keine Diktate.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(history.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                // Marks the dictations whose text left the
                                // device, and keeps the original readable —
                                // otherwise nobody could tell what the model did.
                                if let rawText = entry.rawText {
                                    Label("verbessert", systemImage: "wand.and.stars")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .help("Original: \(rawText)")
                                }
                            }
                            Text(entry.text)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: dictation.lastLatencyMillis) {
            history = (try? await RecordingStore.shared.recentDictations(limit: 8)) ?? []
        }
    }
}

// MARK: - Meetings

struct MeetingsSettingsView: View {
    @AppStorage("autoRecordMeetings") private var autoRecord = true
    @AppStorage("notifyOnMeetingReady") private var notifyOnReady = true
    @AppStorage("speakerNamingEnabled") private var speakerNaming = true
    @AppStorage("meetingEchoCancellation") private var echoCancellation = false
    @AppStorage("meetingUseDictationEngine") private var useDictationEngine = false
    @AppStorage(ASREngineID.storageKey) private var engineRaw = ASREngineID.parakeetV3.rawValue
    @AppStorage("showNextMeeting") private var showNextMeeting = true
    @AppStorage("openNotesOnMeetingStart") private var openNotesOnStart = true
    @AppStorage("meetingNotesFloating") private var notesFloating = true
    @AppStorage("meetingHookPath") private var meetingHookPath = ""

    /// Which engine a meeting will actually use given the toggle — Unified can't
    /// batch-transcribe, so it resolves to Parakeet v3.
    private var effectiveMeetingEngineLabel: String {
        guard useDictationEngine else { return "Parakeet v3" }
        switch ASREngineID(rawValue: engineRaw) ?? .parakeetV3 {
        case .parakeetV3: return "Parakeet v3"
        case .unifiedEnglish: return String(localized: "Parakeet v3 (Unified ist nur fürs Diktat)")
        case .whisper: return "Whisper"
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Erkannte Calls anbieten", isOn: $autoRecord)
                Toggle("Benachrichtigen, wenn die Notiz fertig ist", isOn: $notifyOnReady)
            } footer: {
                Text("Sobald Zoom, Teams, Webex, FaceTime, Slack oder ein Browser-Call das Mikrofon öffnet, meldet sich Notable per Benachrichtigung: »Aufnehmen«, »Immer für diese App« oder »Später«. Aufgezeichnet wird erst nach »Aufnehmen«. Endet der Call, stoppt die Aufnahme automatisch, die Notiz wird erzeugt und zusammengefasst. Ohne Benachrichtigungsrecht erscheint stattdessen ein kleines Fenster oben rechts.")
            }

            Section {
                Toggle("Sprecher anhand genannter Namen benennen", isOn: $speakerNaming)
            }

            Section {
                Toggle("Echo-Unterdrückung im Meeting (VPIO)", isOn: $echoCancellation)
            } footer: {
                Text("Standard: aus. Verhindert, dass die Gegenseite über die Lautsprecher zurück ins Mikrofon läuft (bei Kopfhörern unnötig). Nur einschalten, wenn du ohne Kopfhörer aufnimmst und die Gegenseite doppelt im Transkript landet — VPIO war die Ursache leerer Transkripte und wird nur mit diesem Schalter aktiv.")
            }

            Section {
                Toggle("Meetings mit dem gewählten Diktat-Modell transkribieren", isOn: $useDictationEngine)
                LabeledContent("Modell für Meetings", value: effectiveMeetingEngineLabel)
            } header: {
                Text("Transkriptionsmodell")
            } footer: {
                Text("Standard: aus → Meetings nutzen immer Parakeet v3 (am genauesten, mehrsprachig). An: Meetings folgen dem ASR-Motor aus den Diktat-Einstellungen. Parakeet Unified ist Streaming-only und für Meetings nicht nutzbar — dann wird auf Parakeet v3 zurückgefallen.")
            }

            Section {
                Toggle("Nächstes Meeting in der Menüleiste zeigen", isOn: $showNextMeeting)
            }

            Section {
                Toggle("Notizfenster beim Meeting-Start öffnen", isOn: $openNotesOnStart)
                Toggle("Notizfenster immer im Vordergrund", isOn: $notesFloating)
            } header: {
                Text("Notizen während des Calls")
            } footer: {
                Text("Das Notizfenster (⇧⌘N) begleitet die laufende Aufnahme: ⌘T setzt die Laufzeit als Zeitstempel, die Diktattaste funktioniert auch dort hinein. Beim Beenden landen die Notizen wörtlich als „Eigene Notizen“ in der Notiz im Inbox-Ordner und gehen als Grundwahrheit in die Zusammenfassung ein. Das Fenster öffnet sich, ohne den Call in den Hintergrund zu schieben.")
            }

            Section {
                if meetingHookPath.isEmpty {
                    Text("Kein Skript gewählt").foregroundStyle(.secondary)
                } else {
                    Text(meetingHookPath).font(.callout).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button("Skript wählen…") { chooseHookScript() }
                    if !meetingHookPath.isEmpty {
                        Button("Entfernen", role: .destructive) { meetingHookPath = "" }
                    }
                }
            } header: {
                Text("Skript nach Meeting-Ende")
            } footer: {
                Text("Wird nach jeder fertigen Meeting-Notiz ausgeführt und bekommt den Pfad der Markdown-Datei als Argument — z. B. um sie nach Obsidian zu kopieren oder einen Webhook auszulösen.")
            }

            RememberedConsentSection()
        }
        .formStyle(.grouped)
    }

    private func chooseHookScript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Skript wählen, das nach jedem fertigen Meeting läuft")
        if panel.runModal() == .OK, let url = panel.url {
            meetingHookPath = url.path
        }
    }
}

/// Lists the per-source "Immer/Nie" decisions the consent prompt remembered,
/// with a reset that re-enables the prompt for that source.
private struct RememberedConsentSection: View {
    @State private var decisions: [(key: String, decision: MeetingConsentDecision)] = []

    var body: some View {
        Section("Gemerkte Entscheidungen pro App") {
            if decisions.isEmpty {
                Text("Noch keine gemerkten Entscheidungen pro Quelle.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(decisions, id: \.key) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(displayName(for: entry.key))
                            Text(entry.decision == .always ? "Immer aufnehmen" : "Nie aufnehmen")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Zurücksetzen") {
                            MeetingConsentStore.forget(entry.key)
                            reload()
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        decisions = MeetingConsentStore.all()
            .map { (key: $0.key, decision: $0.value) }
            .sorted { $0.key < $1.key }
    }

    private func displayName(for key: String) -> String {
        switch key {
        case "us.zoom.xos": return "Zoom"
        case "com.microsoft.teams2", "com.microsoft.teams": return "Microsoft Teams"
        case "com.apple.FaceTime": return "FaceTime"
        case "Cisco-Systems.Spark", "com.webex.meetingmanager": return "Webex"
        case "com.tinyspeck.slackmacgap": return "Slack"
        case "web:google-meet": return "Google Meet (Browser)"
        case "web:zoom": return "Zoom (Browser)"
        case "web:teams": return "Microsoft Teams (Browser)"
        default: return key
        }
    }
}

// MARK: - Zusammenfassung


struct SummarizationSettingsView: View {
    @AppStorage("summarizationProvider") private var providerRaw = SummarizationProviderID.anthropicAPI.rawValue

    @State private var apiKeyInput = ""
    @State private var apiKeyStored = false
    @State private var keyTestResult: String?
    @State private var cliPath: String?

    private var provider: SummarizationProviderID {
        SummarizationProviderID(rawValue: providerRaw) ?? .anthropicAPI
    }

    var body: some View {
        Form {
            Section {
                Picker("Zusammenfassung über", selection: $providerRaw) {
                    ForEach(SummarizationProviderID.allCases) { provider in
                        Text(provider.label).tag(provider.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            if provider == .anthropicAPI {
                Section("Anthropic API") {
                    SecureField("API-Key", text: $apiKeyInput, prompt: Text("sk-ant-…"))
                    HStack {
                        Button("Im Schlüsselbund sichern") {
                            let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            apiKeyStored = KeychainStore.write(trimmed, account: KeychainStore.anthropicAPIKeyAccount)
                            // Only drop the typed key once it is safely stored —
                            // a failed write used to clear the field and leave
                            // the user with nothing but "Kein Key hinterlegt".
                            if apiKeyStored {
                                apiKeyInput = ""
                                keyTestResult = nil
                            } else {
                                keyTestResult = String(localized: "Schlüsselbund-Zugriff fehlgeschlagen — Key nicht gesichert.")
                            }
                        }
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if apiKeyStored {
                            Label("Key im Schlüsselbund hinterlegt", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button("Entfernen", role: .destructive) {
                                KeychainStore.delete(account: KeychainStore.anthropicAPIKeyAccount)
                                apiKeyStored = false
                            }
                        } else {
                            Label("Kein Key hinterlegt", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if apiKeyStored {
                        HStack {
                            Button("Verbindung testen") {
                                keyTestResult = String(localized: "Prüfe…")
                                Task { keyTestResult = await AnthropicAPIProvider.validateKey() }
                            }
                            if let keyTestResult {
                                Text(keyTestResult)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Modell: claude-sonnet-5. Der Key wird ausschließlich im macOS-Schlüsselbund gespeichert.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if provider == .claudeCodeCLI {
                Section("Anthropic Claude Code CLI (Abo)") {
                    if let cliPath {
                        Label("CLI gefunden: \(cliPath)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Claude Code CLI nicht gefunden", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    Text("Nutzt die lokal installierte, eingeloggte CLI — ohne API-Schlüssel. Aufrufe zählen auf dein Abo-Kontingent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apiKeyStored = KeychainStore.read(account: KeychainStore.anthropicAPIKeyAccount) != nil
            cliPath = ClaudeCodeCLILocator.locate()
        }
    }
}

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
                Text("Alle fünf werden gebraucht. Fehlt eine, meldet das jeweilige Feature es und arbeitet eingeschränkt weiter.")
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
    /// TCC grants macOS caches per-process (screen recording, input monitoring).
    private static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

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
