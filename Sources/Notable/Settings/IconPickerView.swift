import SwiftUI

/// Curated menu-bar icon choice, backed by a single `@AppStorage` key. Only the
/// truly-idle base symbol is user-configurable — the recording, processing, and
/// active-dictation icons stay fixed because they communicate state.
struct MenuBarIcon: Identifiable, Hashable {
    let symbol: String
    let label: String

    var id: String { symbol }

    /// UserDefaults key shared with `NotableApp.menuSymbol`.
    static let storageKey = "menuBarIconSymbol"

    /// The default idle symbol (matches `AppState.CaptureState.idle.symbolName`).
    static let defaultSymbol = "waveform"

    /// The curated set offered in Settings — all transcription/audio/notes themed.
    static let all: [MenuBarIcon] = [
        MenuBarIcon(symbol: "waveform", label: "Wellenform"),
        MenuBarIcon(symbol: "waveform.circle", label: "Wellenform-Kreis"),
        MenuBarIcon(symbol: "waveform.badge.mic", label: "Wellenform + Mikro"),
        MenuBarIcon(symbol: "mic", label: "Mikrofon"),
        MenuBarIcon(symbol: "mic.fill", label: "Mikrofon (voll)"),
        MenuBarIcon(symbol: "mic.circle", label: "Mikro-Kreis"),
        MenuBarIcon(symbol: "note.text", label: "Notiz"),
        MenuBarIcon(symbol: "doc.text", label: "Dokument"),
        MenuBarIcon(symbol: "text.bubble", label: "Sprechblase"),
        MenuBarIcon(symbol: "captions.bubble", label: "Untertitel"),
        MenuBarIcon(symbol: "quote.bubble", label: "Zitat"),
        MenuBarIcon(symbol: "text.bubble.fill", label: "Sprechblase (voll)"),
        MenuBarIcon(symbol: "record.circle", label: "Aufnahme"),
        MenuBarIcon(symbol: "sparkles", label: "Funken"),
        MenuBarIcon(symbol: "person.wave.2", label: "Sprecher"),
        MenuBarIcon(symbol: "ear", label: "Ohr"),
        MenuBarIcon(symbol: "list.bullet.rectangle", label: "Liste"),
        MenuBarIcon(symbol: "pencil.and.scribble", label: "Notieren"),
        // Erweiterte Auswahl — bewusst unterschiedlichere Motive.
        MenuBarIcon(symbol: "waveform.path", label: "Wellen-Pfad"),
        MenuBarIcon(symbol: "waveform.path.ecg", label: "Pulslinie"),
        MenuBarIcon(symbol: "dot.radiowaves.left.and.right", label: "Funkwellen"),
        MenuBarIcon(symbol: "wave.3.right", label: "Schallwellen"),
        MenuBarIcon(symbol: "mic.and.signal.meter", label: "Mikro + Pegel"),
        MenuBarIcon(symbol: "mic.square", label: "Mikro (Quadrat)"),
        MenuBarIcon(symbol: "headphones", label: "Kopfhörer"),
        MenuBarIcon(symbol: "speaker.wave.2", label: "Lautsprecher"),
        MenuBarIcon(symbol: "character.bubble", label: "Zeichen-Blase"),
        MenuBarIcon(symbol: "bubble.left.and.bubble.right", label: "Dialog"),
        MenuBarIcon(symbol: "captions.bubble.fill", label: "Untertitel (voll)"),
        MenuBarIcon(symbol: "quote.bubble.fill", label: "Zitat (voll)"),
        MenuBarIcon(symbol: "square.and.pencil", label: "Schreiben"),
        MenuBarIcon(symbol: "highlighter", label: "Textmarker"),
        MenuBarIcon(symbol: "note", label: "Notizzettel"),
        MenuBarIcon(symbol: "doc.plaintext", label: "Klartext"),
        MenuBarIcon(symbol: "list.bullet.clipboard", label: "Klemmbrett"),
        MenuBarIcon(symbol: "brain", label: "Gehirn"),
        MenuBarIcon(symbol: "brain.head.profile", label: "KI-Kopf"),
        MenuBarIcon(symbol: "wand.and.stars", label: "Zauberstab"),
        MenuBarIcon(symbol: "keyboard", label: "Tastatur"),
        MenuBarIcon(symbol: "text.cursor", label: "Textcursor"),
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
