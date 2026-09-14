import AppKit
import SwiftUI

/// The main menu's About and Help (Spec 33 §3.4).
///
/// Notable is an accessory app, so its menu bar only shows while one of its
/// windows is key — and there it had no About item and no Help menu. The
/// version was reachable only through Settings → Allgemein. These two are
/// exactly what belongs in a menu that is present only inside Notable's own
/// windows; nothing global lives here.
struct NotableCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("Über Notable") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            }
        }
        CommandGroup(replacing: .help) {
            Button("Notable-Hilfe") {
                guard let url = URL(string: "https://github.com/jonas-gehring/notable#readme") else { return }
                NSWorkspace.shared.open(url)
            }
            Button("Einführung zeigen") {
                AppContainer.shared.presentWindow("onboarding")
            }
        }
    }
}
