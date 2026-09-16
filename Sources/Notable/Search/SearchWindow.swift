import AppKit
import SwiftUI

/// Full-text search over every recording — the reason SQLite is the source
/// of truth and Markdown only a projection.
struct SearchWindowView: View {
    @State private var query = ""
    @State private var hits: [RecordingStore.SearchHit] = []
    @State private var searched = false

    var body: some View {
        VStack(spacing: 0) {
            TextField("Diktate und Meetings durchsuchen…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(Theme.Spacing.m)
                .accessibilityLabel("Suchfeld")

            Divider()

            if hits.isEmpty {
                ContentUnavailableView(
                    searched && !query.isEmpty ? "Keine Treffer" : "Notizen durchsuchen",
                    systemImage: "magnifyingglass",
                    description: Text(searched && !query.isEmpty
                        ? "Nichts gefunden für „\(query)“."
                        : "Suchbegriff eingeben — durchsucht alle Transkripte lokal.")
                )
            } else {
                List(hits) { hit in
                    SearchHitRow(hit: hit)
                }
                .listStyle(.inset)
            }
        }
        .windowMinimum(WindowSize.search)
        .windowFrameAutosave(WindowSize.search)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250)) // debounce
            guard !Task.isCancelled else { return }
            hits = (try? await RecordingStore.shared.search(query)) ?? []
            searched = true
        }
    }
}

private struct SearchHitRow: View {
    let hit: RecordingStore.SearchHit

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: hit.kind == .meeting ? "person.2.wave.2" : "mic")
                .foregroundStyle(.secondary)
                .accessibilityLabel(hit.kind == .meeting ? "Meeting" : "Diktat")

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(hit.title ?? (hit.kind == .meeting ? "Meeting" : "Diktat"))
                        .font(.headline)
                    Spacer()
                    Text(hit.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(hit.snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            if let path = hit.markdownPath {
                Button("Öffnen") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
                .buttonStyle(.link)
            } else {
                Button("Kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hit.snippet, forType: .string)
                }
                .buttonStyle(.link)
            }
        }
        .padding(Theme.Spacing.xs)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall).fill(hovering ? Theme.hover : .clear))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Theme.Motion.appear, value: hovering)
        .transition(.opacity)
    }
}
