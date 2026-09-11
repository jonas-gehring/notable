import SwiftUI

/// Correcting who said what, so that the correction holds (Spec 24, Stufe 4).
///
/// Renaming "Sprecher 3" by hand in the Markdown was lost at the next
/// projection from SQLite. Here a name goes into the store — `speaker_labels`,
/// source `user`, which no later run overwrites — and the note is projected
/// again. The summary is not redone on its own: with the API provider that
/// costs money, so it is offered.
struct SpeakerEditorView: View {
    let recording: RecordingStore.Recording
    @EnvironmentObject private var noteManager: NoteManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DefaultsKey.summarizationProvider.key) private var providerID = DefaultsKey.summarizationProvider.fallback

    @State private var speakers: [RecordingStore.SpeakerLabel] = []
    @State private var drafts: [String: String] = [:]
    @State private var summaryStale = false
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sprecher").font(.headline)
                Text(recording.title ?? String(localized: "Meeting")).font(.subheadline).foregroundStyle(.secondary)
            }
            if speakers.isEmpty {
                Text("Dieses Meeting hat keine Sprecher-Labels.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    ForEach(speakers) { speaker in
                        row(speaker)
                    }
                }
            }
            if summaryStale {
                HStack {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text("Die Zusammenfassung ist noch auf dem alten Stand.")
                    Spacer()
                    Button("Neu zusammenfassen") { resummarize() }
                }
                .font(.callout)
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 600, minHeight: 280)
        .disabled(busy)
        .task { await load() }
    }

    @ViewBuilder
    private func row(_ speaker: RecordingStore.SpeakerLabel) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(speaker.name).fontWeight(.medium)
                Text("\(speaker.segmentCount) Beiträge · \(Self.duration(speaker.seconds))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if speaker.isLocalUser {
                Text("fest").font(.caption).foregroundStyle(.secondary)
                Color.clear.frame(width: 1, height: 1)
                Color.clear.frame(width: 1, height: 1)
            } else {
                HStack(spacing: 4) {
                    TextField("Name …", text: draftBinding(speaker))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160)
                        .onSubmit { rename(speaker) }
                    if !suggestions.isEmpty {
                        Menu {
                            ForEach(suggestions, id: \.self) { name in
                                Button(name) { drafts[speaker.cluster] = name; rename(speaker) }
                            }
                        } label: { Image(systemName: "person.crop.circle.badge.questionmark") }
                        .menuStyle(.borderlessButton)
                        .frame(width: 32)
                        .help("Vorschläge aus Kalender und Call")
                    }
                }
                Text(speaker.source.map(Self.sourceLabel) ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                Menu("Zusammenführen") {
                    ForEach(speakers.filter { !$0.isLocalUser && $0.cluster != speaker.cluster }) { other in
                        Button(String(localized: "mit „\(other.name)“")) { merge(speaker, into: other) }
                    }
                }
                .fixedSize()
                .disabled(speakers.filter { !$0.isLocalUser }.count < 2)
            }
        }
    }

    // MARK: - Actions

    private var suggestions: [String] {
        var seen = Set<String>()
        return (recording.attendees + recording.participants).filter { seen.insert($0.lowercased()).inserted }
    }

    private func draftBinding(_ speaker: RecordingStore.SpeakerLabel) -> Binding<String> {
        Binding(get: { drafts[speaker.cluster] ?? "" }, set: { drafts[speaker.cluster] = $0 })
    }

    private func load() async {
        speakers = await noteManager.speakers(of: recording)
        drafts = Dictionary(uniqueKeysWithValues: speakers.map { ($0.cluster, $0.source == nil ? "" : $0.name) })
    }

    private func rename(_ speaker: RecordingStore.SpeakerLabel) {
        let name = (drafts[speaker.cluster] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        perform { try await noteManager.renameSpeaker(recording, cluster: speaker.cluster, to: name) }
    }

    private func merge(_ speaker: RecordingStore.SpeakerLabel, into other: RecordingStore.SpeakerLabel) {
        perform { try await noteManager.mergeSpeaker(recording, cluster: speaker.cluster, into: other.cluster) }
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        busy = true
        errorMessage = nil
        Task {
            do {
                try await work()
                summaryStale = recording.summary != nil
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    private func resummarize() {
        busy = true
        Task {
            do {
                try await noteManager.resummarizeWithNotes(recording, providerID: providerID)
                summaryStale = false
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    private static func sourceLabel(_ source: RecordingStore.SpeakerLabel.Source) -> String {
        switch source {
        case .screen: String(localized: "vom Bildschirm")
        case .llm: String(localized: "aus dem Gespräch")
        case .user: String(localized: "von dir")
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
