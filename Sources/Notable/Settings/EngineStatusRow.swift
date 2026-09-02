import SwiftUI

/// The engine's real state, next to the picker that chooses it (Spec 11 §2).
///
/// Before this, a download ran silently inside FluidAudio and the only sign of
/// life was one line in the menu bar — the one place nobody looks while changing
/// a setting in the settings window. A failed load waited for the next dictation
/// to retry itself.
struct EngineStatusRow: View {
    @ObservedObject var dictation: DictationController

    private var selected: ASREngineID { ASREngineID.current }

    var body: some View {
        LabeledContent("Modell") {
            HStack(spacing: 8) {
                switch dictation.modelState(for: selected) {
                case .ready:
                    Label("geladen", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                case .loading:
                    ProgressView().controlSize(.small)
                    // A percentage only once there is one. A phantom 0 % on a
                    // warm cache would be a lie about work that is not happening.
                    if let progress = dictation.downloadProgress {
                        Text("lädt: \(Int(progress * 100)) %")
                    } else {
                        Text("lädt…")
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                    Button("Nochmal versuchen") { dictation.retryLoad(selected) }
                        .buttonStyle(.link)
                }
                Text("·  \(selected.downloadSize)")
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
        }
        if dictation.isUsingBootstrap {
            Text("Vorläufig aktiv: \(BootstrapPolicy.bootstrapEngine.shortLabel) \(BootstrapPolicy.bootstrapSize.rawValue) — \(selected.shortLabel) lädt noch. Diktate sind schon möglich, aber merklich ungenauer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// „Sprachen, die ich diktiere" (Spec 11 §3).
///
/// Two entries, not a hundred: `TextPolisher` only tells German from English, so
/// a third would promise something nothing downstream delivers.
struct SpokenLanguagesRow: View {
    @State private var selection: Set<String> = Set(SpokenLanguages.load())

    var body: some View {
        LabeledContent("Sprachen, die ich diktiere") {
            HStack(spacing: 12) {
                ForEach(SpokenLanguages.supported, id: \.code) { language in
                    Toggle(language.label, isOn: binding(for: language.code))
                        .toggleStyle(.checkbox)
                }
            }
        }
        Text("""
        Schränkt die Spracherkennung der Textnachbearbeitung ein — ohne das kann \
        ein kurzes „Ok, dann machen wir das“ als Dänisch durchgehen und verliert \
        Wörter an die englische Füllwortliste. Bei genau einer Sprache stellt \
        Whisper zusätzlich fest darauf ein. Auf Parakeet wirkt es nicht: das Modell \
        erkennt selbst und hat keinen Schalter dafür.
        """)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func binding(for code: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(code) },
            set: { isOn in
                var next = selection
                if isOn {
                    next.insert(code)
                } else {
                    // The last language cannot be removed — an empty profile
                    // would leave the recognizer unconstrained again, which is
                    // the state this setting exists to prevent.
                    guard next.count > 1 else { return }
                    next.remove(code)
                }
                selection = next
                SpokenLanguages.save(SpokenLanguages.supported.map(\.code).filter(next.contains))
            }
        )
    }
}
