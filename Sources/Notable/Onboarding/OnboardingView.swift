import AppKit
import SwiftUI

/// First-run walkthrough: purpose + the five permissions (guided, using the same
/// `PermissionsManager` as Settings) + a first-dictation success moment. Skippable
/// everywhere; the current page is persisted so a relaunch (needed for screen /
/// input-monitoring grants) resumes where it left off.
struct OnboardingView: View {
    @EnvironmentObject private var permissions: PermissionsManager
    @EnvironmentObject private var dictation: DictationController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @AppStorage("didCompleteOnboarding") private var didComplete = false
    @AppStorage("onboardingPage") private var pageRaw = 0
    @AppStorage(HotkeySpec.storageKey) private var hotkeyRaw = HotkeySpec.rightOption.rawValue

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    enum Page: Int, CaseIterable {
        case welcome, microphone, hotkey, firstDictation, meetings, provider, done

        /// Names the dots in the footer, so jumping straight to a page is a
        /// choice rather than a guess.
        var title: String {
            switch self {
            case .welcome: "Willkommen"
            case .microphone: "Mikrofon"
            case .hotkey: "Hotkey & Einfügen"
            case .firstDictation: "Erstes Diktat"
            case .meetings: "Meetings"
            case .provider: "Zusammenfassung"
            case .done: "Fertig"
            }
        }
    }

    private var page: Page { Page(rawValue: pageRaw) ?? .welcome }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
            Divider()
            footer
        }
        .frame(width: 540, height: 480)
        .background(Theme.windowBackground)
        .onReceive(refreshTimer) { _ in permissions.refresh() }
        .onAppear { permissions.refresh() }
    }

    // MARK: Pages

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome:
            pageBody(
                icon: "waveform",
                title: "Willkommen bei Notable",
                text: "Diktiere per Hotkey in jedes Textfeld und lass Meetings automatisch mitschreiben — die Erkennung läuft auf deinem Mac. **Audio verlässt das Gerät nie**; zum Zusammenfassen geht ausschließlich der Text eines Meetings hinaus. Jede Meeting-Notiz landet als Markdown-Datei in einem Ordner, den du aussuchst — auch ohne Notable lesbar.")
        case .microphone:
            permissionPage(
                .microphone,
                title: "Mikrofon",
                text: "Ohne Mikrofon kein Diktat. Das ist die einzige zwingende Berechtigung.")
        case .hotkey:
            VStack(alignment: .leading, spacing: 16) {
                pageHeader(icon: "keyboard", title: "Hotkey & Einfügen")
                Text("Für den globalen Push-to-talk-Hotkey und das Einfügen ins fokussierte Feld braucht Notable zwei Berechtigungen. Beide werden erst nach einem Neustart aktiv.")
                    .foregroundStyle(Theme.textSubtle)
                permissionRow(.inputMonitoring)
                permissionRow(.accessibility)
                Button("Notable neu starten") { relaunch() }
                    .padding(.top, 4)
            }
        case .firstDictation:
            firstDictationPage
        case .meetings:
            VStack(alignment: .leading, spacing: 16) {
                pageHeader(icon: "person.2.wave.2", title: "Meetings (optional)")
                Text("Notable erkennt Calls und schreibt mit. Für den Ton der anderen verlangt macOS das Recht **Systemaudio-Aufnahme** — ein eigenes Recht, nicht die Bildschirmaufnahme; ein Bild wird nie aufgezeichnet. Der Kalender ordnet Aufnahmen dem Termin zu, die Mitteilung stellt vor jedem Mitschnitt die Rückfrage. Alles drei optional.")
                    .foregroundStyle(Theme.textSubtle)
                permissionRow(.systemAudio)
                permissionRow(.calendar)
                permissionRow(.notifications)
            }
        case .provider:
            pageBody(
                icon: "text.justify.left",
                title: "Zusammenfassung",
                text: "Meeting-Transkripte werden zu einer Notiz zusammengefasst — wahlweise über die Anthropic-API (Schlüssel im Schlüsselbund) oder über eine lokal installierte CLI: Claude Code, Gemini CLI oder Codex CLI. Lässt sich auch später einrichten; **Diktat funktioniert ohne**.",
                action: ("Einstellungen öffnen…", { openSettings() }))
        case .done:
            pageBody(
                icon: "checkmark.circle.fill",
                title: "Alles bereit",
                text: "Notable lebt in der Menüleiste — dort findest du Meeting-Aufnahme, Notizen, Statistik und Einstellungen. Die Notizen liegen als Markdown in **Dokumente/Notable**; den Ordner kannst du in den Einstellungen umlegen. Die LLM-Verbesserung für Diktate bleibt aus, bis du sie dort einschaltest.")
        }
    }

    private var firstDictationPage: some View {
        let done = dictation.lastDictationAt != nil
        return VStack(alignment: .leading, spacing: 16) {
            pageHeader(icon: "mic.fill", title: "Dein erstes Diktat")
            Text("Klick in ein Textfeld einer anderen App (z. B. TextEdit), halte die Taste **\(hotkeyLabel)**, sprich einen Satz und lass los. Der Text erscheint im Feld.")
                .foregroundStyle(Theme.textSubtle)
            HStack(spacing: 8) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(done ? Theme.success : Theme.textMuted)
                Text(done ? "Sitzt! Dein Diktat ist angekommen." : "Warte auf dein erstes Diktat…")
                    .foregroundStyle(done ? Theme.textEmphasis : Theme.textSubtle)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.top, 4)

            // On a cold cache the real model is still coming down. Saying so —
            // and saying that dictation already works — is the whole point of
            // the stand-in; a bare progress bar would just look like waiting.
            if dictation.isUsingBootstrap {
                Text(dictation.downloadProgress.map {
                    "Du kannst schon diktieren. Das große Modell lädt noch: \(Int($0 * 100)) % — danach wird es genauer."
                } ?? "Du kannst schon diktieren. Das große Modell lädt noch — danach wird es genauer.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSubtle)
            } else if dictation.modelState != .ready, let progress = dictation.downloadProgress {
                Text("ASR-Modell lädt: \(Int(progress * 100)) %")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSubtle)
            }
        }
    }

    // MARK: Building blocks

    private func pageBody(icon: String, title: String, text: String,
                          action: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            pageHeader(icon: icon, title: title)
            Text(.init(text)).foregroundStyle(Theme.textSubtle)
            if let action {
                Button(action.0) { action.1() }
            }
        }
    }

    private func pageHeader(icon: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textEmphasis)
        }
    }

    private func permissionPage(_ kind: PermissionsManager.Kind, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            pageHeader(icon: "mic", title: title)
            Text(text).foregroundStyle(Theme.textSubtle)
            permissionRow(kind)
        }
    }

    private func permissionRow(_ kind: PermissionsManager.Kind) -> some View {
        let status = permissions.status(of: kind)
        return HStack(spacing: 10) {
            Image(systemName: status.symbolName).foregroundStyle(status.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.name).foregroundStyle(Theme.textEmphasis)
                Text(status.label).font(.caption).foregroundStyle(Theme.textSubtle)
            }
            Spacer()
            if permissions.canPrompt(kind) {
                Button("Erlauben") { Task { await permissions.request(kind) } }
            } else if status != .granted {
                Button("Systemeinstellungen…") { permissions.openSystemSettings(for: kind) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
    }

    // MARK: Footer / navigation

    private var footer: some View {
        HStack {
            if page != .welcome {
                Button("Zurück") { pageRaw = max(0, pageRaw - 1) }
            }
            Spacer()
            // The dots were decoration. Every page here is skippable and none
            // depends on the one before it, so there is no reason to make
            // someone click "Weiter" five times to reach the page they want.
            HStack(spacing: 5) {
                ForEach(Page.allCases, id: \.rawValue) { p in
                    Button { pageRaw = p.rawValue } label: {
                        Circle()
                            .fill(p == page ? Theme.accent : Theme.textMuted.opacity(0.4))
                            .frame(width: 6, height: 6)
                    }
                    .buttonStyle(.plain)
                    .help(p.title)
                    .accessibilityLabel(p.title)
                }
            }
            Spacer()
            if page == .done {
                Button("Fertig") { finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                // The header comment claimed this was "skippable everywhere" long
                // before there was a way to skip. Someone who already knows the
                // app — or is reinstalling it — should not have to page through
                // permissions they granted years ago.
                Button("Überspringen") { finish() }
                Button("Weiter") { pageRaw = min(Page.allCases.count - 1, pageRaw + 1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    // MARK: Actions

    private var hotkeyLabel: String {
        HotkeySpec(rawValue: hotkeyRaw)?.label ?? HotkeySpec.rightOption.label
    }

    private func finish() {
        didComplete = true
        pageRaw = 0
        dismiss()
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Relaunch a fresh instance to pick up TCC grants macOS caches per-process
    /// (screen recording, input monitoring) — mirrors the Settings relaunch.
    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
