import AppKit
import SwiftUI

// MARK: - Meetings

struct MeetingsSettingsView: View {
    @AppStorage(DefaultsKey.autoRecordMeetings.key) private var autoRecord = DefaultsKey.autoRecordMeetings.fallback
    @AppStorage(DefaultsKey.notifyOnMeetingReady.key) private var notifyOnReady = DefaultsKey.notifyOnMeetingReady.fallback
    @AppStorage(DefaultsKey.speakerNamingEnabled.key) private var speakerNaming = DefaultsKey.speakerNamingEnabled.fallback
    @AppStorage(DefaultsKey.meetingEchoCancellation.key) private var echoCancellation = DefaultsKey.meetingEchoCancellation.fallback
    @AppStorage(DefaultsKey.meetingUseDictationEngine.key) private var useDictationEngine = DefaultsKey.meetingUseDictationEngine.fallback
    @AppStorage(ASREngineID.storageKey) private var engineRaw = ASREngineID.parakeetV3.rawValue
    @AppStorage(DefaultsKey.showNextMeeting.key) private var showNextMeeting = DefaultsKey.showNextMeeting.fallback
    @AppStorage(DefaultsKey.openNotesOnMeetingStart.key) private var openNotesOnStart = DefaultsKey.openNotesOnMeetingStart.fallback
    @AppStorage(DefaultsKey.meetingNotesFloating.key) private var notesFloating = DefaultsKey.meetingNotesFloating.fallback
    @AppStorage(DefaultsKey.meetingHookPath.key) private var meetingHookPath = DefaultsKey.meetingHookPath.fallback
    @AppStorage(DefaultsKey.inputDeviceUID.key) private var inputDeviceUID = DefaultsKey.inputDeviceUID.fallback
    @AppStorage(DefaultsKey.lastMeetingInputDevice.key) private var lastInputDevice = DefaultsKey.lastMeetingInputDevice.fallback
    @State private var inputDevices: [AudioDeviceInfo] = []
    @AppStorage(DefaultsKey.screenSpeakerRecognition.key) private var screenSpeakers = DefaultsKey.screenSpeakerRecognition.fallback
    @AppStorage(DefaultsKey.ownerName.key) private var ownerName = DefaultsKey.ownerName.fallback
    @State private var probeMessage: String?

    /// Stufe 0 of Spec 24: one text dump of the running call's window.
    private func probe() {
        probeMessage = ScreenProbe.probeRunningCall().message
    }

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
                Toggle("Sprecher anhand genannter Namen benennen", isOn: $speakerNaming)
                // Spec 24: the call shows who takes part and who is speaking.
                Toggle("Sprecher am Bildschirm erkennen", isOn: $screenSpeakers)
                // Spec 35: macOS often knows only the first name, and then
                // "Herr Gehring" is not recognised as the owner's own name.
                TextField("Dein vollständiger Name", text: $ownerName, prompt: Text(verbatim: NSFullUserName()))
            } header: {
                Text("Sprecher")
            } footer: {
                Text("Liest während einer Aufnahme nur Namen aus dem Call-Fenster, nie ein Bild.")
            }

            Section {
                Toggle("Echo unterdrücken", isOn: $echoCancellation)
            } footer: {
                Text("Nur einschalten, wenn du ohne Kopfhörer aufnimmst und die Gegenseite doppelt im Transkript landet.")
            }

            Section {
                Toggle("Meetings mit dem gewählten Diktat-Modell transkribieren", isOn: $useDictationEngine)
                LabeledContent("Modell für Meetings", value: effectiveMeetingEngineLabel)
            } header: {
                Text("Transkriptionsmodell")
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
                Text("⌘T setzt einen Zeitstempel; die Notizen landen wörtlich in der Meeting-Notiz.")
            }

            // Measuring and scripting, one level down (Spec 33 §3.1): the probe
            // is a harness for Spec 24's Stufe 0, the hook a power-user escape.
            Section {
                DisclosureGroup("Erweitert") {
                    LabeledContent("Sprechererkennung: unterstützte Apps") {
                        Text(CallScreenAdapters.all.isEmpty
                             ? String(localized: "noch keine — erst messen")
                             : CallScreenAdapters.all.flatMap(\.bundleIDPrefixes).joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Call-Fenster jetzt auslesen") { probe() }
                        if let probeMessage {
                            Text(probeMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Text("Schreibt den Aufbau des laufenden Call-Fensters als Text in die Logs.")
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

            CalendarVisibilitySection()
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
