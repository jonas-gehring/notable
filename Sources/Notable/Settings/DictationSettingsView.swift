import SwiftUI

// MARK: - Diktat

struct DictationSettingsView: View {
    @EnvironmentObject private var dictation: DictationController
    @AppStorage(HotkeySpec.storageKey) private var hotkeyRaw = HotkeySpec.rightOption.rawValue
    @AppStorage(DefaultsKey.polishRemoveFillers.key) private var removeFillers = DefaultsKey.polishRemoveFillers.fallback
    @AppStorage(DefaultsKey.polishApplyITN.key) private var applyITN = DefaultsKey.polishApplyITN.fallback
    @AppStorage(DefaultsKey.polishParagraphs.key) private var paragraphs = DefaultsKey.polishParagraphs.fallback
    @AppStorage(DefaultsKey.polishStructureCommands.key) private var structureCommands = DefaultsKey.polishStructureCommands.fallback
    @AppStorage(DefaultsKey.polishFuzzyDictionary.key) private var fuzzyDictionary = DefaultsKey.polishFuzzyDictionary.fallback
    @AppStorage(DefaultsKey.appContextFormatting.key) private var appContextFormatting = DefaultsKey.appContextFormatting.fallback
    @AppStorage(DefaultsKey.dictationSounds.key) private var dictationSounds = DefaultsKey.dictationSounds.fallback
    @AppStorage(DefaultsKey.dictationIdleTimeout.key) private var dictationIdleTimeout = DefaultsKey.dictationIdleTimeout.fallback
    @AppStorage(Paster.Method.storageKey) private var pasteMethodRaw = Paster.Method.pasteboard.rawValue
    @AppStorage(ASREngineID.storageKey) private var engineRaw = ASREngineID.parakeetV3.rawValue
    @AppStorage(WhisperModelSize.storageKey) private var whisperSizeRaw = WhisperModelSize.base.rawValue
    @AppStorage(OverlayStyle.storageKey) private var overlayStyleRaw = OverlayStyle.bottom.rawValue
    @AppStorage(DefaultsKey.bootstrapModel.key) private var bootstrapModel = DefaultsKey.bootstrapModel.fallback
    @AppStorage(MediaInterrupter.Key.pausePlayback) private var pauseMedia = false
    @AppStorage(MediaInterrupter.Key.muteOutput) private var muteOutput = false
    @State private var history: [RecordingStore.ActivityItem] = []
    @State private var dictionary: [String: String] = PersonalDictionary.load()
    @State private var suggestions: [String: String] = PersonalDictionary.learnedSuggestions()
    @State private var newWrong = ""
    @State private var newRight = ""

    var body: some View {
        Form {
            Section {
                // Symmetric to the enhancement picker: a key cannot hold both
                // roles, so the one already taken by "Diktat mit Verbesserung"
                // is not offered here either.
                Picker("Push-to-talk-Taste", selection: $hotkeyRaw) {
                    ForEach(HotkeySpec.allCases.filter { $0 != EnhancementSettings.hotkey() }) { spec in
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
                        : String(localized: "Freihändig nach \(Int(dictationIdleTimeout)) s Stille beenden"))
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
                        // Not `String(format:)`: `%.1f` formats with a C locale,
                        // so a German window printed "1.5 s" where every other
                        // number on the pane reads "1,5 s".
                        value: String(localized: """
                        \(latency) ms bei \(dictation.lastAudioSeconds ?? 0, format: .number.precision(.fractionLength(1))) s Audio
                        """)
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
                    // The same list as the "Letzte Diktate" window, just
                    // shorter — including Kopieren and Korrigieren, which this
                    // section used to be missing for no stated reason.
                    RecentDictationsList(items: history, compact: true)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: dictation.lastLatencyMillis) {
            history = (try? await RecordingStore.shared.recentActivity(
                kind: .dictation, within: 0, limit: 8
            )) ?? []
        }
    }
}
