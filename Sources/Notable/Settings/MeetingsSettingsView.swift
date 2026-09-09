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
