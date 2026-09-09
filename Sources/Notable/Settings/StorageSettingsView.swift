import SwiftUI

/// Settings → Speicherplatz (issue #2).
///
/// Six weeks of use left 9.8 GB of raw meeting audio on disk and nothing ever
/// deleted any of it. This is where that gets a rule — and where the two things
/// that must *not* be deleted are stated out loud, because a cleanup screen that
/// only lists what it destroys is one nobody will trust.
struct StorageSettingsView: View {
    @AppStorage(RetentionPolicy.Key.enabled) private var enabled = false
    @AppStorage(RetentionPolicy.Key.audioAge) private var audioDays = 30
    @AppStorage(RetentionPolicy.Key.audioBudget) private var audioBudgetGB = 20
    @AppStorage(RetentionPolicy.Key.failedAge) private var failedDays = 90
    @AppStorage(RetentionPolicy.Key.dictationAge) private var dictationDays = 0
    @AppStorage(RetentionPolicy.Key.meetingAge) private var meetingDays = 0
    @AppStorage(RetentionPolicy.Key.chatAge) private var chatDays = 0
    @AppStorage(DefaultsKey.appStatistics.key) private var appStatistics = DefaultsKey.appStatistics.fallback

    @State private var footprint: StorageFootprint?
    @State private var models: [ModelInventory.Entry] = []
    @State private var compression: SpoolArchiver.Plan?
    @State private var compressionResult: SpoolArchiver.Outcome?
    @State private var isCompressing = false
    @State private var confirmModelCleanup = false
    @State private var modelCleanupErrors: [String] = []
    @State private var pending: RetentionPlanner.Plan?
    @State private var lastResult: RetentionRunner.Result?
    @State private var isWorking = false
    @State private var confirmClearApps = false
    @State private var clearedApps: Int?

    private static let ages: [(Int, LocalizedStringKey)] = [
        (0, "Aus"), (7, "7 Tage"), (30, "30 Tage"), (90, "90 Tage"), (365, "1 Jahr"),
    ]
    private static let budgets: [(Int, LocalizedStringKey)] = [
        (0, "Aus"), (5, "5 GB"), (10, "10 GB"), (20, "20 GB"), (50, "50 GB"),
    ]

    var body: some View {
        Form {
            Section {
                usageRow("Meeting-Audio", footprint?.meetingAudio, unit: Self.sessions)
                usageRow("Fehlgeschlagene Aufnahmen", footprint?.failedRecordings, unit: Self.sessions)
                usageRow("Modelle", footprint?.models, unit: Self.models(_:))
                usageRow("Datenbank", footprint?.database, unit: nil)
                LabeledContent("Gesamt") {
                    Text(footprint.map { byteText($0.total) } ?? "…").bold()
                }
            } header: {
                Text("Belegung")
            } footer: {
                Text("""
                Alle vier Posten, weil zwei davon lange keiner genannt hat — die \
                Modelle sind der größte, und sie kamen hier nie vor.
                """)
            }

            modelSection
            compressionSection

            Section {
                Toggle("Beim Start automatisch aufräumen", isOn: $enabled)
                picker("Meeting-Audio löschen nach", $audioDays, Self.ages)
                picker("Gesamtbudget für Meeting-Audio", $audioBudgetGB, Self.budgets)
                picker("Fehlgeschlagene Aufnahmen löschen nach", $failedDays, Self.ages)
            } header: {
                Text("Aufnahmen")
            } footer: {
                Text("""
                Zwei Regeln, weil eine nicht reicht: eine Frist erwischt keine einzelne \
                riesige Aufnahme, ein Budget allein bremst das stille Wachsen nicht. \
                Fehlgeschlagene Aufnahmen bekommen mehr Zeit — sie liegen dort, um von \
                Hand gerettet zu werden.
                """)
            }

            Section {
                picker("Diktattext löschen nach", $dictationDays, Self.ages)
                picker("Meeting-Transkripte löschen nach", $meetingDays, Self.ages)
                picker("Chat-Verläufe löschen nach", $chatDays, Self.ages)
            } header: {
                Text("Texte in der Datenbank")
            } footer: {
                Text("""
                Gelöscht wird der Text, nie die Zeile: die Wortzahl bleibt stehen, \
                also bleibt die Statistik danach exakt dieselbe. Standardmäßig aus.
                """)
            }

            Section {
                Toggle("Ziel-App der Diktate erfassen", isOn: $appStatistics)
                // Confirmed and counted: it is a database write with no undo,
                // and it used to give no sign that anything had happened.
                Button("Erfasste Ziel-Apps löschen") { confirmClearApps = true }
                    .buttonStyle(.link)
                    .confirmationDialog(
                        "Erfasste Ziel-Apps löschen?",
                        isPresented: $confirmClearApps
                    ) {
                        Button("Löschen", role: .destructive) { clearSourceApps() }
                        Button("Abbrechen", role: .cancel) {}
                    } message: {
                        Text("Die Zuordnung „welches Diktat ging in welche App“ geht verloren. Wortzahlen und Zeiten bleiben.")
                    }
                if let clearedApps {
                    Text("\(clearedApps) Einträge gelöscht.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("App-Statistik")
            } footer: {
                Text("Die Bundle-ID bleibt in der lokalen Datenbank und geht nie in eine Anfrage.")
            }

            Section {
                if let pending {
                    if pending.removals.isEmpty {
                        Text("Nichts aufzuräumen.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(Self.sessions(pending.removals.count)), \(byteText(pending.reclaimedBytes)) werden gelöscht.")
                        HStack {
                            Button("Endgültig löschen") { runPlan(pending) }
                                .buttonStyle(.borderedProminent)
                            Button("Abbrechen") { self.pending = nil }
                        }
                    }
                } else {
                    Button("Jetzt aufräumen…") { preview() }
                        .disabled(isWorking)
                }
                if let lastResult, lastResult.removedSessions > 0 {
                    Text("Zuletzt gelöscht: \(Self.sessions(lastResult.removedSessions)), \(byteText(lastResult.reclaimedBytes)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // A failed database clean-up used to report itself as "0
                // segments cleared" — indistinguishable from nothing to do.
                if let lastResult, !lastResult.errors.isEmpty {
                    Text("Aufräumen unvollständig: \(lastResult.errors.joined(separator: "; "))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Manuell aufräumen")
            } footer: {
                Text("""
                Was nie automatisch gelöscht wird: deine Markdown-Notizen im Notiz-Ordner, \
                die Statistik und das Kassenbuch der KI-Kosten. Aufräumen zeigt immer erst \
                den Plan.
                """)
            }
        }
        .formStyle(.grouped)
        .task { await measure() }
    }

    /// "1 Sitzung" / "4 Sitzungen" — picked, not interpolated blindly.
    ///
    /// German and English both inflect the noun, and every count here used to
    /// read "1 Sitzungen" / "1 sessions". A `.stringsdict` for three call sites
    /// is more machinery than one `== 1` deserves.
    private static func sessions(_ count: Int) -> String {
        count == 1 ? String(localized: "1 Sitzung") : String(localized: "\(count) Sitzungen")
    }

    /// "1 Modell" / "7 Modelle" — same reason as ``sessions(_:)``.
    private static func models(_ count: Int) -> String {
        count == 1 ? String(localized: "1 Modell") : String(localized: "\(count) Modelle")
    }

    @ViewBuilder
    private func usageRow(
        _ title: LocalizedStringKey,
        _ value: StorageFootprint.Item?,
        unit: ((Int) -> String)?
    ) -> some View {
        LabeledContent(title) {
            if let value {
                if let count = value.count, let unit {
                    Text("\(byteText(value.bytes)) · \(unit(count))")
                } else {
                    Text(byteText(value.bytes))
                }
            } else {
                Text("wird gemessen…").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Modelle (Spec 20)

    /// The models get rows in the section that already exists, not a tab of
    /// their own — an eighth settings tab is exactly the growth Spec 22 is
    /// written against.
    @ViewBuilder
    private var modelSection: some View {
        Section {
            if models.isEmpty {
                Text("Noch keine Modelle geladen.").foregroundStyle(.secondary)
            }
            ForEach(models) { entry in
                LabeledContent {
                    Text(byteText(entry.bytes))
                } label: {
                    Text(entry.name)
                    Text(entry.state == .incomplete && !entry.missing.isEmpty
                         ? String(localized: "unvollständig — es fehlt \(entry.missing.joined(separator: ", "))")
                         : entry.state.label)
                }
            }

            let plan = ModelInventory.removable(in: models)
            if !plan.isEmpty {
                // Same shape as the retention cleanup below: show the plan
                // first, delete only on confirmation. A gigabyte removed
                // unasked is irreversible.
                Button("\(Self.models(plan.entries.count)) entfernen (\(byteText(plan.bytes)))") {
                    confirmModelCleanup = true
                }
                .buttonStyle(.link)
                .confirmationDialog("Modellordner entfernen?", isPresented: $confirmModelCleanup) {
                    Button("Entfernen", role: .destructive) { removeModels(plan) }
                    Button("Abbrechen", role: .cancel) {}
                } message: {
                    Text("Ein unvollständiges Modell wird beim nächsten Start neu geladen. Ein verwaistes kennt kein Code-Pfad mehr.")
                }
            }
            if !modelCleanupErrors.isEmpty {
                Text("Nicht entfernt: \(modelCleanupErrors.joined(separator: "; "))")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Modelle")
        } footer: {
            Text("""
            Die Spracherkennung lädt ihre Modelle beim ersten Start von HuggingFace. \
            Welche Fassung das ist, entscheidet die eingebundene Bibliothek — benennt \
            sie ein Verzeichnis um, bleibt das alte liegen und steht hier als verwaist.
            """)
        }
    }

    // MARK: - Archiv komprimieren (Spec 21, Stufe 2)

    @ViewBuilder
    private var compressionSection: some View {
        if let compression, !compression.isEmpty {
            Section {
                Text("\(Self.sessions(compression.sessions)), \(byteText(compression.currentBytes)) → etwa \(byteText(compression.estimatedBytes)).")
                Button("Archiv jetzt umrechnen…") { compressArchive() }
                    .disabled(isCompressing)
                if isCompressing {
                    Text("Läuft — das kann bei großen Archiven dauern.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Bestand umrechnen")
            } footer: {
                Text("""
                Verlustfrei: dieselben Abtastwerte, weniger Bytes, als .m4a auch von \
                QuickTime abspielbar. Die Rohspur wird erst gelöscht, nachdem die neue \
                zurückgelesen und verglichen wurde. Neue Aufnahmen macht das von selbst.
                """)
            }
        }
        if let compressionResult, compressionResult.compressedTracks > 0 {
            Section {
                Text("\(compressionResult.compressedTracks) Spuren umgerechnet, \(byteText(compressionResult.reclaimed)) frei.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !compressionResult.failures.isEmpty {
                    Text("Nicht umgerechnet: \(compressionResult.failures.joined(separator: "; "))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func removeModels(_ plan: ModelInventory.Removal) {
        Task {
            // Off the main actor: removing a model directory is a filesystem
            // walk over up to a gigabyte, and the settings window has no
            // business freezing for it.
            modelCleanupErrors = await Task.detached { ModelInventory.remove(plan) }.value
            await measure()
        }
    }

    private func compressArchive() {
        isCompressing = true
        Task {
            compressionResult = await SpoolArchiver.compressAll(in: SpoolStore.archiveURL)
            isCompressing = false
            await measure()
        }
    }

    private func picker(_ title: LocalizedStringKey, _ binding: Binding<Int>,
                        _ options: [(Int, LocalizedStringKey)]) -> some View {
        Picker(title, selection: binding) {
            ForEach(options, id: \.0) { value, label in
                Text(label).tag(value)
            }
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Measured when the tab opens, never continuously — walking four
    /// directories of multi-gigabyte files is not something to do on a timer.
    private func measure() async {
        let engine = ASREngineID.current
        let archiveURL = SpoolStore.archiveURL
        let measured = await Task.detached {
            let models = ModelInventory.current(engine: engine)
            return (
                models,
                StorageFootprint.measure(modelEntries: models),
                SpoolArchiver.plan(in: archiveURL)
            )
        }.value
        models = measured.0
        footprint = measured.1
        compression = measured.2
        // The menu line rests on the same four numbers. Without this it would
        // still be announcing five gigabytes after they had been cleaned up.
        AppContainer.shared.storageNotice.update(with: measured.1)
    }

    private func clearSourceApps() {
        Task {
            clearedApps = (try? await RecordingStore.shared.clearSourceApps()) ?? 0
        }
    }

    private func preview() {
        isWorking = true
        Task {
            let runner = RetentionRunner(store: .shared)
            pending = await runner.plan(policy: RetentionPolicy.fromDefaults())
            isWorking = false
        }
    }

    private func runPlan(_ plan: RetentionPlanner.Plan) {
        isWorking = true
        pending = nil
        Task {
            let runner = RetentionRunner(store: .shared)
            lastResult = await runner.run(plan)
            try? await RecordingStore.shared.vacuum()
            await measure()
            isWorking = false
        }
    }
}
