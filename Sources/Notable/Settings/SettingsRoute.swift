import Foundation

/// The four settings pages (Spec 38 §3.2).
///
/// There were seven, and three of them followed the code rather than a question
/// the user asks: "Zusammenfassung" was a section of Meetings that got a page
/// because `SummarizationProvider` is a module, "Menüleiste" was an icon and a
/// stepper, and "Speicherplatz" and "Berechtigungen" answer one question
/// together — *what does Notable know and keep?*
///
/// **The four old raw values still resolve** (``init(rawValue:)``): they are
/// written into notification payloads and set by menu items, so a route that
/// used to reach a page has to reach the page that absorbed it rather than
/// resolve to `nil` and drop the user wherever the window was last left.
///
/// It lives here rather than nested in `SettingsView` because it is pure — a
/// name, an icon and a table — and because the routes are worth a test, which
/// means not dragging four SwiftUI pages into the test bundle to get at them.
/// `SettingsView.Pane` is still its name at every call site.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, dictation, meetings, data

    /// Where each dissolved page went. Not a migration — nothing is stored
    /// under these names — just the aliases every old call site still uses.
    static let legacyAliases: [String: SettingsPane] = [
        "menubar": .general,
        "summary": .meetings,
        "storage": .data,
        "permissions": .data,
    ]

    /// Hand-written so the aliases resolve. The synthesized `rawValue` getter
    /// stays, so a pane still round-trips through its own raw value; only the
    /// way *in* is widened.
    init?(rawValue: String) {
        if let match = Self.allCases.first(where: { $0.stableRawValue == rawValue }) {
            self = match
        } else if let alias = Self.legacyAliases[rawValue] {
            self = alias
        } else {
            return nil
        }
    }

    /// The case's own spelling, without going through `init(rawValue:)`.
    private var stableRawValue: String {
        switch self {
        case .general: "general"
        case .dictation: "dictation"
        case .meetings: "meetings"
        case .data: "data"
        }
    }

    var id: String { rawValue }

    var label: String {
        let key: String.LocalizationValue = switch self {
        case .general: "Allgemein"
        case .dictation: "Diktat"
        case .meetings: "Meetings"
        case .data: "Daten"
        }
        return String(localized: key)
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "mic"
        case .meetings: "person.2.wave.2"
        case .data: "lock.shield"
        }
    }
}

/// Which settings page should be shown when the window comes up.
///
/// The window scene is opened by id and has no parameters, so a menu item that
/// is *about* a page — "Notable belegt 5,3 GB" — had no way to lead to it and
/// would have dropped the user on "Allgemein" to find it themselves. Set the
/// pane, then open the window; ``SettingsView`` consumes it once and clears it,
/// so the next plain "Einstellungen…" opens where it left off.
@MainActor
final class SettingsRoute: ObservableObject {
    @Published var requested: SettingsPane?

    /// Reads and clears in one step — a route that stayed set would pull every
    /// later visit back to the same page.
    func consume() -> SettingsPane? {
        defer { requested = nil }
        return requested
    }
}
