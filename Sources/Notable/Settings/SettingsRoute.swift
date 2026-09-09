import Foundation

/// Which settings page should be shown when the window comes up.
///
/// The window scene is opened by id and has no parameters, so a menu item that
/// is *about* a page — "Notable belegt 5,3 GB" — had no way to lead to it and
/// would have dropped the user on "Allgemein" to find it themselves. Set the
/// pane, then open the window; ``SettingsView`` consumes it once and clears it,
/// so the next plain "Einstellungen…" opens where it left off.
@MainActor
final class SettingsRoute: ObservableObject {
    @Published var requested: SettingsView.Pane?

    /// Reads and clears in one step — a route that stayed set would pull every
    /// later visit back to the same page.
    func consume() -> SettingsView.Pane? {
        defer { requested = nil }
        return requested
    }
}
