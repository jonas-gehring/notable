import SwiftUI

/// Curated menu-bar icon choice, backed by a single `@AppStorage` key. Only the
/// truly-idle base symbol is user-configurable — the recording, processing, and
/// active-dictation icons stay fixed because they communicate state.
struct MenuBarIcon: Identifiable, Hashable {
    let symbol: String
    /// Every literal below goes through `String(localized:)`: this reaches
    /// `Text` and `.accessibilityLabel`, and a plain `String` is the one
    /// overload SwiftUI renders verbatim — thirty-nine German words that would
    /// sit unchanged in an English picker.
    let label: String

    var id: String { symbol }

    /// UserDefaults key shared with `NotableApp.menuSymbol`.
    static let storageKey = "menuBarIconSymbol"

    /// The default idle symbol (matches `AppState.CaptureState.idle.symbolName`).
    static let defaultSymbol = "waveform"

    /// The curated set offered in Settings — all transcription/audio/notes themed.
    static let all: [MenuBarIcon] = [
        MenuBarIcon(symbol: "waveform", label: String(localized: "Wellenform")),
        MenuBarIcon(symbol: "waveform.circle", label: String(localized: "Wellenform-Kreis")),
        MenuBarIcon(symbol: "waveform.badge.mic", label: String(localized: "Wellenform + Mikro")),
        MenuBarIcon(symbol: "mic", label: String(localized: "Mikrofon")),
        MenuBarIcon(symbol: "mic.fill", label: String(localized: "Mikrofon (voll)")),
        MenuBarIcon(symbol: "mic.circle", label: String(localized: "Mikro-Kreis")),
        MenuBarIcon(symbol: "note.text", label: String(localized: "Notiz")),
        MenuBarIcon(symbol: "doc.text", label: String(localized: "Dokument")),
        MenuBarIcon(symbol: "text.bubble", label: String(localized: "Sprechblase")),
        MenuBarIcon(symbol: "captions.bubble", label: String(localized: "Untertitel")),
        MenuBarIcon(symbol: "quote.bubble", label: String(localized: "Zitat")),
        MenuBarIcon(symbol: "text.bubble.fill", label: String(localized: "Sprechblase (voll)")),
        MenuBarIcon(symbol: "record.circle", label: String(localized: "Aufnahme")),
        MenuBarIcon(symbol: "sparkles", label: String(localized: "Funken")),
        MenuBarIcon(symbol: "person.wave.2", label: String(localized: "Sprecher")),
        MenuBarIcon(symbol: "ear", label: String(localized: "Ohr")),
        MenuBarIcon(symbol: "list.bullet.rectangle", label: String(localized: "Liste")),
        MenuBarIcon(symbol: "pencil.and.scribble", label: String(localized: "Notieren")),
        // Erweiterte Auswahl — bewusst unterschiedlichere Motive.
        MenuBarIcon(symbol: "waveform.path", label: String(localized: "Wellen-Pfad")),
        MenuBarIcon(symbol: "waveform.path.ecg", label: String(localized: "Pulslinie")),
        MenuBarIcon(symbol: "dot.radiowaves.left.and.right", label: String(localized: "Funkwellen")),
        MenuBarIcon(symbol: "wave.3.right", label: String(localized: "Schallwellen")),
        MenuBarIcon(symbol: "mic.and.signal.meter", label: String(localized: "Mikro + Pegel")),
        MenuBarIcon(symbol: "mic.square", label: String(localized: "Mikro (Quadrat)")),
        MenuBarIcon(symbol: "headphones", label: String(localized: "Kopfhörer")),
        MenuBarIcon(symbol: "speaker.wave.2", label: String(localized: "Lautsprecher")),
        MenuBarIcon(symbol: "character.bubble", label: String(localized: "Zeichen-Blase")),
        MenuBarIcon(symbol: "bubble.left.and.bubble.right", label: String(localized: "Dialog")),
        MenuBarIcon(symbol: "captions.bubble.fill", label: String(localized: "Untertitel (voll)")),
        MenuBarIcon(symbol: "quote.bubble.fill", label: String(localized: "Zitat (voll)")),
        MenuBarIcon(symbol: "square.and.pencil", label: String(localized: "Schreiben")),
        MenuBarIcon(symbol: "highlighter", label: String(localized: "Textmarker")),
        MenuBarIcon(symbol: "note", label: String(localized: "Notizzettel")),
        MenuBarIcon(symbol: "doc.plaintext", label: String(localized: "Klartext")),
        MenuBarIcon(symbol: "list.bullet.clipboard", label: String(localized: "Klemmbrett")),
        MenuBarIcon(symbol: "brain", label: String(localized: "Gehirn")),
        MenuBarIcon(symbol: "brain.head.profile", label: String(localized: "KI-Kopf")),
        MenuBarIcon(symbol: "wand.and.stars", label: String(localized: "Zauberstab")),
        MenuBarIcon(symbol: "keyboard", label: String(localized: "Tastatur")),
        MenuBarIcon(symbol: "text.cursor", label: String(localized: "Textcursor")),
    ]

    /// The user's chosen idle menu-bar symbol, or the default. Read this from the
    /// `App` struct so `menuSymbol` reflects the setting.
    static func idleSymbol() -> String {
        let stored = UserDefaults.standard.string(forKey: storageKey)
        guard let stored, !stored.isEmpty else { return defaultSymbol }
        return stored
    }
}

/// A compact grid of SF-Symbol options for the menu-bar icon. Drop into a
/// Settings tab / section.
struct IconPickerView: View {
    @AppStorage(MenuBarIcon.storageKey) private var selectedSymbol = MenuBarIcon.defaultSymbol

    private let columns = [GridItem(.adaptive(minimum: 60), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(MenuBarIcon.all) { icon in
                Button {
                    selectedSymbol = icon.symbol
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: icon.symbol)
                            .font(.title2)
                            .frame(height: 24)
                        Text(icon.label)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedSymbol == icon.symbol ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(selectedSymbol == icon.symbol ? Color.accentColor : Color.secondary.opacity(0.25))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(icon.label)
                .accessibilityAddTraits(selectedSymbol == icon.symbol ? [.isSelected] : [])
            }
        }
    }
}
