import SwiftUI

/// Correcting who said what, so that the correction holds (Spec 24, Stufe 4).
///
/// Renaming "Sprecher 3" by hand in the Markdown was lost at the next
/// projection from SQLite. Here a name goes into the store — `speaker_labels`,
/// source `user`, which no later run overwrites — and the note is projected
/// again. The summary is not redone on its own: with the API provider that
/// costs money, so it is offered.
///
/// Since Spec 36 the dialog has an ear: ▶ plays the loudest five seconds of
/// that speaker out of the archived audio (`SpeakerSample`). Without it only
/// someone who remembers the meeting can correct anything — which is the reason
/// the field measurement found 23 unnamed labels and no corrections. Where the
/// archive is gone (retention, or a meeting older than the archive) the button
/// is disabled and says so, rather than doing nothing.
struct SpeakerEditorView: View {
    let recording: RecordingStore.Recording
    /// Set when the dialog is its own window (`SpeakerEditorWindow`, opened from
    /// the notification): SwiftUI's `dismiss` closes a sheet, and this one has
    /// none. As a sheet in the note list it stays nil and `dismiss` applies.
    var onClose: (() -> Void)?

    @EnvironmentObject private var noteManager: NoteManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DefaultsKey.summarizationProvider.key) private var providerID = DefaultsKey.summarizationProvider.fallback

    @State private var speakers: [RecordingStore.SpeakerLabel] = []
    @State private var drafts: [String: String] = [:]
    /// Cluster → its turns, for the audio sample.
    @State private var times: [String: [(start: TimeInterval, end: TimeInterval)]] = [:]
    @StateObject private var sample = SpeakerSamplePlayer()
    @State private var summaryStale = false
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
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
            if let message = errorMessage ?? sample.failure {
                Text(message).font(.callout).foregroundStyle(.red)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Fertig") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 600, minHeight: 280)
        .disabled(busy)
        .task { await load() }
        .onDisappear { sample.stop() }
    }

    @ViewBuilder
    private func row(_ speaker: RecordingStore.SpeakerLabel) -> some View {
        GridRow {
            HStack(spacing: Theme.Spacing.xs) {
                playButton(speaker)
                VStack(alignment: .leading, spacing: 1) {
                    Text(speaker.name).fontWeight(.medium)
                    Text("\(speaker.segmentCount) Beiträge · \(Self.duration(speaker.seconds))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if speaker.isLocalUser {
                Text("fest").font(.caption).foregroundStyle(.secondary)
                Color.clear.frame(width: 1, height: 1)
                Color.clear.frame(width: 1, height: 1)
            } else if speaker.isUnknown {
                Text("zu kurz, um eine Stimme zu erkennen").font(.caption).foregroundStyle(.secondary)
                Color.clear.frame(width: 1, height: 1)
                Color.clear.frame(width: 1, height: 1)
            } else {
                HStack(spacing: Theme.Spacing.xs) {
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
                    ForEach(speakers.filter { !$0.isLocalUser && !$0.isUnknown && $0.cluster != speaker.cluster }) { other in
                        Button(String(localized: "mit „\(other.name)“")) { merge(speaker, into: other) }
                    }
                }
                .fixedSize()
                .disabled(speakers.filter { !$0.isLocalUser && !$0.isUnknown }.count < 2)
            }
        }
    }

    // MARK: - Hörprobe

    @ViewBuilder
    private func playButton(_ speaker: RecordingStore.SpeakerLabel) -> some View {
        Button {
            if sample.playing == speaker.cluster {
                sample.stop()
            } else {
                sample.play(cluster: speaker.cluster, segments: times[speaker.cluster] ?? [])
            }
        } label: {
            Image(systemName: sample.playing == speaker.cluster ? "stop.circle" : "play.circle")
                .imageScale(.large)
        }
        .buttonStyle(.borderless)
        .disabled(sample.archive == nil || (times[speaker.cluster] ?? []).isEmpty)
        .help(sampleHint)
        .accessibilityLabel("Fünf Sekunden anhören")
    }

    /// Typed as a `LocalizedStringKey` on purpose: a ternary of two string
    /// literals lands on the verbatim `String` overload of `.help`, and then the
    /// German shows through in every language.
    private var sampleHint: LocalizedStringKey {
        sample.archive == nil ? "Audio nicht mehr vorhanden" : "Fünf Sekunden anhören"
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
        // The shared store, not the note manager's: the segments' times are what
        // the sample needs, and `NoteManager` deliberately exposes notes rather
        // than rows. The labels above come from the same database.
        let segments = (try? await RecordingStore.shared.segments(for: recording.id)) ?? []
        times = segments.reduce(into: [:]) { result, segment in
            // The same key `speakerLabels` groups by: the minted cluster, or the
            // shown name for a meeting from before the column existed.
            guard let label = segment.cluster ?? segment.speaker else { return }
            result[label, default: []].append((start: segment.start, end: segment.end ?? segment.start))
        }
        await sample.prepare(for: recording)
    }

    private func rename(_ speaker: RecordingStore.SpeakerLabel) {
        let name = (drafts[speaker.cluster] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        perform { try await noteManager.renameSpeaker(recording, cluster: speaker.cluster, to: name) }
    }

    private func merge(_ speaker: RecordingStore.SpeakerLabel, into other: RecordingStore.SpeakerLabel) {
        perform { try await noteManager.mergeSpeaker(recording, cluster: speaker.cluster, into: other.cluster) }
    }

    private func close() {
        sample.stop()
        if let onClose { onClose() } else { dismiss() }
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
        case .calendar: String(localized: "aus dem Kalender")
        case .llm: String(localized: "aus dem Gespräch")
        case .voice: String(localized: "an der Stimme erkannt")
        case .user: String(localized: "von dir")
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
