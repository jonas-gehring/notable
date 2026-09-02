import AppKit
import SwiftUI

/// Composition root. A singleton container instead of scattered @StateObjects,
/// because the AppDelegate needs the same instances as the SwiftUI scenes.
@MainActor
final class AppContainer {
    static let shared = AppContainer()

    let appState = AppState()
    let permissions = PermissionsManager()
    let notesFolder = NotesFolderManager()
    let calendar = CalendarMonitor()
    let detector = MeetingDetector()
    let liveNotes = LiveNotesController()
    lazy var dictation = DictationController(appState: appState)
    lazy var meeting = MeetingController(notesFolder: notesFolder, calendar: calendar, liveNotes: liveNotes)
    lazy var notes = NoteManager(notesFolder: notesFolder)
    lazy var consent = ConsentCoordinator(meeting: meeting)
    let updateChecker = UpdateChecker()
    let updateInstaller = UpdateInstaller()
    let dictationHistory = DictationHistory()
    let usage = UsageSummary()

    /// SwiftUI's `openWindow` is only reachable from a `View`. `MenuBarLabel` is
    /// alive for the whole app lifetime, so it parks the action here — that is
    /// what lets a controller (e.g. the meeting start) present a window.
    private var openWindowAction: ((String, Bool) -> Void)?

    func registerWindowOpener(_ action: @escaping (String, Bool) -> Void) {
        openWindowAction = action
    }

    /// Opens (or fronts) a window scene by id. `activate: false` leaves the
    /// frontmost app frontmost — right for anything the app decides to show on
    /// its own, so it never yanks focus out of a running call.
    func presentWindow(_ id: String, activate: Bool = true) {
        openWindowAction?(id, activate)
    }

    private init() {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let container = AppContainer.shared
        container.dictation.start()

        // Notification Center is the consent surface (Spec 09) — the delegate must
        // exist before anything is posted, and the authorization result decides
        // whether the panel fallback is used instead.
        NotificationCenterService.shared.registerCategoriesAndDelegate()
        Task { await NotificationCenterService.shared.requestAuthorizationIfNeeded() }

        // Only the legacy fallback path uses the global mic bit; the per-process
        // detector filters our own capture by PID.
        container.detector.isOwnCaptureActive = {
            container.appState.captureState != .idle || container.meeting.state != .idle
        }
        // A recording started by hand *during* a detected call ends with the call.
        container.meeting.isCallActive = { container.detector.isCallActive }
        // Detection no longer records directly — it asks. The coordinator honours a
        // remembered choice or shows the non-activating consent prompt; only "Ja"
        // (or a remembered "immer") calls startAutomatically. The autoRecordMeetings
        // guard now lives inside the coordinator.
        container.detector.onMeetingStart = { candidate in
            container.consent.callDetected(candidate)
        }
        container.detector.onMeetingEnd = {
            container.consent.callEnded()
        }
        container.detector.start()

        // A crash mid-meeting leaves the spool on disk — recover it now.
        container.meeting.recoverOrphanedRecordings()

        // The notification's "Einfügen" button on an improved dictation.
        NotificationCenterService.shared.onPasteEnhanced = {
            container.dictationHistory.pasteLastEnhanced()
        }

        // Surface the mic prompt on launch — without this the app never asks and
        // dictation silently captures nothing (mic stays "notDetermined").
        container.permissions.requestMicrophoneIfNeeded()

        // Throttled (once per 24h); silent on network/rate-limit errors.
        Task { await container.updateChecker.checkOnLaunch() }

        // The native menu can't refresh history on open (its items are NSMenuItems),
        // so prime the recents/last list at launch; the dictation flow refreshes it
        // after each save.
        Task { await container.dictationHistory.refresh() }

        // One-time backfill of word counts for dictations recorded before the
        // usage-statistics column existed. Guarded so it runs at most once.
        // The menu's statistics line reads the same column, so it is refreshed
        // after the backfill rather than before it.
        Task {
            if !UserDefaults.standard.bool(forKey: "didBackfillWordCount") {
                try? await RecordingStore.shared.backfillWordCounts()
                UserDefaults.standard.set(true, forKey: "didBackfillWordCount")
            }
            await container.usage.refresh()
        }

        // Retention (issue #2). Deliberately **after** the spool recovery above:
        // the other order lets the runner delete a directory recovery is still
        // holding. Off until the user switches it on in Settings.
        startRetentionSchedule(container)
    }

    /// Runs the cleanup once at launch and then every 24 h. Never during a
    /// recording — a meeting in progress owns the disk.
    private func startRetentionSchedule(_ container: AppContainer) {
        retentionTask = Task {
            while !Task.isCancelled {
                if RetentionPolicy.isEnabled(), !container.meeting.state.isRecording {
                    let runner = RetentionRunner(store: .shared)
                    let policy = RetentionPolicy.fromDefaults()
                    await runner.run(runner.plan(policy: policy))
                }
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    private var retentionTask: Task<Void, Never>?
}

@main
struct NotableApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var appState = AppContainer.shared.appState
    @ObservedObject private var meeting = AppContainer.shared.meeting
    /// Re-renders `body` (and the menu-bar glyph) live when the user picks a
    /// different idle icon in Settings.
    @AppStorage(MenuBarIcon.storageKey) private var menuIconSymbol = MenuBarIcon.defaultSymbol

    /// One icon for every state — the menu-bar icon is the primary UI.
    private var menuSymbol: String {
        switch meeting.state {
        case .recording: "record.circle"
        case .processing: "hourglass.circle"
        case .idle:
            // Read the @AppStorage value directly (not UserDefaults) so SwiftUI
            // observes it and re-renders the label when the user picks a new icon.
            appState.captureState == .idle
                ? menuIconSymbol
                : appState.captureState.symbolName
        }
    }

    var body: some Scene {
        // Closure-based label: the string `systemImage:` initializer does NOT
        // refresh the status-item glyph when menuSymbol changes at runtime; an
        // Image in the label closure does.
        MenuBarExtra {
            MenuContentView()
                .environmentObject(appState)
                .environmentObject(AppContainer.shared.dictation)
                .environmentObject(AppContainer.shared.meeting)
                .environmentObject(AppContainer.shared.detector)
                .environmentObject(AppContainer.shared.notesFolder)
                .environmentObject(AppContainer.shared.updateChecker)
                .environmentObject(AppContainer.shared.updateInstaller)
                .environmentObject(AppContainer.shared.dictationHistory)
                .environmentObject(AppContainer.shared.usage)
                .environmentObject(AppContainer.shared.liveNotes)
        } label: {
            MenuBarLabel(symbol: menuSymbol)
        }
        // Native NSMenu dropdown: compact, system-styled. (Traded the earlier
        // .window panel's custom header/status-dot for nativeness — deliberate.)
        .menuBarExtraStyle(.menu)

        Window("Notizen durchsuchen", id: "search") {
            SearchWindowView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 440)

        Window("Notizen", id: "notes") {
            NoteListView()
                .environmentObject(AppContainer.shared.notes)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 480)

        Window("Letzte Diktate", id: "recent") {
            RecentDictationsView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 440)

        Window("Statistik", id: "stats") {
            StatsView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 640, height: 620)

        // Live notes for the running call. Small and floating on purpose — it
        // sits next to the meeting window, not in front of it.
        Window("Meeting-Notizen", id: "meetingNotes") {
            LiveNotesView()
                .environmentObject(AppContainer.shared.liveNotes)
                .environmentObject(AppContainer.shared.meeting)
        }
        .defaultSize(width: 380, height: 320)
        .windowResizability(.contentMinSize)

        Window("Willkommen", id: "onboarding") {
            OnboardingView()
                .environmentObject(AppContainer.shared.permissions)
                .environmentObject(AppContainer.shared.dictation)
        }
        .windowResizability(.contentSize)

        // A regular Window, not the SwiftUI `Settings` scene: from a MenuBarExtra
        // (accessory app) the Settings scene can only be opened via SettingsLink,
        // which creates the window *behind* the frontmost app and gives no reliable
        // hook to bring it forward (showSettingsWindow: no-ops here, and a menu
        // item's .simultaneousGesture never fires in the NSMenu). A plain Window
        // opens through the same openWindow(id:)+activate path as the other windows,
        // which already come to the front reliably.
        Window("Einstellungen", id: "settings") {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(AppContainer.shared.dictation)
                .environmentObject(AppContainer.shared.permissions)
                .environmentObject(AppContainer.shared.notesFolder)
                .environmentObject(AppContainer.shared.updateChecker)
                .environmentObject(AppContainer.shared.updateInstaller)
        }
        .defaultSize(width: 760, height: 520)
        .windowResizability(.contentMinSize)
    }
}

/// The menu-bar status glyph. Being always alive, its onAppear is also the
/// reliable place to open the onboarding window once, on a fresh install.
struct MenuBarLabel: View {
    let symbol: String
    @Environment(\.openWindow) private var openWindow
    @AppStorage("didCompleteOnboarding") private var didComplete = false

    var body: some View {
        Image(systemName: symbol)
            .onAppear {
                // The one long-lived View in the app: hand its `openWindow`
                // action to the container so controllers can present windows.
                AppContainer.shared.registerWindowOpener { id, activate in
                    openWindow(id: id)
                    if activate { NSApp.activate(ignoringOtherApps: true) }
                }
                guard !didComplete else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    openWindow(id: "onboarding")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

/// Native menu-bar dropdown (`.menuBarExtraStyle(.menu)`): a real macOS NSMenu of
/// SwiftUI `Button`/`Toggle`/`Menu`/`Divider`/disabled `Text` items. Compact and
/// system-styled — no custom header, status dot, or hover cards (those need the
/// `.window` style). Live recents/last stay current because the dictation flow
/// refreshes `DictationHistory` on save and at launch, not on menu open (a `.menu`
/// dropdown is built as NSMenuItems, so `onAppear` there is unreliable).
struct MenuContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var meeting: MeetingController
    @EnvironmentObject private var notesFolder: NotesFolderManager
    @EnvironmentObject private var updateChecker: UpdateChecker
    @EnvironmentObject private var updateInstaller: UpdateInstaller
    @EnvironmentObject private var history: DictationHistory
    @EnvironmentObject private var usage: UsageSummary
    @EnvironmentObject private var liveNotes: LiveNotesController
    @AppStorage("showNextMeeting") private var showNextMeeting = true
    @AppStorage("showUsageInMenu") private var showUsageInMenu = true

    /// The header must never say "Bereit" while a meeting is being recorded —
    /// meeting state lives outside `appState.captureState`.
    private var statusLabel: String {
        switch meeting.state {
        case .recording: "Meeting wird aufgezeichnet…"
        case .processing: "Meeting wird verarbeitet…"
        case .idle: appState.captureState.label
        }
    }

    /// Recomputed on every body evaluation (the menu rebuilds when it opens),
    /// so no stored state or refresh timer is needed.
    private var nextEvent: CalendarMonitor.UpcomingEvent? {
        showNextMeeting ? AppContainer.shared.calendar.nextEvent() : nil
    }

    var body: some View {
        // Status line + any setup notice (render as disabled menu items).
        Text(statusLabel)
        if let error = dictation.setupError {
            Text("⚠︎ \(error)")
        } else if dictation.isUsingBootstrap {
            // Not "loading" — dictation works right now, just not at full
            // quality. Those are different statements and the menu should not
            // blur them.
            Text(dictation.downloadProgress.map {
                "Vorläufiges Modell aktiv — \(ASREngineID.current.shortLabel) lädt: \(Int($0 * 100)) %"
            } ?? "Vorläufiges Modell aktiv — \(ASREngineID.current.shortLabel) lädt…")
        } else if dictation.modelState != .ready {
            Text(dictation.downloadProgress.map { "ASR-Modell lädt: \(Int($0 * 100)) %" }
                ?? dictation.modelState.label)
        }
        // Today's numbers at a glance; the window has the full picture. Omitted
        // entirely on a day with nothing to report (see UsageMetrics.menuLine).
        if showUsageInMenu, let usageLine = usage.line {
            Text(usageLine)
        }

        Divider()

        // Meeting
        Button(meeting.state.isRecording ? "Meeting beenden" : "Meeting aufzeichnen") {
            meeting.toggle()
        }
        .disabled(meeting.state == .processing)
        Button(liveNotes.isActive ? "Notizen zum Meeting…" : "Meeting-Notizen…") { open("meetingNotes") }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        if let next = nextEvent {
            Text("Nächstes: \(Self.nextEventLabel(next))")
        }
        if let message = meeting.statusMessage {
            Text(message)
        }
        if let url = meeting.lastNoteURL {
            Button("Letzte Notiz öffnen") { NSWorkspace.shared.open(url) }
        }
        if meeting.summaryRetry != nil {
            Button("Zusammenfassung nachholen") { meeting.retrySummary() }
                .disabled(meeting.state != .idle)
        }

        Divider()

        // Dictation
        Button("Letztes Diktat einfügen") { Task { try? await history.pasteLast() } }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(history.last == nil)
        Button("Letztes Diktat kopieren") { Task { await history.copyLast() } }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(history.last == nil)
        // Only present once the feature has been switched on — the switch is the
        // consent, so an unconfigured install offers no way to send text out.
        if EnhancementSettings.isEnabled {
            Menu("Letztes Diktat verbessern") {
                ForEach(EnhancementProfile.all()) { profile in
                    Button(profile.title) {
                        Task {
                            let result = await history.enhanceLast(profile: profile)
                            guard let result else { return }
                            if result.didEnhance {
                                NotificationCenterService.shared.postDictationEnhanced(
                                    id: "dictation.enhanced",
                                    preview: DictationHistory.menuTitle(for: result.text, limit: 80)
                                )
                            }
                        }
                    }
                }
            }
            .disabled(history.last == nil)
        }
        if history.recent.isEmpty {
            Button("Letzte Diktate…") { open("recent") }
                .keyboardShortcut("r", modifiers: [.command])
        } else {
            Menu("Letzte Diktate") {
                ForEach(history.recent.prefix(8)) { item in
                    Button(item.menuTitle) { Task { try? await history.paste(item.text) } }
                }
                Divider()
                Button("Alle anzeigen…") { open("recent") }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Divider()

        // Notes & storage (folded into one submenu to stay compact)
        Menu("Notizen") {
            Button("Notizen verwalten…") { open("notes") }
            Button("Durchsuchen…") { open("search") }
                .keyboardShortcut("f", modifiers: [.command])
            Button("Notizen-Ordner öffnen") {
                try? notesFolder.ensureExists()
                NSWorkspace.shared.open(notesFolder.folderURL)
            }
        }
        // Top level, not buried in the submenu: the statistics line above is the
        // glance, this is the way in.
        Button("Statistik…") { open("stats") }

        Divider()
        Button("Einstellungen…") { open("settings") }
            .keyboardShortcut(",", modifiers: [.command])
        updateSection
        Button("Notable beenden") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: [.command])
    }

    /// The update entry sits between Einstellungen and Beenden — the place the
    /// eye goes last, and where a menu-bar app is expected to keep it.
    ///
    /// A `.menu` MenuBarExtra closes on click, so the *result* of a manual check
    /// can only be seen the next time the menu opens. Without a line saying so,
    /// "Nach Updates suchen" would be indistinguishable from a no-op whenever
    /// there is nothing to install — the exact silent failure the rest of this
    /// app avoids. An error is therefore always stated, and a successful check
    /// confirms itself for `resultWindow` afterwards and then gets out of the way.
    @ViewBuilder
    private var updateSection: some View {
        if let update = updateChecker.available {
            updateItems(update)
        } else if updateChecker.isChecking {
            Text("Suche nach Updates…")
        } else {
            Button("Nach Updates suchen") { Task { await updateChecker.check() } }
            if let error = updateChecker.lastError {
                Text(error)
            } else if let checked = updateChecker.lastChecked,
                      Date().timeIntervalSince(checked) < Self.resultWindow {
                Text("Notable \(Self.currentVersionString) ist aktuell (\(checked.formatted(date: .omitted, time: .shortened)))")
            }
        }
    }

    /// How long a completed check keeps confirming itself in the menu.
    private static let resultWindow: TimeInterval = 5 * 60

    private static var currentVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    @ViewBuilder
    private func updateItems(_ update: UpdateInfo) -> some View {
        switch updateInstaller.phase {
        case .downloading:
            Text("Update wird geladen…")
        case .unpacking:
            Text("Update wird entpackt…")
        case .installing:
            Text("Wird installiert, Neustart…")
        case let .failed(message):
            Text("Update fehlgeschlagen: \(message)")
            Button("Update \(update.versionString) erneut installieren") {
                Task { await updateInstaller.installAndRelaunch(update) }
            }
        case .idle:
            Button("Update \(update.versionString) installieren") {
                Task { await updateInstaller.installAndRelaunch(update) }
            }
        }
    }

    /// "15:00 Standup (in 12 min)" for the next-meeting line.
    static func nextEventLabel(_ event: CalendarMonitor.UpcomingEvent) -> String {
        let time = event.startDate.formatted(date: .omitted, time: .shortened)
        let minutes = Int(event.startDate.timeIntervalSinceNow / 60)
        let relative: String
        if minutes <= 0 { relative = "jetzt" }
        else if minutes < 60 { relative = "in \(minutes) min" }
        else { relative = "in \(minutes / 60) h \(minutes % 60) min" }
        return "\(time) \(event.title) (\(relative))"
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
