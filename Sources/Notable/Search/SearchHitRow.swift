import AppKit
import SwiftUI

/// One full-text hit (FTS5 over every recording, the reason SQLite is the
/// source of truth and Markdown only a projection). Shown by the notes window
/// for dictation hits; meeting hits there select the note instead.
struct SearchHitRow: View {
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
