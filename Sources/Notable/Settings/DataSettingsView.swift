import SwiftUI

/// Settings → **Daten**: *Was weiß Notable, was behält es, was darf es?*
///
/// One page out of two (Spec 38 §3.2). "Speicherplatz" and "Berechtigungen"
/// were separate pages answering one question between them, and neither could
/// be read without the other: what is on the disk, how long it stays, what is
/// recorded about you, and which rights make any of it possible.
///
/// The retention half is where six weeks of use left 9.8 GB of raw meeting
/// audio with nothing ever deleting it (issue #2). Six pickers asked about that
/// in six ways; one asks now, and the two things that must **not** be deleted
/// are still stated out loud, because a cleanup screen that only lists what it
/// destroys is one nobody will trust.
struct DataSettingsView: View {
    @EnvironmentObject private var permissions: PermissionsManager

    @AppStorage(RetentionPolicy.Key.enabled) private var enabled = false
    @AppStorage(RetentionPolicy.Key.audioAge) private var audioDays = RetentionPolicy.default.audioMaxAgeDays ?? 30
    @AppStorage(RetentionPolicy.Key.audioBudget) private var audioBudgetGB = RetentionPolicy.defaultBudgetGigabytes
    @AppStorage(RetentionPolicy.Key.failedAge) private var failedDays = RetentionPolicy.default.failedMaxAgeDays ?? 60
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

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private static let ages: [(Int, LocalizedStringKey)] = [
        (0, "Aus"), (7, "7 Tage"), (30, "30 Tage"), (90, "90 Tage"), (365, "1 Jahr"),
    ]
    private static let budgets: [(Int, LocalizedStringKey)] = [
        (0, "Aus"), (5, "5 GB"), (10, "10 GB"), (20, "20 GB"), (50, "50 GB"),
    ]

    /// The one retention control. `AudioRetentionChoice` holds the pure half —
    /// including what a hand-set number that is none of the five reads as.
    private var audioChoice: Binding<AudioRetentionChoice> {
        Binding(
            get: { AudioRetentionChoice.nearest(days: audioDays) },
            set: { audioDays = $0.rawValue }
        )
    }

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
                Text("Alles, was Notable auf die Platte legt.")
            }

            retentionSection
            statisticsSection
            permissionsSection
            modelSection
            compressionSection
            manualCleanupSection
            advancedSection
        }
        .formStyle(.grouped)
        .task { await measure() }
        .onAppear { permissions.refresh() }
        .onReceive(refreshTimer) { _ in permissions.refresh() }
    }

    // MARK: - Aufbewahrung

    /// One switch and one age. The budget is fixed at 20 GB and the grace period
    /// for failed recordings is twice the age — both derived rather than asked
    /// (§3.1 rule 1) — and the three **text** deadlines have stopped being
    /// automatic altogether: they were off in the default and stayed off, and
    /// whoever wants transcripts gone has "Jetzt aufräumen…". All six keys are
    /// still read; the pickers for them live under "Erweitert", for whoever set
    /// one.
    private var retentionSection: some View {
        Section {
            Toggle("Alte Aufnahmen automatisch aufräumen", isOn: $enabled)
            Picker("Meeting-Audio behalten", selection: audioChoice) {
                ForEach(AudioRetentionChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .disabled(!enabled)
        } header: {
            Text("Aufbewahrung")
        } footer: {
            Text("Gilt nur für rohes Audio. Notizen, Transkripte, Statistik und KI-Kosten werden nie automatisch gelöscht.")
        }
    }

    // MARK: - Statistik

    private var statisticsSection: some View {
        Section {
            Toggle("Ziel-App der Diktate erfassen", isOn: $appStatistics)
            // Confirmed and counted: it is a database write with no undo,
            // and it used to give no sign that anything had happened.
            Button("Erfasste Ziel-Apps löschen", role: .destructive) { confirmClearApps = true }
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
            Text("Statistik")
        } footer: {
            Text("Die Bundle-ID bleibt in der lokalen Datenbank und geht nie in eine Anfrage.")
        }
    }

    // MARK: - Berechtigungen

    /// The page that was. "Status aktualisieren" is gone — it refreshes every
    /// two seconds while this page is open — and "Notable neu starten" moved to
    /// Allgemein › Erweitert, next to the other thing a restart is for.
    private var permissionsSection: some View {
        Section {
            ForEach(PermissionsManager.Kind.allCases) { kind in
                permissionRow(kind)
            }
        } header: {
            Text("Berechtigungen")
        } footer: {
            // No count: there were six kinds behind a sentence claiming
            // five, and the onboarding said next door that only the
            // microphone is required. Both cannot be true, and the number
            // was the part that had to go.
            Text("Zwingend ist nur das Mikrofon. Fehlt eine der anderen, meldet das jeweilige Feature es und arbeitet eingeschränkt weiter.")
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

    // MARK: - Erweitert

    /// The five deadlines that lost their place over the fold. Nothing here is
    /// new and nothing here is required — it exists so that a value somebody
    /// set before Spec 38 stays reachable (§3.5).
    private var advancedSection: some View {
        Section {
            DisclosureGroup("Erweitert") {
                picker("Diktattext löschen nach", $dictationDays, Self.ages)
                picker("Meeting-Transkripte löschen nach", $meetingDays, Self.ages)
                picker("Chat-Verläufe löschen nach", $chatDays, Self.ages)
                picker("Gesamtbudget für Meeting-Audio", $audioBudgetGB, Self.budgets)
                picker("Fehlgeschlagene Aufnahmen löschen nach", $failedDays, Self.ages)
                Text("Gelöscht wird bei Texten nur der Text — die Statistik bleibt unverändert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Manuell aufräumen

    private var manualCleanupSection: some View {
        Section {
            if let pending {
                if pending.removals.isEmpty {
                    Text("Nichts aufzuräumen.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(Self.sessions(pending.removals.count)), \(byteText(pending.reclaimedBytes)) werden gelöscht.")
                    HStack {
                        Button("Endgültig löschen", role: .destructive) { runPlan(pending) }
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
            Text("Notizen, Statistik und KI-Kosten werden nie gelöscht; du siehst immer erst den Plan.")
        }
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

    @ViewBuilder
    private var modelSection: some View {
        Section {
            if models.isEmpty {
                EmptyState("Noch keine Modelle geladen.")
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
                Button("\(Self.models(plan.entries.count)) entfernen (\(byteText(plan.bytes)))", role: .destructive) {
                    confirmModelCleanup = true
                }
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
            Text("Unvollständige und nicht mehr benutzte Modelle lassen sich hier entfernen.")
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
                Text("Verlustfrei als .m4a — die Rohspur geht erst, wenn die neue geprüft ist.")
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

    /// Measured when the page opens, never continuously — walking four
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
