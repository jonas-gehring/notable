import SwiftUI

// MARK: - Diktat

/// The page in the order of Spec 33 §3.2: key, recognition, text, dictionary and
/// building blocks, display and sound, and the repair tools folded away.
struct DictationSettingsView: View {
    @EnvironmentObject private var dictation: DictationController
    @AppStorage(HotkeySpec.storageKey) private var hotkeyRaw = HotkeySpec.rightOption.rawValue
    @AppStorage(DefaultsKey.polishFuzzyDictionary.key) private var fuzzyDictionary = DefaultsKey.polishFuzzyDictionary.fallback
    @AppStorage(DefaultsKey.dictationSounds.key) private var dictationSounds = DefaultsKey.dictationSounds.fallback
    @AppStorage(DefaultsKey.dictationIdleTimeout.key) private var dictationIdleTimeout = DefaultsKey.dictationIdleTimeout.fallback
    @AppStorage(Paster.Method.storageKey) private var pasteMethodRaw = Paster.Method.pasteboard.rawValue
    @AppStorage(ASREngineID.storageKey) private var engineRaw = ASREngineID.parakeetV3.rawValue
    @AppStorage(WhisperModelSize.storageKey) private var whisperSizeRaw = WhisperModelSize.base.rawValue
    @AppStorage(OverlayStyle.storageKey) private var overlayStyleRaw = OverlayStyle.bottom.rawValue
    @AppStorage(DefaultsKey.bootstrapModel.key) private var bootstrapModel = DefaultsKey.bootstrapModel.fallback
    @AppStorage(MediaInterrupter.Key.pausePlayback) private var pauseMedia = false
    @AppStorage(MediaInterrupter.Key.muteOutput) private var muteOutput = false
    @State private var dictionary: [String: String] = PersonalDictionary.load()
    @State private var suggestions: [String: String] = PersonalDictionary.learnedSuggestions()
    @State private var newWrong = ""
    @State private var newRight = ""

    /// Hands-free on silence as a switch (Spec 33 §3.1 rule 3); the number sits
    /// under "Erweitert" for whoever wants another one.
    private var endsOnSilence: Binding<Bool> {
        Binding(
            get: { dictationIdleTimeout > 0 },
            set: { on in
                let standard = DefaultsKey.dictationIdleTimeout.fallback
                dictationIdleTimeout = on ? (standard > 0 ? standard : 30) : 0
            }
        )
    }

    var body: some View {
        Form {
            Section {
                // Symmetric to the enhancement picker: a key cannot hold both
                // roles, so the one already taken by "Diktat mit Verbesserung"
                // is not offered here either.
                Picker("Push-to-talk-Taste", selection: $hotkeyRaw) {
                    ForEach(HotkeySpec.allCases.filter { $0 != EnhancementSettings.hotkey() && $0 != LocalPolish.commandHotkey() }) { spec in
                        Text(spec.label).tag(spec.rawValue)
                    }
                }
                .onChange(of: hotkeyRaw) { _, _ in
                    dictation.hotkeyChanged()
                }
                Toggle("Freihändig bei Stille beenden", isOn: endsOnSilence)
            } header: {
                Text("Taste")
            } footer: {
                Text("Halten = Push-to-talk, kurzer Tap = freihändig.")
            }

            Section {
                Picker("Erkennung", selection: $engineRaw) {
                    ForEach(ASREngineID.allCases) { engine in
                        Text(engine.label).tag(engine.rawValue)
                    }
                }
                .onChange(of: engineRaw) { _, _ in
                    dictation.engineChanged()
                }
                // Status where the choice is made: what a switch costs, and
                // whether the thing is even loaded.
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
                SpokenLanguagesRow()
            } header: {
                Text("Erkennung")
            } footer: {
                Text("„Englisch — schnell“ versteht nur Englisch; Whisper lädt sein Modell beim ersten Mal.")
            }

            TextPreparationSection()

            LocalPolishSection()

            EnhancementSettingsSection(onHotkeyChange: { dictation.hotkeyChanged() })

            Section {
                if dictionary.isEmpty {
                    EmptyState("Keine Einträge.")
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
                Text("Wörterbuch & Bausteine")
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
                    Text("Aus deinen Korrekturen gelernt — in „Letzte Diktate“ und, wenn Lesen erlaubt ist, im Zielfeld.")
                }
            }

            SmartReplaceSection()

            Section {
                Picker("Anzeige während der Aufnahme", selection: $overlayStyleRaw) {
                    ForEach(OverlayStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                Toggle("Töne bei Aufnahme-Start und -Ende", isOn: $dictationSounds)
                Toggle("Wiedergabe während des Diktats pausieren", isOn: $pauseMedia)
                Toggle("Systemton während des Diktats stummschalten", isOn: $muteOutput)
            } header: {
                Text("Anzeige & Ton")
            }

            // Repair tools and a measurement, one level down (Spec 33 §3.1).
            Section {
                DisclosureGroup("Erweitert") {
                    Picker("Einfügemethode", selection: $pasteMethodRaw) {
                        Text("Zwischenablage (⌘V, Standard)").tag("pasteboard")
                        Text("Tastatureingabe simulieren").tag("typing")
                    }
                    Toggle("Beim ersten Start ein kleines Modell vorschalten", isOn: $bootstrapModel)
                    if dictationIdleTimeout > 0 {
                        Stepper(value: $dictationIdleTimeout, in: 15...120, step: 15) {
                            Text("Freihändig nach \(Int(dictationIdleTimeout)) s Stille beenden")
                        }
                    }
                    if let latency = dictation.lastLatencyMillis {
                        LabeledContent(
                            String(localized: "Letzte Latenz (Loslassen → Einfügen)"),
                            // Not `String(format:)`: `%.1f` formats with a C locale.
                            value: String(localized: """
                            \(latency) ms bei \(dictation.lastAudioSeconds ?? 0, format: .number.precision(.fractionLength(1))) s Audio
                            """)
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One switch for the rule stage (Spec 33 §3.2): fillers, numbers, paragraphs,
/// spoken structure and the target app are *one* thing to most people. The five
/// switches stay — in a sheet, for whoever wants one of them off.
struct TextPreparationSection: View {
    @AppStorage(DefaultsKey.polishRemoveFillers.key) private var removeFillers = DefaultsKey.polishRemoveFillers.fallback
    @AppStorage(DefaultsKey.polishApplyITN.key) private var applyITN = DefaultsKey.polishApplyITN.fallback
    @AppStorage(DefaultsKey.polishParagraphs.key) private var paragraphs = DefaultsKey.polishParagraphs.fallback
    @AppStorage(DefaultsKey.polishStructureCommands.key) private var structureCommands = DefaultsKey.polishStructureCommands.fallback
    @AppStorage(DefaultsKey.appContextFormatting.key) private var appContextFormatting = DefaultsKey.appContextFormatting.fallback
    @State private var showsDetails = false

    private var switches: [Bool] { [removeFillers, applyITN, paragraphs, structureCommands, appContextFormatting] }

    private var all: Binding<Bool> {
        Binding(
            get: { switches.allSatisfy { $0 } },
            set: { on in
                removeFillers = on
                applyITN = on
                paragraphs = on
                structureCommands = on
                appContextFormatting = on
            }
        )
    }

    var body: some View {
        Section {
            Toggle("Text aufbereiten", isOn: all)
            HStack {
                if switches.contains(true), switches.contains(false) {
                    Text("Angepasst")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Anpassen…") { showsDetails = true }
            }
        } header: {
            Text("Text")
        } footer: {
            Text("Füllwörter, Zahlen, Absätze, gesprochene Struktur und die Ziel-App — nie in Code-Editoren.")
        }
        .sheet(isPresented: $showsDetails) {
            TextPreparationSheet()
        }
    }
}

private struct TextPreparationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DefaultsKey.polishRemoveFillers.key) private var removeFillers = DefaultsKey.polishRemoveFillers.fallback
    @AppStorage(DefaultsKey.polishApplyITN.key) private var applyITN = DefaultsKey.polishApplyITN.fallback
    @AppStorage(DefaultsKey.polishParagraphs.key) private var paragraphs = DefaultsKey.polishParagraphs.fallback
    @AppStorage(DefaultsKey.polishStructureCommands.key) private var structureCommands = DefaultsKey.polishStructureCommands.fallback
    @AppStorage(DefaultsKey.appContextFormatting.key) private var appContextFormatting = DefaultsKey.appContextFormatting.fallback

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Füllwörter entfernen (ähm, äh …)", isOn: $removeFillers)
                    Toggle("Zahlen & Daten formatieren", isOn: $applyITN)
                    Toggle("Absätze setzen", isOn: $paragraphs)
                    Toggle("Gesprochene Struktur umsetzen", isOn: $structureCommands)
                } header: {
                    Text("Textqualität")
                } footer: {
                    Text("Absätze und gesprochene Befehle wie „neue Zeile“ oder „Stichpunkt“ — nie in Code-Editoren.")
                }
                Section {
                    Toggle("Text an die Ziel-App anpassen", isOn: $appContextFormatting)
                } header: {
                    Text("App-Anpassung")
                } footer: {
                    Text("Locker in Chats, Schlusspunkt in Mails, wörtlich in Code-Editoren.")
                }
                if appContextFormatting {
                    AppCategorySection()
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.l)
        }
        .frame(minWidth: 460, minHeight: 420)
    }
}
