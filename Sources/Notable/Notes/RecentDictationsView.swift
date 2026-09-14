import AppKit
import SwiftUI

/// Overview of the most recent **dictations**, newest first, in a trailing time
/// window (default 24 h). Each shows its spoken text with copy + re-insert.
struct RecentDictationsView: View {
    /// Trailing time windows offered above the list.
    enum Window: Int, CaseIterable, Identifiable {
        case day = 24
        case week = 168
        case all = 0

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .day: String(localized: "Letzte 24 Stunden")
            case .week: String(localized: "Letzte 7 Tage")
            case .all: String(localized: "Alle")
            }
        }
    }

    @State private var window: Window = .day
    @State private var items: [RecordingStore.ActivityItem] = []
    @State private var loaded = false
    /// The dictation whose transcription failed or whose paste did not land
    /// (Spec 30 §3.7).
    @State private var failed: LastClip?
    /// Bumps to re-run the loader when the user switches windows or asks to refresh.
    @State private var reloadToken = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Zeitraum", selection: $window) {
                    ForEach(Window.allCases) { win in
                        Text(win.label).tag(win)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Spacer()

                Button {
                    reloadToken += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Aktualisieren")
                .accessibilityLabel("Aktualisieren")
            }
            .padding(12)

            Divider()

            if let failed {
                failedRow(failed)
                Divider()
            }

            if items.isEmpty, !loaded {
                // Loading is not an empty state (Spec 33 §3.6): a large "no
                // content" graphic for the half second a query takes read as
                // "there is nothing" before there was an answer.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "Keine Diktate",
                    systemImage: "mic",
                    description: Text("Im gewählten Zeitraum wurde nicht diktiert.")
                )
            } else {
                RecentDictationsList(items: items)
            }
        }
        .windowMinimum(WindowSize.recent)
        .windowFrameAutosave(WindowSize.recent)
        .task(id: reloadKey) {
            loaded = false
            failed = LastClipStore.pending()
            // Filtered in SQL, not here: with a mixed `LIMIT 200` the meetings
            // in the window ate slots, so "all dictations" was quietly capped
            // at whatever share of the last 200 rows happened to be dictations.
            items = (try? await RecordingStore.shared.recentActivity(
                kind: .dictation, within: window.rawValue
            )) ?? []
            loaded = true
        }
    }

    /// The failed dictation, here too. Retrying stays in the menu: it pastes, and
    /// a click in this window makes Notable the frontmost app — the text would
    /// land here. From the window it can be copied or discarded.
    private func failedRow(_ clip: LastClip) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Fehlgeschlagenes Diktat · \(clip.recordedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout.weight(.medium))
                Text(clip.failure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Wiederholen fügt ein — deshalb steht es im Menü, wo die Ziel-App vorne bleibt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let text = clip.text {
                Button("Kopieren") { DictationHistory.copyToClipboard(text) }
                    .buttonStyle(.link)
            }
            Button("Verwerfen", role: .destructive) {
                AppContainer.shared.dictation.discardLastClip()
                failed = nil
            }
            .buttonStyle(.link)
        }
        .padding(Theme.Spacing.m)
    }

    /// One value that changes whenever we must re-query.
    private var reloadKey: String { "\(window.rawValue)-\(reloadToken)" }
}
