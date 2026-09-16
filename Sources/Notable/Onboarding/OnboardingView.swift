import AppKit
import SwiftUI

/// First-run walkthrough, **five steps** since Spec 38 §3.4: welcome, the three
/// permissions dictation needs, the first dictation, meetings, done.
///
/// Two pages went: "Zusammenfassung" asked nothing — it was three sentences and
/// a button to the settings — and "Notizen-Ordner" confirmed a default that has
/// been right since Spec 27. The folder is still created before the tour ends,
/// which is what the page was actually for; it just does not need a screen of
/// its own to do it. Skippable everywhere; the current page is persisted so a
/// relaunch (needed for input-monitoring and accessibility grants) resumes where
/// it left off.
struct OnboardingView: View {
    @EnvironmentObject private var permissions: PermissionsManager
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var notesFolder: NotesFolderManager
    @State private var folderError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @AppStorage(DefaultsKey.didCompleteOnboarding.key) private var didComplete = DefaultsKey.didCompleteOnboarding.fallback
    @AppStorage(DefaultsKey.onboardingPage.key) private var pageRaw = DefaultsKey.onboardingPage.fallback
    @AppStorage(HotkeySpec.storageKey) private var hotkeyRaw = HotkeySpec.rightOption.rawValue
    @AppStorage(DefaultsKey.typingWPM.key) private var typingWPM = DefaultsKey.typingWPM.fallback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    enum Page: Int, CaseIterable {
        case welcome, permissions, firstDictation, meetings, done

        /// Names the dots in the footer, so jumping straight to a page is a
        /// choice rather than a guess.
        var title: String {
            let key: String.LocalizationValue = switch self {
            case .welcome: "Willkommen"
            case .permissions: "Mikrofon & Taste"
            case .firstDictation: "Erstes Diktat"
            case .meetings: "Meetings"
            case .done: "Fertig"
            }
            return String(localized: key)
        }
    }

    /// A page number stored by an earlier, longer tour can be out of range —
    /// it falls back to the start rather than to nothing.
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
        // ⌘W and the red button are ways of saying "not now", and they used to
        // mean "ask me again at every launch, forever".
        .onDisappear { markSeen() }
    }

    // MARK: Pages

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome:
            pageBody(
                icon: "waveform",
                title: "Willkommen bei Notable",
                text: "Taste halten, sprechen, loslassen — der Text steht im Feld.",
                bullets: [
                    "Erkennung läuft auf deinem Mac",
                    "Audio verlässt das Gerät nie",
                    "Meeting-Notizen als Markdown-Datei",
                ])
        case .permissions:
            permissionsPage
        case .firstDictation:
            firstDictationPage
        case .meetings:
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                pageHeader(icon: "person.2.wave.2", title: "Meetings")
                Text("Optional. Notable erkennt Calls und fragt vorher.")
                    .foregroundStyle(Theme.textSubtle)
                permissionRow(.systemAudio)
                permissionRow(.calendar)
                permissionRow(.notifications)
                Text("„Systemaudio-Aufnahme“ ist der Ton der anderen — ein eigenes Recht, nicht die Bildschirmaufnahme. Ein Bild wird nie aufgezeichnet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
            }
        case .done:
            donePage
        }
    }

    /// The three rights dictation needs, on one page (§3.4).
    ///
    /// They were two pages, and the split was arbitrary: without all three there
    /// is no dictation, so the tour asked twice for one thing. "Weiter" is off
    /// until the microphone is granted (Spec 33 §3.5 stands), because "Alles
    /// bereit" without a microphone was a lie the tour told.
    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            pageHeader(icon: "mic", title: "Mikrofon & Taste")
            Text("Drei Rechte, dann einmal neu starten.")
                .foregroundStyle(Theme.textSubtle)
            permissionRow(.microphone)
            permissionRow(.inputMonitoring)
            permissionRow(.accessibility)
            if permissions.status(of: .microphone) != .granted {
                Text("„Weiter“ geht erst mit Mikrofon. Überspringen geht, dann funktioniert kein Diktat.")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
            Button("Notable neu starten") { relaunch() }
        }
    }

    /// The last page creates the notes folder (Spec 27 §3.4): if macOS asks for
    /// access to iCloud Drive, it asks now, with the reason on screen — not
    /// while the first meeting's note is being written. The page that used to
    /// do this is gone; the act it existed for is not.
    private var donePage: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            pageHeader(icon: "checkmark.circle.fill", title: "Alles bereit")
            Text("Notable wohnt in der Menüleiste.")
                .font(.title3)
                .foregroundStyle(Theme.textEmphasis)
            HStack(spacing: 10) {
                Image(nsImage: notesFolder.icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(notesFolder.readablePath).foregroundStyle(Theme.textEmphasis)
                    Text(notesFolder.sync.label).font(.caption).foregroundStyle(Theme.textSubtle)
                }
                Spacer()
                Button("Ändern…") { notesFolder.chooseFolder() }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl).strokeBorder(Theme.border, lineWidth: 1))
            if let folderError {
                Text(folderError).font(.callout).foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 7) {
                bullet("Hier liegt jede Meeting-Notiz als Markdown-Datei.")
                bullet("Zusammenfassungen brauchen einen Anbieter — Einstellungen › Meetings.")
                bullet("⌘, hat alles Weitere; die Verbesserung von Diktaten bleibt aus, bis du sie einschaltest.")
            }
        }
        .onAppear(perform: createFolder)
    }

    private var firstDictationPage: some View {
        let done = dictation.lastDictationAt != nil
        return VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            pageHeader(icon: "mic.fill", title: "Dein erstes Diktat")
            Text("In ein Textfeld einer anderen App klicken, **\(hotkeyLabel)** halten, einen Satz sprechen, loslassen.")
                .font(.title3)
                .foregroundStyle(Theme.textEmphasis)
            // The product explaining itself without a sentence of marketing
            // (Spec 37 §3.7) — and with this dictation's own numbers, not an
            // average from a website.
            firstDictationResult
            // The product showing itself (Spec 33 §3.5): the HUD's own waveform,
            // fed by the live input while the key is held — then what arrived.
            FirstDictationPreview(meter: dictation.meter, text: dictation.lastDictationText, done: done)

            // On a cold cache the real model is still coming down. Saying that
            // dictation already works is the whole point of the stand-in.
            if dictation.isUsingBootstrap {
                DownloadProgressRow(
                    fraction: dictation.downloadProgress,
                    caption: "Du kannst schon diktieren — danach wird es genauer."
                )
            } else if dictation.modelState != .ready {
                DownloadProgressRow(fraction: dictation.downloadProgress)
            }
        }
    }

    /// „23 Wörter in 6 s. Getippt: etwa 35 s."
    ///
    /// Only once a dictation has landed, and only when both halves are
    /// measured — without the recording's length the comparison would be half a
    /// claim. The typing figure is the assumption from the statistics window,
    /// the same one every "gespart" rests on.
    @ViewBuilder
    private var firstDictationResult: some View {
        let words = UsageMetrics.wordCount(dictation.lastDictationText ?? "")
        if words > 0, let seconds = dictation.lastAudioSeconds, seconds > 0 {
            let typed = Int(UsageMetrics.typingSeconds(words: words, typingWPM: typingWPM).rounded())
            Text("\(words) Wörter in \(Int(seconds.rounded())) s. Getippt: etwa \(typed) s.")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : Theme.Motion.gentle, value: words)
        }
    }

    // MARK: Building blocks

    /// One sentence, then facts as ticks.
    ///
    /// The pages used to carry a paragraph each — five or six lines of prose in
    /// a 540-point window, which is a wall nobody reads on the way to their
    /// first dictation. Everything that was in those paragraphs and still needs
    /// saying is now either a single line or a tick; everything else was
    /// documentation, and documentation belongs in the settings pane it
    /// describes.
    private func pageBody(icon: String, title: LocalizedStringKey, text: LocalizedStringKey,
                          bullets: [LocalizedStringKey] = []) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            pageHeader(icon: icon, title: title)
            Text(text)
                .font(.title3)
                .foregroundStyle(Theme.textEmphasis)
            if !bullets.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(bullets.enumerated()), id: \.offset) { _, text in
                        bullet(text)
                    }
                }
            }
        }
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.accent)
            Text(text).foregroundStyle(Theme.textSubtle)
        }
    }

    private func pageHeader(icon: String, title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.title.weight(.semibold))
                .foregroundStyle(Theme.textEmphasis)
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
        .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl).strokeBorder(Theme.border, lineWidth: 1))
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
            // someone click "Weiter" four times to reach the page they want.
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
                    .disabled(page == .permissions && permissions.status(of: .microphone) != .granted)
            }
        }
        .padding(14)
    }

    // MARK: Actions

    private var hotkeyLabel: String {
        HotkeySpec(rawValue: hotkeyRaw)?.label ?? HotkeySpec.rightOption.label
    }

    /// `ensureExists` throws and records rather than being `try?`-ed (Spec 27),
    /// so the failure is on screen here instead of surfacing during the first
    /// meeting.
    private func createFolder() {
        do {
            try notesFolder.ensureExists()
            folderError = nil
        } catch {
            folderError = notesFolder.lastError ?? error.localizedDescription
        }
    }

    private func finish() {
        // Skipping still leaves a folder behind: every path out of the tour
        // ends with somewhere for the notes to go.
        createFolder()
        didComplete = true
        pageRaw = 0
        dismiss()
    }

    /// Closing the window counts as finishing it.
    ///
    /// Only `finish()` used to set the flag, so ⌘W or the red button left it
    /// false — and `MenuBarLabel.onAppear` then reopened the tour on *every*
    /// launch, forever, with no way out but walking to the last page. "Einführung
    /// zeigen" in Einstellungen › Allgemein › Erweitert is the way back in.
    private func markSeen() {
        didComplete = true
    }

    /// Relaunch a fresh instance to pick up TCC grants macOS caches per-process
    /// (input monitoring, accessibility) — mirrors the Settings relaunch.
    private func relaunch() { AppRelauncher.relaunch() }
}

/// The first-dictation moment: a waiting state, the live waveform while the key
/// is held, and the text once it has landed.
private struct FirstDictationPreview: View {
    @ObservedObject var meter: LevelMeter
    let text: String?
    let done: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(done ? Theme.success : Theme.textMuted)
                Text(done ? "Sitzt! Dein Diktat ist angekommen." : "Warte auf dein erstes Diktat…")
                    .foregroundStyle(done ? Theme.textEmphasis : Theme.textSubtle)
                Spacer()
                WaveformView(level: meter.level, barCount: 24, maxHeight: 22, tint: Theme.accent)
            }
            .font(.body.weight(.medium))
            if done, let text {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(Theme.textEmphasis)
                    .lineLimit(4)
                    .padding(Theme.Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl).strokeBorder(Theme.border, lineWidth: 1))
            }
        }
    }
}
