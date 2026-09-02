import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "Textbausteine" section of the dictation settings (issue #4).
///
/// It sits next to the personal dictionary and deliberately looks similar, which
/// is why the collision warning matters: a trigger that is also a dictionary key
/// means one table corrects what the other just inserted.
struct SmartReplaceSection: View {
    @State private var items: [SmartReplacement] = SmartReplace.load()
    @State private var editing: SmartReplacement?
    @State private var dictionary: [String: String] = PersonalDictionary.load()

    private var collisions: Set<UUID> { SmartReplace.collisions(items, dictionary: dictionary) }

    var body: some View {
        Section {
            if items.isEmpty {
                Text("Noch keine Textbausteine.")
                    .foregroundStyle(.secondary)
            }
            ForEach($items) { $item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Toggle("", isOn: $item.enabled)
                        .labelsHidden()
                        .onChange(of: item.enabled) { _, _ in persist() }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.trigger)
                                .fontWeight(.medium)
                            if collisions.contains(item.id) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("Steht auch im Wörterbuch — die eine Tabelle korrigiert, was die andere einsetzt.")
                            }
                        }
                        Text(preview(item.replacement))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Bearbeiten") { editing = item }
                        .buttonStyle(.link)
                    Button {
                        items.removeAll { $0.id == item.id }
                        persist()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Baustein löschen")
                }
                .padding(.vertical, 2)
            }

            HStack {
                Button("Baustein hinzufügen…") {
                    editing = SmartReplacement(trigger: "", replacement: "")
                }
                Spacer()
                Button("Exportieren…") { export() }
                    .buttonStyle(.link)
                Button("Importieren…") { importItems() }
                    .buttonStyle(.link)
            }
        } header: {
            Text("Textbausteine")
        } footer: {
            Text("""
            Ein gesprochenes Kürzel wird zu beliebigem, auch mehrzeiligem Text. \
            Getrennt vom Wörterbuch und bewusst nicht unscharf: eine knapp \
            danebenliegende Korrektur kostet ein Wort, eine knapp danebenliegende \
            Expansion schreibt einen Absatz. Bausteine wirken auch im Verbatim-Modus \
            (Editor, Terminal) — dort sind sie der eigentliche Gewinn.
            """)
        }
        .sheet(item: $editing) { item in
            SmartReplaceEditor(item: item) { saved in
                if let index = items.firstIndex(where: { $0.id == saved.id }) {
                    items[index] = saved
                } else {
                    items.append(saved)
                }
                persist()
            }
        }
    }

    private func preview(_ text: String) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        return single.count > 60 ? String(single.prefix(60)) + "…" : single
    }

    private func persist() {
        SmartReplace.save(items)
        items = SmartReplace.load()
        dictionary = PersonalDictionary.load()
    }

    // MARK: - Export / import

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Textbausteine.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(items).write(to: url, options: .atomic)
    }

    private func importItems() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let imported = try? JSONDecoder().decode([SmartReplacement].self, from: data)
        else { return }
        // Appended, not replaced: an import must never silently drop the list
        // that is already there.
        let known = Set(items.map { $0.trigger.lowercased() })
        items += imported.filter { !known.contains($0.trigger.lowercased()) }
        persist()
    }
}

private struct SmartReplaceEditor: View {
    @State var item: SmartReplacement
    let onSave: (SmartReplacement) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Textbaustein")
                .font(.headline)

            Form {
                TextField("Wenn du sagst", text: $item.trigger, prompt: Text("meine Adresse"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("erscheint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $item.replacement)
                        .font(.body)
                        .frame(minHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                }
                Toggle("Groß-/Kleinschreibung beachten", isOn: $item.caseSensitive)
            }
            .formStyle(.grouped)

            Text("Platzhalter: {datum}, {uhrzeit}, {wochentag}.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Sichern") {
                    onSave(item)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!SmartReplace.isValidTrigger(item.trigger) || item.replacement.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}
