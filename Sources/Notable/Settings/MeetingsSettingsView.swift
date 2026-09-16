import AppKit
import SwiftUI

// MARK: - Meetings

/// *Wie werden Calls aufgenommen und was wird daraus?* (Spec 38 §3.2)
///
/// The page absorbed "Zusammenfassung" — summarizing is what happens to a
/// meeting after it stops — and folded the echo switch, the transcription model
/// and the measuring tools into its one "Erweitert" group.
struct MeetingsSettingsView: View {
    @AppStorage(DefaultsKey.autoRecordMeetings.key) private var autoRecord = DefaultsKey.autoRecordMeetings.fallback
    @AppStorage(DefaultsKey.speakerNamingEnabled.key) private var speakerNaming = DefaultsKey.speakerNamingEnabled.fallback
    @AppStorage(DefaultsKey.screenSpeakerRecognition.key) private var screenSpeakers = DefaultsKey.screenSpeakerRecognition.fallback
    @AppStorage(DefaultsKey.meetingEchoCancellation.key) private var echoCancellation = DefaultsKey.meetingEchoCancellation.fallback
    @AppStorage(DefaultsKey.meetingUseDictationEngine.key) private var useDictationEngine = DefaultsKey.meetingUseDictationEngine.fallback
    @AppStorage(ASREngineID.storageKey) private var engineRaw = ASREngineID.parakeetV3.rawValue
    @AppStorage(DefaultsKey.showNextMeeting.key) private var showNextMeeting = DefaultsKey.showNextMeeting.fallback
    @AppStorage(DefaultsKey.openNotesOnMeetingStart.key) private var openNotesOnStart = DefaultsKey.openNotesOnMeetingStart.fallback
    @AppStorage(DefaultsKey.meetingHookPath.key) private var meetingHookPath = DefaultsKey.meetingHookPath.fallback
    @AppStorage(DefaultsKey.inputDeviceUID.key) private var inputDeviceUID = DefaultsKey.inputDeviceUID.fallback
    @AppStorage(DefaultsKey.lastMeetingInputDevice.key) private var lastInputDevice = DefaultsKey.lastMeetingInputDevice.fallback
    @AppStorage(DefaultsKey.ownerName.key) private var ownerName = DefaultsKey.ownerName.fallback
    @AppStorage(DefaultsKey.summarizationProvider.key) private var summarizationRaw = DefaultsKey.summarizationProvider.fallback
    @State private var inputDevices: [AudioDeviceInfo] = []
    /// What the automatic measurement has written so far (Spec 36 §3.1).
    @State private var probeFiles: [(url: URL, modified: Date)] = []

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

    /// Two toggles, one question with a privacy order inside it (§3.1 rule 2).
    /// The pure mapping is `SpeakerNamingMode`.
    private var namingMode: Binding<SpeakerNamingMode> {
        Binding(
            get: { SpeakerNamingMode(namesFromConversation: speakerNaming, readsScreen: screenSpeakers) },
            set: { mode in
                speakerNaming = mode.namesFromConversation
                screenSpeakers = mode.readsScreen
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Erkannte Calls anbieten", isOn: $autoRecord)
                Toggle("Nächstes Meeting in der Menüleiste zeigen", isOn: $showNextMeeting)
            } footer: {
                Text("Notable fragt, sobald ein Call das Mikrofon öffnet, und nimmt erst nach „Aufnehmen“ auf.")
            }

            Section {
                Picker("Eingabegerät", selection: $inputDeviceUID) {
                    Text("Automatisch").tag("")
                    ForEach(inputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if !inputDeviceUID.isEmpty, !inputDevices.contains(where: { $0.uid == inputDeviceUID }) {
                        Text("Festgelegtes Gerät (nicht verbunden)").tag(inputDeviceUID)
                    }
                }
                if !lastInputDevice.isEmpty {
                    LabeledContent("Zuletzt aufgenommen von", value: lastInputDevice)
                }
            } header: {
                Text("Mikrofon")
            } footer: {
                Text("Automatisch nimmt das Gerät, das der Call benutzt — gilt auch fürs Diktat.")
            }
            .onAppear {
                inputDevices = AudioDevices.inputDevices().filter { $0.transport != .aggregate }
            }

            Section {
                Picker("Sprecher benennen", selection: namingMode) {
                    ForEach(SpeakerNamingMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text(namingMode.wrappedValue.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Spec 35: macOS often knows only the first name, and then
                // "Herr Gehring" is not recognised as the owner's own name.
                TextField("Dein vollständiger Name", text: $ownerName, prompt: Text(verbatim: NSFullUserName()))
            } header: {
                Text("Sprecher")
            } footer: {
                Text("Vom Bildschirm wird nur gelesen, wer im Call-Fenster steht — nie ein Bild.")
            }

            VoiceProfilesSection()

            Section {
                Toggle("Notizfenster beim Meeting-Start öffnen", isOn: $openNotesOnStart)
            } header: {
                Text("Notizen im Call")
            } footer: {
                Text("⌘T setzt einen Zeitstempel; die Notizen landen wörtlich in der Meeting-Notiz.")
            }

            SummarizationSection()
            CalendarVisibilitySection()
            RememberedConsentSection()
            advancedSection
        }
        .formStyle(.grouped)
        .onAppear { probeFiles = ScreenProbe.files() }
    }

    // MARK: - Erweitert

    /// The one folded group on this page: a switch the code genuinely cannot
    /// decide, a model override, and the measuring and scripting tools.
    ///
    /// **Echo suppression stays a switch** (§3.1 rule 1, the exception): whether
    /// VPIO mutes the input graph on *this* Mac is not something the code can
    /// know — that was the July post-mortem, where it silenced whole meetings.
    /// It is simply not a question everyone has to be asked.
    private var advancedSection: some View {
        Section {
            DisclosureGroup("Erweitert") {
                Toggle("Echo unterdrücken", isOn: $echoCancellation)
                Text("Nur einschalten, wenn du ohne Kopfhörer aufnimmst und die Gegenseite doppelt im Transkript landet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Meetings mit dem gewählten Diktat-Modell transkribieren", isOn: $useDictationEngine)
                LabeledContent("Modell für Meetings", value: effectiveMeetingEngineLabel)

                if let cli = SummarizationProviderID(rawValue: summarizationRaw), cli.isCLI {
                    CLIArgumentsRow(provider: cli)
                }

                LabeledContent("Sprechererkennung: unterstützte Apps") {
                    Text(CallScreenAdapters.all.isEmpty
                         ? String(localized: "noch keine — erst messen")
                         : CallScreenAdapters.all.flatMap(\.bundleIDPrefixes).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
                // The button is gone (Spec 36 §3.1): it asked for a press in the
                // middle of a call, and in five weeks nobody pressed it. The
                // measurement happens by itself now; what is left is the row
                // that says what it wrote, and what is in it.
                LabeledContent("Bildschirm-Messungen") {
                    Text("\(probeFiles.count) Dateien").foregroundStyle(.secondary)
                }
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting(probeFiles.map(\.url))
                }
                .disabled(probeFiles.isEmpty)
                Text("Beim ersten Call je App und Version schreibt Notable den Aufbau des Call-Fensters als Text in die Logs — darin stehen die Namen aus dem Call-Fenster. Bleibt lokal, wird nach 30 Tagen gelöscht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Skript nach Meeting-Ende") {
                    if meetingHookPath.isEmpty {
                        Text("Kein Skript gewählt").foregroundStyle(.secondary)
                    } else {
                        Text(meetingHookPath).lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack {
                    Button("Skript wählen…") { chooseHookScript() }
                    if !meetingHookPath.isEmpty {
                        Button("Entfernen", role: .destructive) { meetingHookPath = "" }
                    }
                }
                Text("Bekommt nach jeder fertigen Meeting-Notiz den Pfad der Markdown-Datei.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

/// The voices Notable has remembered (Spec 36, Stufe 3).
///
/// **Off in the default, decided 2026-09-16.** An embedding cannot be turned
/// back into audio, but it is still a biometric feature of another person lying
/// on this Mac — and a new class of data deserves a deliberate switching-on,
/// not a switch someone finds later. The footer says what happens in one
/// sentence, the list shows every profile, and "Vergessen" removes one for good.
/// Removing a profile leaves the notes exactly as they are: the name that was
/// applied is a fact about that meeting.
private struct VoiceProfilesSection: View {
    @AppStorage(DefaultsKey.voiceProfilesEnabled.key) private var enabled = DefaultsKey.voiceProfilesEnabled.fallback
    @State private var profiles: [VoiceProfiles.Profile] = []

    var body: some View {
        Section {
            Toggle("Stimmen wiedererkennen", isOn: $enabled)
            if enabled {
                if profiles.isEmpty {
                    EmptyState("Noch keine Stimme gemerkt.")
                }
                ForEach(profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: profile.name)
                            Text("aus \(profile.meetings) Meetings")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Vergessen") { forget(profile) }
                    }
                }
            }
        } header: {
            Text("Stimmen")
        } footer: {
            Text("Notable merkt sich, wie benannte Sprecher klingen, um sie im nächsten Meeting zu erkennen. Bleibt auf diesem Mac. Wie zuverlässig das trifft, ist noch nicht vermessen — im Zweifel bleibt es bei „Sprecher 1“.")
        }
        .task(id: enabled) { await reload() }
    }

    private func reload() async {
        profiles = (try? await RecordingStore.shared.voiceProfiles()) ?? []
    }

    private func forget(_ profile: VoiceProfiles.Profile) {
        Task {
            try? await RecordingStore.shared.forgetVoiceProfile(id: profile.id)
            await reload()
        }
    }
}

/// Which calendars Notable sees, with today's events in each (Spec 35) — the
/// question behind every note that matched no event. A calendar that lives only
/// in Outlook or the Teams app never reaches EventKit and never appears here.
private struct CalendarVisibilitySection: View {
    @State private var calendars: [CalendarMonitor.VisibleCalendar]?

    var body: some View {
        Section {
            if let calendars {
                if calendars.isEmpty {
                    Text("Keine Kalender gefunden.").foregroundStyle(.secondary)
                }
                ForEach(calendars) { calendar in
                    LabeledContent {
                        Text("\(calendar.eventsToday) heute")
                    } label: {
                        Text(verbatim: calendar.title)
                        Text(verbatim: calendar.account)
                    }
                }
            } else {
                Text("Kein Kalenderzugriff — Notable kann Meetings keinem Termin zuordnen.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Kalender")
        } footer: {
            Text("Fehlt dein Arbeitskalender, füge das Konto unter Systemeinstellungen → Internetaccounts hinzu.")
        }
        .onAppear { calendars = AppContainer.shared.calendar.visibleCalendars() }
    }
}

/// Lists the per-source "Immer/Nie" decisions the consent prompt remembered,
/// with a reset that re-enables the prompt for that source.
private struct RememberedConsentSection: View {
    @State private var decisions: [(key: String, decision: MeetingConsentDecision)] = []

    var body: some View {
        Section("Gemerkte Entscheidungen pro App") {
            if decisions.isEmpty {
                EmptyState("Noch keine gemerkten Entscheidungen pro Quelle.")
            } else {
                ForEach(decisions, id: \.key) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(MeetingApps.displayName(for: entry.key))
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
}

extension ScreenProbe {
    /// Writes the running call window's Accessibility tree and reveals the file.
    /// One entry for Settings and for the ⌥ alternative in the menu (Spec 33 §3.1).
    @MainActor
    @discardableResult
    static func probeRunningCall() -> (succeeded: Bool, message: String?) {
        guard let call = AppContainer.shared.detector.callProcess else {
            return (false, ProbeError.noCallApp.errorDescription)
        }
        do {
            let url = try dump(bundleIDs: call.processBundleIDs, callName: call.sourceName)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return (true, url.lastPathComponent)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
