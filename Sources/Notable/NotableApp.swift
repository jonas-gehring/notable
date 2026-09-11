import AppKit
import SwiftUI
import os

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
    /// `lazy` because it asks the rest of the app whether quitting now would
    /// lose anything (`UpdateWindow.hardLock`): a meeting, a note in the making,
    /// a dictation, an open draft (Spec 25).
    lazy var updateInstaller: UpdateInstaller = {
        let installer = UpdateInstaller(busyReason: { [unowned self] in UpdateWindow.hardLock(self.updateInputs()) })
        installer.beforeQuit = { [unowned self] info, unattended in
            UpdateMarkers.recordBeforeQuit(
                from: Self.runningVersion, to: info.version.description, notes: info.notes,
                unattended: unattended, windows: self.visibleWindowIDs()
            )
        }
        return installer
    }()
    let dictationHistory = DictationHistory()
    let usage = UsageSummary()
    let storageNotice = StorageNotice()
    /// Which settings pane to show. Set before opening the window, so a menu
    /// item can lead to the page it is about instead of to "Allgemein".
    let settingsRoute = SettingsRoute()

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

    /// False until `MenuBarLabel` has appeared — early in launch, nothing can be
    /// presented yet.
    var canPresentWindows: Bool { openWindowAction != nil }

    static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    // MARK: - Update moment (Spec 25)

    /// Everything `UpdateWindow` decides from, read fresh.
    func updateInputs() -> UpdateWindow.Inputs {
        UpdateWindow.Inputs(
            isRecording: meeting.state.isRecording,
            processingNotes: meeting.processingCount,
            dictationBusy: appState.captureState != .idle,
            draftOpen: notes.isEditingUserNotes,
            // `NSApp.windows` includes panels the user never sees (the dictation
            // overlay, the status item's own window), so only visible, titled
            // windows count.
            windowVisible: NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) },
            idleSeconds: SystemActivity.idleSeconds,
            screenLocked: SystemActivity.isScreenLocked
        )
    }

    /// The window scenes reopened after an update (§3.6). The live notes window
    /// is not among them: it belongs to a recording, and a recording is a hard
    /// lock, so it is never open when an update installs.
    static let restorableWindowIDs = ["notes", "search", "recent", "stats", "settings", "onboarding"]

    /// Which of those are open. SwiftUI names a `Window` scene's `NSWindow` after
    /// the scene id, possibly with a suffix — hence the prefix match.
    func visibleWindowIDs() -> [String] {
        let open = NSApp.windows
            .filter { $0.isVisible && $0.styleMask.contains(.titled) }
            .compactMap { $0.identifier?.rawValue }
        return Self.restorableWindowIDs.filter { id in open.contains { $0 == id || $0.hasPrefix(id + "-") } }
    }

    private init() {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let log = Logger(subsystem: "de.jonasgehring.notable", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let container = AppContainer.shared
        // Before anything loads a model: the weights used to live in a folder
        // named after a library the user never chose. A rename inside one
        // volume, so with nothing to do this costs a `fileExists`.
        ModelStorageMigration.run()
        container.dictation.start()
        // An unreachable notes folder is said now, and a lost folder icon put
        // back — without creating anything (Spec 27).
        container.notesFolder.refreshStatus()

        // Notification Center is the consent surface (Spec 09) — the delegate must
        // exist before anything is posted, and the authorization result decides
        // whether the panel fallback is used instead.
        NotificationCenterService.shared.registerCategoriesAndDelegate()
        Task {
            await NotificationCenterService.shared.requestAuthorizationIfNeeded()
            // After the authorization is known: posting before it is dropped.
            Self.announceCompletedUpdate()
        }
        restoreWindowsAfterUpdate(UpdateMarkers.consumeRestoreWindows(), attempts: 20)

        // Only the legacy fallback path uses the global mic bit; the per-process
        // detector filters our own capture by PID.
        container.detector.isOwnCaptureActive = {
            container.appState.captureState != .idle || container.meeting.state != .idle
        }
        // A recording started by hand *during* a detected call ends with the call.
        container.meeting.isCallActive = { container.detector.isCallActive }
        // The call's own microphone is the one to record (Spec 23).
        container.meeting.callProcess = {
            container.detector.callProcess.map { (name: $0.sourceName, bundleIDs: $0.processBundleIDs) }
        }
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
            // A paste that cannot happen has to say so — the text stays on the
            // clipboard, but the button looked like it had worked.
            if let error = container.dictationHistory.pasteLastEnhanced() {
                container.dictation.overlay.flashError(error.localizedDescription)
            }
        }

        // Surface the mic prompt on launch — without this the app never asks and
        // dictation silently captures nothing (mic stays "notDetermined").
        container.permissions.requestMicrophoneIfNeeded()

        // Throttled (once per 24h); silent on network/rate-limit errors. A find is
        // announced once per version — the menu shows it only to whoever opens the
        // menu, which is not a way to learn that an update exists.
        container.updateChecker.onUpdateFound = { version in
            NotificationCenterService.shared.postUpdateAvailable(version: version)
        }
        NotificationCenterService.shared.onOpenSettings = { pane in
            container.settingsRoute.requested = SettingsView.Pane(rawValue: pane)
            container.presentWindow("settings")
        }
        // "Jetzt installieren" on the 72-hour nudge — the manual path, with every
        // hard lock still in force.
        NotificationCenterService.shared.onInstallUpdateNow = {
            guard let found = container.updateChecker.available else { return }
            Task { await container.updateInstaller.installAndRelaunch(found) }
        }
        Task {
            await container.updateChecker.checkOnLaunch()
            await Self.prepareAndEvaluateUpdate()
        }
        // A menu-bar app runs for weeks; without this, an update found on Monday
        // waits for the next reboot.
        updateTimer = Timer.scheduledTimer(
            withTimeInterval: UpdateChecker.periodicInterval, repeats: true
        ) { _ in
            Task { @MainActor in
                await AppContainer.shared.updateChecker.checkPeriodically()
                await Self.prepareAndEvaluateUpdate()
            }
        }
        // Checking costs a request, waiting costs nothing (Spec 25 §3.2): once
        // an update is prepared, the moment is judged every minute and whenever
        // the screens sleep or the session is switched away from.
        updateMomentTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await Self.evaluateUpdateMoment() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in await Self.evaluateUpdateMoment() }
            }
        }

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
                // The flag is only set once the backfill actually succeeded.
                // `try?` followed by an unconditional `set(true)` meant one
                // transient failure — a locked database at launch — left those
                // word counts NULL for good, and the statistics quietly
                // understated every dictation from before the column existed.
                do {
                    try await RecordingStore.shared.backfillWordCounts()
                    UserDefaults.standard.set(true, forKey: "didBackfillWordCount")
                } catch {
                    AppDelegate.log.error("Wortzahl-Backfill fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                }
            }
            await container.usage.refresh()
            // After the spool recovery above, so the number is the one that is
            // actually on the disk now rather than the one from before.
            await container.storageNotice.refresh()
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

    /// Quitting must not lose a meeting or a note.
    ///
    /// ⌘Q, "Notable beenden" and the updater all went straight to
    /// `NSApp.terminate`, which ends the meeting the hard way and leaves the
    /// spool for the next launch to recover. Here the meeting is stopped
    /// properly first, and the quit resumes once **every** note in the making
    /// is written — a note still being transcribed or summarized used to be cut
    /// off too, and recovery then repeated minutes of work and paid for an API
    /// summary twice (Spec 25 §3.4).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let meeting = AppContainer.shared.meeting
        guard meeting.state != .idle else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in
            await meeting.stopAndAwaitNote()
            if meeting.processingCount > 0 {
                meeting.announceQuitAfterProcessing()
                await meeting.awaitProcessingFinished()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private var retentionTask: Task<Void, Never>?
    private var updateTimer: Timer?
    private var updateMomentTimer: Timer?
    private var terminationPending = false

    // MARK: - Updates (Spec 25)

    /// After a network check: download and verify a found update right away,
    /// then see whether now is the moment.
    @MainActor
    private static func prepareAndEvaluateUpdate() async {
        let container = AppContainer.shared
        guard let found = container.updateChecker.available,
              UpdateInstaller.automaticInstallEnabled() else { return }
        guard await container.updateInstaller.prepare(found) else {
            log.error("Update \(found.versionString, privacy: .public) ließ sich nicht vorbereiten")
            return
        }
        await evaluateUpdateMoment()
    }

    /// Installs a prepared update if `UpdateWindow` says nothing would be lost
    /// and nobody is using a Notable window; otherwise records why not.
    ///
    /// The user asked for an update that happens, not for a button that offers
    /// one — and the button is still there for whoever turns this off.
    @MainActor
    private static func evaluateUpdateMoment() async {
        let container = AppContainer.shared
        guard let found = container.updateChecker.available else { return }
        let decision = UpdateWindow.decide(container.updateInputs())
        guard let skipped = await container.updateInstaller.installUnattended(found, decision: decision) else { return }
        log.debug("Auto-Update wartet (\(skipped.logLabel, privacy: .public))")
        guard case .waiting(let reason) = skipped else { return }
        // Three days held back by open windows alone: ask once (§3.8).
        let since = UpdateMarkers.waitingSince(found.versionString)
        if UpdateWindow.shouldNudge(waitingSince: since, now: Date(), reason: reason,
                                    alreadyNudged: UpdateMarkers.wasNudged(found.versionString)),
           NotificationCenterService.shared.postUpdateNudge(version: found.versionString) {
            UpdateMarkers.markNudged(found.versionString)
        }
    }

    /// Says once that an update happened — or that it did not take (§3.7).
    @MainActor
    private static func announceCompletedUpdate() {
        switch UpdateMarkers.consumeOutcome(running: AppContainer.runningVersion) {
        case .installed(_, let to):
            NotificationCenterService.shared.postUpdateInstalled(version: to)
        case .failed(let target, let running):
            NotificationCenterService.shared.postUpdateFailed(target: target, running: running)
        case nil:
            break
        }
    }

    /// Reopens the windows that were open when the update quit the app —
    /// without activating, so nobody's focus is pulled into Notable (§3.6).
    /// The window opener registers a moment after launch, hence the retries.
    private func restoreWindowsAfterUpdate(_ ids: [String], attempts: Int) {
        guard !ids.isEmpty else { return }
        let container = AppContainer.shared
        guard container.canPresentWindows else {
            guard attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restoreWindowsAfterUpdate(ids, attempts: attempts - 1)
            }
            return
        }
        for id in ids { container.presentWindow(id, activate: false) }
    }
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
                .environmentObject(AppContainer.shared.storageNotice)
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
                .environmentObject(AppContainer.shared.notesFolder)
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
    @AppStorage(DefaultsKey.didCompleteOnboarding.key) private var didComplete = DefaultsKey.didCompleteOnboarding.fallback

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
    @EnvironmentObject private var storageNotice: StorageNotice
    @EnvironmentObject private var liveNotes: LiveNotesController
    @AppStorage(DefaultsKey.showNextMeeting.key) private var showNextMeeting = DefaultsKey.showNextMeeting.fallback
    @AppStorage(DefaultsKey.showUsageInMenu.key) private var showUsageInMenu = DefaultsKey.showUsageInMenu.fallback

    /// The header must never say "Bereit" while a meeting is being recorded —
    /// meeting state lives outside `appState.captureState`.
    private var statusLabel: String {
        switch meeting.state {
        case .recording: String(localized: "Meeting wird aufgezeichnet…")
        case .processing: String(localized: "Meeting wird verarbeitet…")
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
                String(localized: "Vorläufiges Modell aktiv — \(ASREngineID.current.shortLabel) lädt: \(Int($0 * 100)) %")
            } ?? String(localized: "Vorläufiges Modell aktiv — \(ASREngineID.current.shortLabel) lädt…"))
        } else if dictation.modelState != .ready {
            Text(dictation.downloadProgress.map { String(localized: "ASR-Modell lädt: \(Int($0 * 100)) %") }
                ?? dictation.modelState.label)
        }
        // Today's numbers at a glance; the window has the full picture. Omitted
        // entirely on a day with nothing to report (see UsageMetrics.menuLine).
        if showUsageInMenu, let usageLine = usage.line {
            Text(usageLine)
        }
        // Only above the threshold, and it leads somewhere: the page where the
        // retention rules are switched on. The line is a way to the decision,
        // never a substitute for it.
        if let storageLine = storageNotice.line {
            Button(storageLine) {
                AppContainer.shared.settingsRoute.requested = .storage
                open("settings")
            }
        }

        Divider()

        // Meeting
        Button(meeting.state.isRecording ? "Meeting beenden" : "Meeting aufzeichnen") {
            meeting.toggle()
        }
        .disabled(meeting.state == .processing)
        // No `.keyboardShortcut` on the items below.
        //
        // A status-item menu is not in the main menu's key-equivalent chain, so
        // these were never global shortcuts — they only worked while this menu
        // was already open, which is the one moment nobody needs them. Printing
        // "⌘⇧V" next to "Letztes Diktat einfügen" promised exactly the thing it
        // could not do: press it in the app you want the text in, and nothing
        // happens. ⌘, and ⌘Q stay, because macOS routes those itself.
        Button(liveNotes.isActive ? "Notizen zum Meeting…" : "Meeting-Notizen…") { open("meetingNotes") }
        if let next = nextEvent {
            Text("Nächstes: \(Self.nextEventLabel(next))")
        }
        // Which microphone is being recorded. Whoever reads "MacBook Pro
        // Microphone" with the lid shut needs no further diagnosis (Spec 23).
        if meeting.state.isRecording, let device = meeting.inputDeviceName {
            Text("Mikrofon: \(device)")
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
        Button("Letztes Diktat einfügen") {
            Task {
                do {
                    _ = try await history.pasteLast()
                } catch {
                    // Same reasoning as the notification path: the transcript is
                    // on the clipboard, and only this line says why nothing
                    // appeared in the field.
                    AppContainer.shared.dictation.overlay.flashError(error.localizedDescription)
                }
            }
        }
            .disabled(history.last == nil)
        Button("Letztes Diktat kopieren") { Task { await history.copyLast() } }
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
        } else {
            Menu("Letzte Diktate") {
                ForEach(history.recent.prefix(8)) { item in
                    Button(item.menuTitle) { Task { try? await history.paste(item.text) } }
                }
                Divider()
                Button("Alle anzeigen…") { open("recent") }
            }
        }

        Divider()

        // Notes & storage (folded into one submenu to stay compact)
        Menu("Notizen") {
            Button("Notizen verwalten…") { open("notes") }
            Button("Durchsuchen…") { open("search") }
            Button("Notizen-Ordner öffnen") {
                do {
                    try notesFolder.ensureExists()
                    NSWorkspace.shared.open(notesFolder.folderURL)
                } catch {
                    // To the page whose red line says why (Spec 27 §3.4).
                    AppContainer.shared.settingsRoute.requested = .general
                    open("settings")
                }
            }
            if let error = notesFolder.lastError {
                Text(error)
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
            // A menu item cannot host a progress bar, but it can carry the number,
            // and the number is the part that distinguishes "slow" from "stuck".
            if let fraction = updateInstaller.downloadProgress {
                Text("Update wird geladen — \(Int(fraction * 100)) %")
            } else {
                Text("Update wird geladen…")
            }
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
            Button("Version \(update.versionString) überspringen") {
                updateChecker.skip(update)
            }
        }
    }

    /// "15:00 Standup (in 12 min)" for the next-meeting line.
    static func nextEventLabel(_ event: CalendarMonitor.UpcomingEvent) -> String {
        let time = event.startDate.formatted(date: .omitted, time: .shortened)
        let minutes = Int(event.startDate.timeIntervalSinceNow / 60)
        let relative: String
        if minutes <= 0 { relative = String(localized: "jetzt") }
        else if minutes < 60 { relative = String(localized: "in \(minutes) min") }
        else { relative = String(localized: "in \(minutes / 60) h \(minutes % 60) min") }
        return "\(time) \(event.title) (\(relative))"
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
