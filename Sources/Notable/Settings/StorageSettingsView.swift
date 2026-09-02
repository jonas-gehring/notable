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
    @AppStorage("appStatistics") private var appStatistics = true

    @State private var archive: (count: Int, bytes: Int64)?
    @State private var failed: (count: Int, bytes: Int64)?
    @State private var pending: RetentionPlanner.Plan?
    @State private var lastResult: RetentionRunner.Result?
    @State private var isWorking = false

    private static let ages: [(Int, String)] = [
        (0, "Aus"), (7, "7 Tage"), (30, "30 Tage"), (90, "90 Tage"), (365, "1 Jahr"),
    ]
    private static let budgets: [(Int, String)] = [
        (0, "Aus"), (5, "5 GB"), (10, "10 GB"), (20, "20 GB"), (50, "50 GB"),
    ]

    var body: some View {
        Form {
            Section("Belegung") {
                usageRow("Meeting-Audio", archive)
                usageRow("Fehlgeschlagene Aufnahmen", failed)
            }

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
                Button("Erfasste Ziel-Apps löschen") {
                    Task { _ = try? await RecordingStore.shared.clearSourceApps() }
                }
                .buttonStyle(.link)
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
                        Text("\(pending.removals.count) Sitzungen, \(byteText(pending.reclaimedBytes)) werden gelöscht.")
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
                    Text("Zuletzt gelöscht: \(lastResult.removedSessions) Sitzungen, \(byteText(lastResult.reclaimedBytes)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    @ViewBuilder
    private func usageRow(_ title: String, _ value: (count: Int, bytes: Int64)?) -> some View {
        LabeledContent(title) {
            if let value {
                Text("\(byteText(value.bytes)) · \(value.count) Sitzungen")
            } else {
                Text("wird gemessen…").foregroundStyle(.secondary)
            }
        }
    }

    private func picker(_ title: String, _ binding: Binding<Int>, _ options: [(Int, String)]) -> some View {
        Picker(title, selection: binding) {
            ForEach(options, id: \.0) { value, label in
                Text(label).tag(value)
            }
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Measured when the tab opens, never continuously — walking two directories
    /// of multi-gigabyte files is not something to do on a timer.
    private func measure() async {
        let archiveURL = SpoolStore.archiveURL
        let failedURL = SpoolStore.failedURL
        let measured = await Task.detached {
            (
                SpoolInventory.sessions(in: archiveURL),
                SpoolInventory.sessions(in: failedURL)
            )
        }.value
        archive = (measured.0.count, measured.0.reduce(0) { $0 + $1.byteSize })
        failed = (measured.1.count, measured.1.reduce(0) { $0 + $1.byteSize })
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
