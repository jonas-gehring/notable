import AppKit
import SwiftUI

/// The list of recent dictations — one implementation, two places.
///
/// It stood twice: as this window, with a period filter, a copy button and a
/// correction sheet that feeds `PersonalDictionary`; and as a section in the
/// dictation settings, which showed eight entries and could do none of that.
/// Two lists of the same thing that could different amounts, and nothing said
/// which one was the real one.
///
/// Now the settings section shows the shorter list and can do the same things.
/// That is a capability the section did not have — it follows from sharing the
/// row rather than from a separate decision to add it, which is why it is here
/// and not in its own commit.
struct RecentDictationsList: View {
    let items: [RecordingStore.ActivityItem]
    /// Inside a `Form` there is already a list around it; a `List` in a `List`
    /// draws its own scroller and its own insets.
    var compact = false

    var body: some View {
        if compact {
            ForEach(items) { item in
                RecentDictationRow(item: item, compact: true)
            }
        } else {
            List(items) { item in
                RecentDictationRow(item: item)
            }
            .listStyle(.inset)
        }
    }
}

struct RecentDictationRow: View {
    let item: RecordingStore.ActivityItem
    var compact = false
    @State private var copied = false
    @State private var correcting = false
    @State private var draft = ""

    private var text: String { (item.snippet ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    private var durationLabel: String? {
        guard let duration = item.duration, duration >= 1 else { return nil }
        let total = Int(duration.rounded())
        return total >= 60
            ? String(localized: "\(total / 60) min \(total % 60) s")
            : String(localized: "\(total) s")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if !compact {
                Image(systemName: "mic")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if let durationLabel { Text("· \(durationLabel)") }
                    // Marks the dictations whose text left the device, and keeps
                    // the original readable — otherwise nobody could tell what
                    // the model did.
                    if let rawText = item.rawText {
                        Label("verbessert", systemImage: "wand.and.stars")
                            .help("Original: \(rawText)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(text.isEmpty ? "(kein Text)" : text)
                    .font(.callout)
                    .lineLimit(compact ? 2 : 4)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            VStack(spacing: 4) {
                // No "Einfügen" here on purpose: clicking a button in this
                // window makes the window key, so the synthesized ⌘V lands in
                // Notable itself. Copying is the honest action from a window;
                // pasting belongs to the menu, where the target app is still
                // frontmost.
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
