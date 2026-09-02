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
            case .day: "Letzte 24 Stunden"
            case .week: "Letzte 7 Tage"
            case .all: "Alle"
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
                        ? "Im gewählten Zeitraum wurde nicht diktiert."
                        : "")
                )
            } else {
                List(items) { item in
                    RecentDictationRow(item: item)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .task(id: reloadKey) {
            loaded = false
            let all = (try? await RecordingStore.shared.recentActivity(within: window.rawValue)) ?? []
            items = all.filter { $0.kind == .dictation }
            loaded = true
        }
    }

    /// One value that changes whenever we must re-query.
    private var reloadKey: String { "\(window.rawValue)-\(reloadToken)" }
}

private struct RecentDictationRow: View {
    let item: RecordingStore.ActivityItem
    @State private var copied = false
    @State private var correcting = false
    @State private var draft = ""

    private var text: String { (item.snippet ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    private var durationLabel: String? {
        guard let duration = item.duration, duration >= 1 else { return nil }
        let total = Int(duration.rounded())
        return total >= 60 ? "\(total / 60) min \(total % 60) s" : "\(total) s"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "mic")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if let durationLabel { Text("· \(durationLabel)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(text.isEmpty ? "(kein Text)" : text)
                    .font(.callout)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            VStack(spacing: 4) {
                Button("Einfügen") { try? Paster.insert(text) }
                    .buttonStyle(.link)
                    .disabled(text.isEmpty)
                Button(copied ? "Kopiert" : "Kopieren") {
                    guard !text.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .buttonStyle(.link)
                .disabled(text.isEmpty)

                Button("Korrigieren…") {
                    draft = text
                    correcting = true
                }
                .buttonStyle(.link)
                .disabled(text.isEmpty)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $correcting) { correctionSheet }
    }

    /// Lets the user fix a mis-heard dictation; the word-level diff is fed to
    /// `PersonalDictionary.recordCorrection` so Notable learns. The text is NOT
    /// re-inserted anywhere — it already landed in its target app.
    private var correctionSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diktat korrigieren")
                .font(.headline)
            Text("Notable lernt daraus, welche Wörter es falsch hört, und schlägt sie in den Einstellungen als Wörterbuch-Eintrag vor. Der Text wird nicht erneut eingefügt.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Abbrechen") { correcting = false }
                Button("Lernen") {
                    for pair in WordDiff.substitutions(from: text, to: draft) {
                        PersonalDictionary.recordCorrection(heard: pair.heard, corrected: pair.corrected)
                    }
                    correcting = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines) == text)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}
