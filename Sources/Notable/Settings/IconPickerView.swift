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

    /// The curated set offered in Settings (Spec 33 §3.7): twelve motifs, not a
    /// collection of forty. A symbol chosen from the old list keeps working —
    /// `idleSymbol()` reads whatever is stored — and stays visible in the picker
    /// as the previous choice (`offered(current:)`).
    static let all: [MenuBarIcon] = [
        MenuBarIcon(symbol: "waveform", label: String(localized: "Wellenform")),
        MenuBarIcon(symbol: "waveform.circle", label: String(localized: "Wellenform-Kreis")),
        MenuBarIcon(symbol: "waveform.badge.mic", label: String(localized: "Wellenform + Mikro")),
        MenuBarIcon(symbol: "waveform.path.ecg", label: String(localized: "Pulslinie")),
        MenuBarIcon(symbol: "mic", label: String(localized: "Mikrofon")),
        MenuBarIcon(symbol: "mic.fill", label: String(localized: "Mikrofon (voll)")),
        MenuBarIcon(symbol: "mic.circle", label: String(localized: "Mikro-Kreis")),
        MenuBarIcon(symbol: "text.bubble", label: String(localized: "Sprechblase")),
        MenuBarIcon(symbol: "captions.bubble", label: String(localized: "Untertitel")),
        MenuBarIcon(symbol: "note.text", label: String(localized: "Notiz")),
        MenuBarIcon(symbol: "record.circle", label: String(localized: "Aufnahme")),
        MenuBarIcon(symbol: "pencil.and.scribble", label: String(localized: "Notieren")),
    ]

    /// The motifs to show: the twelve, plus a stored symbol from the old list.
    static func offered(current: String) -> [MenuBarIcon] {
        guard !current.isEmpty, !all.contains(where: { $0.symbol == current }) else { return all }
        return all + [MenuBarIcon(symbol: current, label: String(localized: "Bisherige Wahl"))]
    }

    /// The user's chosen idle menu-bar symbol, or the default. Read this from the
    /// `App` struct so `menuSymbol` reflects the setting.
    static func idleSymbol() -> String {
        let stored = UserDefaults.standard.string(forKey: storageKey)
        guard let stored, !stored.isEmpty else { return defaultSymbol }
        return stored
    }
}

/// The idle symbol, as a popup (Spec 38 §3.2).
///
/// It was a twelve-cell `LazyVGrid` with a selection ring — a whole page's worth
/// of surface for a choice made once, on a page that existed for nothing else.
/// A `Picker` in a `Form` row shows the chosen motif *and* its name, the way
/// every other choice on these four pages does, and the menu bar itself is the
/// preview.
struct MenuBarIconPicker: View {
    @AppStorage(MenuBarIcon.storageKey) private var selectedSymbol = MenuBarIcon.defaultSymbol

    var body: some View {
        Picker("Symbol", selection: $selectedSymbol) {
            ForEach(MenuBarIcon.offered(current: selectedSymbol)) { icon in
                // The label is already localized; `Label` renders a plain
                // `String` verbatim, which is what we want here.
                Label(icon.label, systemImage: icon.symbol)
                    .tag(icon.symbol)
            }
        }
    }
}
