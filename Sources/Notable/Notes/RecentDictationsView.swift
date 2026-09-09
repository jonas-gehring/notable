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

            if items.isEmpty {
                ContentUnavailableView(
                    loaded ? "Keine Diktate" : "Wird geladen…",
                    systemImage: "mic",
                    description: Text(loaded
                        ? String(localized: "Im gewählten Zeitraum wurde nicht diktiert.")
                        : "")
                )
            } else {
                RecentDictationsList(items: items)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .task(id: reloadKey) {
            loaded = false
            // Filtered in SQL, not here: with a mixed `LIMIT 200` the meetings
            // in the window ate slots, so "all dictations" was quietly capped
            // at whatever share of the last 200 rows happened to be dictations.
            items = (try? await RecordingStore.shared.recentActivity(
                kind: .dictation, within: window.rawValue
            )) ?? []
            loaded = true
        }
    }

    /// One value that changes whenever we must re-query.
    private var reloadKey: String { "\(window.rawValue)-\(reloadToken)" }
}
