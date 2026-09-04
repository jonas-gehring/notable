import AppKit
import Foundation
import os

/// Manual meeting recording (Phase 4 first stage; auto-detection follows).
/// Records mic + system audio, then runs the on-device pipeline and writes
/// the Markdown note; summarization uses the provider chosen in Settings.
@MainActor
final class MeetingController: ObservableObject {
    private static let log = Logger(subsystem: "de.jonasgehring.notable", category: "meeting")

    enum State: Equatable {
        case idle
        case recording(since: Date)
        case processing

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    /// **Capture and processing are separate states**, and that is the whole
    /// point of this split.
    ///
    /// They used to be one enum, so producing the previous note — 30–60 s of ASR
    /// per hour of audio plus up to two LLM round-trips — blocked the next
    /// recording outright. The detector's `.started` for the following call is a
    /// one-shot: `startAutomatically` returned silently, nothing retried, and a
    /// back-to-back meeting was simply not recorded. Nothing in `produceNote`
    /// needs the controller to be busy — it works from values captured at
    /// `stop()` — so a capture may begin while any number of notes are still
    /// being written.
    enum Capture: Equatable {
        case idle
        case recording(since: Date)
    }

    @Published private(set) var capture: Capture = .idle
    /// How many notes are still being produced. Recovery and stopped meetings
    /// both count; the UI only asks whether it is more than zero.
    @Published private(set) var processingCount = 0

    /// The combined state the interface reads. Recording wins over processing:
    /// a running capture is what the user needs to see.
    var state: State {
        switch capture {
        case .recording(let since): .recording(since: since)
        case .idle: processingCount > 0 ? .processing : .idle
        }
    }
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastNoteURL: URL?
    /// Set when a note was written but its summary failed — retryable.
    @Published private(set) var summaryRetry: RetryPayload?

    struct RetryPayload: Sendable {
        var recordingID: String
        var note: MarkdownProjector.Note
        var fileURL: URL
        var transcript: String
        var context: MeetingContext
    }

    private let micRecorder = AudioRecorder()
    private let systemTap = SystemAudioTap()
    private let notesFolder: NotesFolderManager
    private let calendar: CalendarMonitor
    /// Notes typed while the call runs. Owned by the container so the notes
    /// window and this controller share one buffer; consumed on stop().
    let liveNotes: LiveNotesController
    private var systemTapActive = false
    /// Live guard against a mic that is being recorded but delivers nothing —
    /// see `TrackSilence`. Runs only until the first sound is heard.
    private var micWatchdog: Timer?
    private var startedAutomatically = false
    /// True when this recording belongs to a detected call — either auto-started
    /// or started by hand *while* a call was running. Both must end with the
    /// call; a recording made with no call in sight (a voice memo) must not.
    private var startedDuringCall = false

    /// Injected from the container (`MeetingDetector.isCallActive`).
    var isCallActive: () -> Bool = { false }
    private var currentEvent: CalendarMonitor.EventMatch?
    private var currentSpool: SpoolStore.Session?

    init(notesFolder: NotesFolderManager, calendar: CalendarMonitor, liveNotes: LiveNotesController) {
        self.notesFolder = notesFolder
        self.calendar = calendar
        self.liveNotes = liveNotes
        micRecorder.onConfigurationChange = { [weak self] in
            Task { @MainActor in
                guard let self, self.state.isRecording else { return }
                do {
                    try self.micRecorder.resume()
                    self.statusMessage = String(localized: "Audiogerät gewechselt — Aufnahme fortgesetzt.")
                } catch {
                    self.statusMessage = String(localized: "Audiogerät gewechselt — Mikrofonspur ab hier unvollständig.")
                }
            }
        }
        observeWake()
        // A tap that cannot be rebuilt after an output-device switch means the
        // remote side is no longer being recorded — a silent half-meeting looks
        // exactly like a successful one, so say it out loud.
        systemTap.onRebuildFailure = { [weak self] error in
            Task { @MainActor in
                guard let self, self.state.isRecording else { return }
                // systemTapActive stays true on purpose: stop() must still
                // drain the spool, or the audio captured before the switch
                // would be thrown away too.
                self.statusMessage = String(localized: "System-Audio nach Gerätewechsel verloren — ab hier nur Mikrofon: \(error.localizedDescription)")
            }
        }
    }

    /// Closing the lid mid-call used to shorten the system track by the whole
    /// sleep.
    ///
    /// The two tracks lose time for different reasons and get it back through
    /// different paths: the mic engine usually posts an
    /// `AVAudioEngineConfigurationChange` on wake and `resume()` pads it, while
    /// the tap is handed no default-output-device change and so was never
    /// rebuilt or padded. From then on the system track was short by the sleep
    /// duration, every later segment was stamped too early, and the merge
    /// attributed the wrong speaker for the rest of the meeting. Padding both
    /// tracks here is idempotent — `padGapToWallClock` ignores anything under
    /// 100 ms, so the track that already healed itself is left alone.
    private func observeWake() {
        wakeObserver.token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.isRecording else { return }
                self.micRecorder.padGapToWallClock()
                self.systemTap.padGapToWallClock()
                self.systemTap.rebuildAfterInterruption()
                self.statusMessage = String(localized: "Aus dem Ruhezustand zurück — Aufnahme fortgesetzt.")
            }
        }
    }

    /// Holds the wake observer so it is removed when this controller goes away.
    ///
    /// A box rather than a stored token plus `deinit`: `deinit` is nonisolated,
    /// and a `@MainActor` property cannot be read from there. The box keeps the
    /// centre it registered with, so its own deinit touches no global.
    private final class ObserverBox: @unchecked Sendable {
        private let center: NotificationCenter
        var token: NSObjectProtocol?
        init(center: NotificationCenter) { self.center = center }
        deinit { if let token { center.removeObserver(token) } }
    }

    private let wakeObserver = ObserverBox(center: NSWorkspace.shared.notificationCenter)

    func toggle() {
        switch capture {
        case .idle: start(auto: false)
        case .recording: stop()
        }
    }

    /// Why an automatic start did not happen. Returned rather than swallowed:
    /// `ConsentCoordinator` marks itself `.recording` the moment the user taps
    /// "Aufnehmen" in the notification, so a silent no-op left them believing a
    /// call was being recorded that was not.
    enum StartRefusal: Equatable {
        /// A recording is already running (manual or automatic).
        case alreadyRecording
        /// The microphone could not be opened; `statusMessage` says why.
        case captureFailed
    }

    /// Auto-detection entry point (MeetingDetector). Returns `nil` on success.
    @discardableResult
    func startAutomatically(source: String) -> StartRefusal? {
        guard case .idle = capture else { return .alreadyRecording }
        start(auto: true)
        guard capture != .idle else { return .captureFailed }
        // A warning from start() (no system audio, mic failure) outranks the
        // "recording" confirmation — never overwrite it.
        if statusMessage == nil {
            statusMessage = String(localized: "Meeting erkannt (\(source)) — Aufnahme läuft.")
        }
        return nil
    }

    /// Called when the detector says the call is over. Stops both auto-started
    /// recordings and manual ones that were started during the call — clicking
    /// "Später" and then recording from the menu used to leave a recording that
    /// never ended.
    func stopAutomatically() {
        guard capture != .idle, startedAutomatically || startedDuringCall else { return }
        stop()
    }

    private func start(auto: Bool) {
        guard case .idle = capture else { return }
        statusMessage = nil
        startedAutomatically = auto
        startedDuringCall = auto || isCallActive()
        // One start instant for the spool meta, the recording state and the
        // live-notes clock — three separate `Date()` calls used to drift apart.
        let startedAt = Date()

        // Calendar attribution: ask once, then match the running event.
        Task {
            let granted = await calendar.requestAccessIfNeeded()
            guard capture != .idle else { return } // stop() already consumed the event
            currentEvent = granted ? calendar.currentEvent() : nil
            if let title = currentEvent?.title { liveNotes.updateTitle(title) }
            if let spool = currentSpool {
                let meta = SpoolStore.Meta(
                    startedAt: recordingStartedFallback(spool: spool),
                    eventTitle: currentEvent?.title,
                    eventID: currentEvent?.eventIdentifier
                )
                try? JSONEncoder().encode(meta).write(to: spool.metaURL, options: .atomic)
            }
        }

        // Spool to disk so a crash cannot lose the meeting. RAM fallback
        // if the spool cannot be created.
        currentSpool = try? SpoolStore.create(meta: SpoolStore.Meta(startedAt: startedAt))

        // Degradations are collected, not overwritten — losing echo cancellation
        // AND system audio are two separate things the user must both hear.
        var warnings: [String] = []

        do {
            // Echo cancellation (VPIO): without headphones the remote voices come
            // back in through this mic, and the echo fuses with the user's own
            // speech in the VAD — the note then has him saying the other side's
            // words. BUT: VPIO was the confirmed cause of the "0-segment" bug —
            // with only an input tap and no output render it gated BOTH tracks to
            // digital silence (mic.pcm/system.pcm measured all zeros, manual and
            // auto recordings alike). Default is now OFF, so meetings use the same
            // proven capture path as dictation; the toggle re-enables it (with the
            // AudioRecorder output-render fix) for speaker-without-headphones use.
            // See memory `meeting-empty-transcript-capture-bug`.
            let echoCancellation = UserDefaults.standard.object(forKey: "meetingEchoCancellation") as? Bool ?? false
            try micRecorder.start(spoolingTo: currentSpool?.micURL, voiceProcessing: echoCancellation)
            if echoCancellation, let reason = micRecorder.voiceProcessingError {
                warnings.append(String(localized: "ohne Echo-Unterdrückung (\(reason)) — bei Lautsprecher-Ton kann die Gegenseite doppelt im Transkript landen"))
            }
        } catch {
            statusMessage = String(localized: "Meeting-Start fehlgeschlagen: \(error.localizedDescription)")
            _ = micRecorder.stop() // closes a spool handle reset() may have opened
            if let currentSpool { SpoolStore.remove(currentSpool) }
            currentSpool = nil
            return
        }

        // System audio is the point of meeting capture — but a denied tap
        // permission should not lose the meeting. Record mic-only, loudly.
        do {
            try systemTap.start(spoolingTo: currentSpool?.systemURL)
            systemTapActive = true
        } catch {
            systemTapActive = false
            warnings.append(String(localized: "ohne System-Audio, nur Mikrofon (\(error.localizedDescription))"))
        }

        if !warnings.isEmpty {
            statusMessage = String(localized: "Aufnahme läuft eingeschränkt: ") + warnings.joined(separator: "; ") + "."
        }
        capture = .recording(since: startedAt)
        startMicWatchdog()

        // Live notes open for business: the buffer is bound to this recording's
        // spool from here until stop() consumes it.
        liveNotes.begin(startedAt: startedAt, title: currentEvent?.title ?? String(localized: "Meeting"), spool: currentSpool)
        if UserDefaults.standard.object(forKey: "openNotesOnMeetingStart") as? Bool ?? true {
            // Non-activating: the notes window floats above the call anyway, and
            // yanking focus out of Zoom the moment a meeting is detected is not
            // something a detector should do.
            AppContainer.shared.presentWindow("meetingNotes", activate: false)
        }
    }

    /// Says it out loud when the microphone is open but delivering digital
    /// silence.
    ///
    /// Both meeting-capture regressions so far were exactly this and neither was
    /// noticed during the call — the recording indicator was on, the note came
    /// out readable, and only the missing half of the conversation gave it away
    /// afterwards (see `TrackSilence`). A dead mic is worth interrupting for:
    /// re-granting the permission takes seconds *during* the call and nothing
    /// afterwards can recover the audio.
    ///
    /// Polls the meter rather than the buffer (a snapshot copies the whole
    /// recording) and stops at the first sound, so the common case costs one
    /// float read per second for a few seconds.
    private func startMicWatchdog() {
        stopMicWatchdog()
        let deadline = Date().addingTimeInterval(Self.micSilenceGrace)
        // The timer itself is never touched from inside the hop (it is not
        // Sendable); stopping means clearing `micWatchdog` on the main actor,
        // which is the only owner of it.
        // `.common`, not the default mode: a timer in the default mode stands
        // still for as long as the menu-bar menu is open, which is exactly when
        // someone is looking for the warning. The detector's timer already does
        // this correctly.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.capture != .idle else {
                    self?.stopMicWatchdog()
                    return
                }
                // `level` is the chunk **RMS**, so it is compared against the RMS
                // threshold. Judging it by `peakThreshold` — calibrated for a
                // peak, and necessarily larger than the RMS of the same signal —
                // made the live check stricter than the one `produceNote` runs,
                // so a genuinely quiet interface could raise an alarm the final
                // verdict then contradicted.
                if self.micRecorder.level > TrackSilence.liveRMSThreshold {
                    self.stopMicWatchdog()
                    return
                }
                guard Date() >= deadline else { return }
                self.stopMicWatchdog()
                self.statusMessage = String(localized: "Mikrofon liefert nur Stille — deine eigene Stimme wird nicht aufgezeichnet.")
                    + " "
                    + String(localized: "Mikrofon-Berechtigung für Notable prüfen (Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon).")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        micWatchdog = timer
    }

    private func stopMicWatchdog() {
        micWatchdog?.invalidate()
        micWatchdog = nil
    }

    /// How long the mic may stay silent before that counts as a fault. Long
    /// enough to cover joining a call in silence, short enough to still be
    /// actionable while it runs.
    private static let micSilenceGrace: TimeInterval = 20

    /// startedAt from the existing meta, so the async calendar update does
    /// not shift the recording's timestamp.
    private func recordingStartedFallback(spool: SpoolStore.Session) -> Date {
        if let data = try? Data(contentsOf: spool.metaURL),
           let meta = try? JSONDecoder().decode(SpoolStore.Meta.self, from: data) {
            return meta.startedAt
        }
        return Date()
    }

    /// The note production started by the most recent `stop()`.
    ///
    /// Only the quit path awaits it: ⌘Q used to kill the capture outright and
    /// leave the meeting to next-launch spool recovery.
    private var processingTask: Task<Void, Never>?

    /// Stops a running capture and returns once its note has been written.
    func stopAndAwaitNote() async {
        guard capture != .idle else { return }
        stop()
        await processingTask?.value
    }

    /// Everything that happens once a note has been produced — for a stopped
    /// meeting and for a recovered one alike.
    ///
    /// It was written twice, and the copies had drifted: the recovery branch
    /// reported only "wiederhergestellt" or "ohne erkannten Sprachinhalt" and
    /// dropped `captureWarning` and `summaryError` on the floor. A recovered
    /// meeting whose mic had been silent therefore said nothing about it — and
    /// a failed summary set `summaryRetry` without a single line saying why the
    /// note had none. `CLAUDE.md` claims `produceNote` "puts the warning in the
    /// status line and the notification"; for half the callers that was untrue.
    private func handle(
        outcome: NoteOutcome,
        spool: SpoolStore.Session?,
        userNotes: String?,
        recovered: Bool
    ) {
        lastNoteURL = outcome.url
        // Never clobber a pending retry from another note — only this note's
        // own outcome may replace it.
        if outcome.retry != nil || summaryRetry?.fileURL == outcome.url {
            summaryRetry = outcome.retry
        }
        AppContainer.shared.usage.refreshSoon()

        guard outcome.producedTranscript else {
            // No speech recognized despite a recording — almost always a capture
            // failure (denied system-audio TCC, or VPIO gating the mic during a
            // call). Keep the raw tracks instead of deleting them, so the failure
            // is diagnosable rather than a silent empty note.
            if let spool { SpoolStore.markFailed(spool) }
            // The note file was still written, so notes typed during the call are
            // in the Inbox even when the audio yielded nothing.
            let notesPart = userNotes == nil
                ? ""
                : String(localized: "Notizen gespeichert: \(outcome.url.lastPathComponent). ")
            statusMessage = notesPart
                + String(localized: "Kein Sprachinhalt erkannt — Rohaufnahme unter spool-failed gesichert.")
                + " "
                + String(localized: "Systemaudio-Berechtigung und Mikrofon (Echo-Unterdrückung) prüfen.")
            notifyReady(title: String(localized: "Kein Sprachinhalt erkannt"),
                        body: String(localized: "Rohaufnahme gesichert. Systemaudio-Berechtigung und Mikrofon prüfen."),
                        noteURL: nil)
            return
        }

        if let spool { SpoolStore.archive(spool) }
        let saved = recovered
            ? String(localized: "Unterbrochene Aufnahme wiederhergestellt: \(outcome.url.lastPathComponent)")
            : String(localized: "Notiz gespeichert: \(outcome.url.lastPathComponent)")
        // The capture warning leads: a transcript missing one side still looks
        // finished, and only this line says otherwise.
        statusMessage = (outcome.captureWarning.map { $0 + " " } ?? "")
            + (outcome.summaryError.map { String(localized: "Notiz gespeichert, aber ohne Zusammenfassung: \($0)") } ?? saved)

        if let captureWarning = outcome.captureWarning {
            notifyReady(title: String(localized: "Aufnahme unvollständig"),
                        body: captureWarning, noteURL: outcome.url)
        } else if let summaryError = outcome.summaryError {
            notifyReady(title: String(localized: "Notiz gespeichert — ohne Zusammenfassung"),
                        body: String(localized: "\(summaryError) — im Menü erneut versuchen."),
                        noteURL: outcome.url)
        } else {
            notifyReady(title: recovered
                            ? String(localized: "Unterbrochene Aufnahme wiederhergestellt")
                            : String(localized: "Zusammenfassung fertig"),
                        body: outcome.url.deletingPathExtension().lastPathComponent,
                        noteURL: outcome.url)
        }
        Self.runMeetingHook(noteURL: outcome.url)
    }

    private func stop() {
        guard case .recording(let startedAt) = capture else { return }

        stopMicWatchdog()
        // Both tracks are padded to the wall clock before they are read, so
        // they end at the same length no matter which one lost time and why.
        micRecorder.padGapToWallClock()
        let micSamples = micRecorder.stop()
        let droppedBuffers = systemTapActive ? systemTap.droppedBuffers : 0
        let systemSamples = systemTapActive ? systemTap.stop() : []
        systemTapActive = false
        startedAutomatically = false
        startedDuringCall = false
        let event = currentEvent
        currentEvent = nil
        let spool = currentSpool
        currentSpool = nil
        // Consume the notes typed during the call. finish() flushes them into the
        // spool first, so a processing failure that defers this meeting to
        // next-launch recovery still finds them there.
        let userNotes = liveNotes.finish()
        // Capture is over the moment the tracks are drained — the next call may
        // start recording right now, while this note is still being produced.
        capture = .idle
        processingCount += 1
        statusMessage = String(localized: "Verarbeite Aufnahme…")

        let providerID = UserDefaults.standard.string(forKey: "summarizationProvider")
            ?? SummarizationProviderID.anthropicAPI.rawValue
        try? notesFolder.ensureExists()
        let folderURL = notesFolder.folderURL

        // A dropped tap buffer is lost audio, and losing it shortens the system
        // track against the wall clock — which is how a long meeting ends up
        // with the wrong speaker on every later segment. Say it rather than
        // leaving it in a counter nobody reads.
        if droppedBuffers > 0 {
            Self.log.error("System-Audio: \(droppedBuffers, privacy: .public) Puffer verworfen")
        }

        processingTask = Task {
            do {
                let note = try await Self.produceNote(
                    micSamples: micSamples,
                    systemSamples: systemSamples,
                    startedAt: startedAt,
                    providerID: providerID,
                    folderURL: folderURL,
                    event: event,
                    userNotes: userNotes,
                    spool: spool
                )
                handle(outcome: note, spool: spool, userNotes: userNotes, recovered: false)
            } catch {
                // Spool stays on disk — the next launch retries via recovery.
                statusMessage = String(localized: "Meeting-Verarbeitung fehlgeschlagen: \(error.localizedDescription)")
                notifyReady(title: String(localized: "Meeting-Verarbeitung fehlgeschlagen"),
                            body: error.localizedDescription, noteURL: nil)
            }
            processingCount -= 1
        }
    }

    /// Recovers spooled recordings a crash left behind, one at a time.
    ///
    /// Only the *capture* has to be idle — a recovery may run next to a note
    /// that is still being produced, and a recovery no longer blocks the user
    /// from starting the meeting they just walked into.
    func recoverOrphanedRecordings() {
        guard case .idle = capture, !isRecovering,
              let (session, meta) = SpoolStore.orphans().first else { return }

        let mic = SpoolStore.readSamples(session.micURL)
        let system = SpoolStore.readSamples(session.systemURL)
        let sampleRate = PCMDownsampler.targetSampleRate
        // Notes typed before the crash live in the spool next to the audio, and
        // they outrank the "too short to matter" rule: a two-second recording
        // with three typed lines is still a note worth keeping.
        let recoveredNotes = SpoolStore.readNotes(session)
        guard max(mic.count, system.count) >= sampleRate || recoveredNotes != nil else {
            SpoolStore.remove(session) // too short to matter
            recoverOrphanedRecordings()
            return
        }

        isRecovering = true
        processingCount += 1
        statusMessage = String(localized: "Stelle unterbrochene Aufnahme wieder her…")
        try? notesFolder.ensureExists()
        let folderURL = notesFolder.folderURL
        let providerID = UserDefaults.standard.string(forKey: "summarizationProvider")
            ?? SummarizationProviderID.anthropicAPI.rawValue
        let event: CalendarMonitor.EventMatch? = meta.eventTitle.map {
            CalendarMonitor.EventMatch(title: $0, eventIdentifier: meta.eventID ?? "")
        }
        Task {
            do {
                let note = try await Self.produceNote(
                    micSamples: mic,
                    systemSamples: system,
                    startedAt: meta.startedAt,
                    providerID: providerID,
                    folderURL: folderURL,
                    event: event,
                    userNotes: recoveredNotes,
                    spool: session
                )
                handle(outcome: note, spool: session, userNotes: recoveredNotes, recovered: true)
            } catch {
                statusMessage = String(localized: "Wiederherstellung fehlgeschlagen — Rohdaten unter spool-failed aufbewahrt.")
                SpoolStore.markFailed(session)
            }
            processingCount -= 1
            isRecovering = false
            recoverOrphanedRecordings()
        }
    }

    /// One recovery at a time — the queue is walked recursively, and without
    /// this a second call would pick the same orphan up again.
    private var isRecovering = false

    /// The menu keeps the full history in `statusMessage`; this is the signal for
    /// the moment the user is somewhere else entirely — the meeting just ended
    /// and the note (or the failure) is ready. Click opens the note.
    private func notifyReady(title: String, body: String, noteURL: URL?) {
        guard UserDefaults.standard.object(forKey: "notifyOnMeetingReady") as? Bool ?? true else { return }
        NotificationCenterService.shared.postMeetingReady(
            id: "meeting-ready-\(UUID().uuidString)",
            title: title,
            body: body,
            noteURL: noteURL
        )
    }

    private struct NoteOutcome: Sendable {
        var url: URL
        var summaryError: String?
        var retry: RetryPayload?
        /// False when the pipeline recognized no speech at all. The raw audio
        /// is then worth keeping (a real meeting that captured nothing is a
        /// capture bug, not an empty room), so callers preserve the spool.
        var producedTranscript: Bool
        /// Set when a track was recorded but carried nothing (`TrackSilence`).
        /// The note is still written — half a meeting beats none — but the gap
        /// must be reported, or it reads as a complete transcript.
        var captureWarning: String?
    }

    /// Re-runs summarization for the last note whose summary failed.
    func retrySummary() {
        // A retry only needs no *other* summarization in flight; a running
        // capture is none of its business.
        guard let payload = summaryRetry, processingCount == 0 else { return }
        processingCount += 1
        statusMessage = String(localized: "Erzeuge Zusammenfassung…")
        let providerID = UserDefaults.standard.string(forKey: "summarizationProvider")
            ?? SummarizationProviderID.anthropicAPI.rawValue

        Task {
            do {
                let summary = try await SummarizationService.summarize(
                    transcript: payload.transcript,
                    context: payload.context,
                    providerID: providerID
                )
                // SQLite is the source of truth — store the summary AND subtitle.
                try await RecordingStore.shared.setSummary(
                    summary.markdown, subtitle: summary.subtitle, for: payload.recordingID
                )
                await UsageRecorder.record(
                    summary.usage, provider: summary.providerID,
                    purpose: .summary, recordingID: payload.recordingID
                )
                // Re-render the file from the stored record, not the stale
                // payload snapshot, so user notes added after the failure and the
                // current title survive.
                if let loaded = try? await RecordingStore.shared.meeting(id: payload.recordingID) {
                    let rec = loaded.recording
                    let note = MarkdownProjector.Note(
                        title: rec.title ?? String(localized: "Meeting"), date: rec.startedAt,
                        calendarEventTitle: rec.calendarEventTitle,
                        attendees: rec.attendees,
                        segments: loaded.segments.map { ($0.speaker, $0.text) },
                        summary: rec.summary, userNotes: rec.userNotes
                    )
                    let url = rec.markdownPath.map { URL(fileURLWithPath: $0) } ?? payload.fileURL
                    try? MarkdownProjector.render(note).write(to: url, atomically: true, encoding: .utf8)
                }
                summaryRetry = nil
                statusMessage = String(localized: "Zusammenfassung ergänzt: \(payload.fileURL.lastPathComponent)")
            } catch {
                statusMessage = String(localized: "Zusammenfassung weiterhin fehlgeschlagen: \(error.localizedDescription)")
            }
            processingCount -= 1
        }
    }

    /// How many distinct voices to expect on the system track.
    ///
    /// Everyone invited, minus the local user. Deliberately conservative: with
    /// fewer than two invitees the number says nothing (a one-to-one and a
    /// no-event call look the same), and above eight an invitation is a
    /// distribution list rather than a description of who talks — in both cases
    /// the diarizer's own estimate is the better answer.
    static func expectedRemoteSpeakers(of event: CalendarMonitor.EventMatch?) -> Int? {
        guard let event else { return nil }
        let owner = SpeakerNameResolver.ownerNameTokens
        let remote = event.attendeeNames.filter { !SpeakerNameResolver.isOwnerName($0, ownerTokens: owner) }
        guard (2...8).contains(remote.count) else { return nil }
        return remote.count
    }

    /// Off-main heavy lifting: pipeline → markdown → store → summary.
    /// Runs the user's meeting-end script (Spec 08 E) with the finished note's
    /// path as its one argument. Best-effort and off the main thread, with a
    /// hard timeout so a hanging script can't wedge the app. No path set ⇒ no-op.
    static func runMeetingHook(noteURL: URL) {
        let path = (UserDefaults.standard.string(forKey: "meetingHookPath") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return }
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = [noteURL.path]
            guard (try? process.run()) != nil else { return }
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
            process.waitUntilExit()
            killer.cancel()
        }
    }

    /// The ASR engine for meeting transcription.
    ///
    /// Default: Parakeet v3 — the most accurate multilingual model here, and shared
    /// with dictation's cache so only one copy of the weights is resident. When the
    /// user opts in via `meetingUseDictationEngine`, meetings follow the dictation
    /// engine picker instead: Parakeet v3 or Whisper. Parakeet **Unified** is
    /// streaming-only (no batch `transcribe(samples:)`), so it can't do per-segment
    /// meeting ASR and falls back to Parakeet v3.
    nonisolated static func meetingTranscriber() async throws -> any TranscriptionEngine {
        guard UserDefaults.standard.bool(forKey: "meetingUseDictationEngine") else {
            return try await ParakeetModelCache.shared.transcriber()
        }
        switch ASREngineID.current {
        case .whisper:
            let whisper = WhisperTranscriber()
            try await whisper.prepare()
            return whisper
        case .parakeetV3, .unifiedEnglish:
            return try await ParakeetModelCache.shared.transcriber()
        }
    }

    private static func produceNote(
        micSamples: [Float],
        systemSamples: [Float],
        startedAt: Date,
        providerID: String,
        folderURL: URL,
        event: CalendarMonitor.EventMatch?,
        userNotes: String? = nil,
        /// Only so the "note written" marker can be dropped into it — see
        /// `SpoolStore.markNoteWritten`. Nothing else here touches the spool.
        spool: SpoolStore.Session? = nil
    ) async throws -> NoteOutcome {
        // Transcribe + diarize (detached — CoreML work must not block main).
        // Parakeet v3 is shared with dictation's cache (no second copy of the
        // weights); Whisper is loaded fresh for the meeting when selected.
        // The invitation is the best prior available for how many voices the far
        // side has: everyone invited except the local user. Nil when there is no
        // event, or when the list is so small that guessing is worse than not.
        let expectedSpeakers = Self.expectedRemoteSpeakers(of: event)
        let segments = try await Task.detached(priority: .userInitiated) {
            let transcriber = try await meetingTranscriber()
            return try await MeetingPipeline.process(
                micSamples: micSamples,
                systemSamples: systemSamples,
                transcriber: transcriber,
                expectedSpeakers: expectedSpeakers
            )
        }.value

        // A track that was recorded but carries no signal at all is a capture
        // fault, and it is invisible downstream: the pipeline happily transcribes
        // whatever *did* arrive and the note reads like a full meeting. Judged on
        // the raw samples, before any of that (`TrackSilence`).
        let micSilent = TrackSilence.isSilent(micSamples)
        let systemSilent = !systemSamples.isEmpty && TrackSilence.isSilent(systemSamples)
        let captureWarning: String?
        switch (micSilent, systemSilent) {
        case (true, true):
            captureWarning = String(localized: "Beide Spuren waren stumm — es wurde nichts aufgezeichnet.")
        case (true, false):
            captureWarning = String(localized: "Mikrofon war stumm — deine eigene Stimme fehlt im Transkript.")
                + " " + String(localized: "Mikrofon-Berechtigung für Notable prüfen.")
        case (false, true):
            captureWarning = String(localized: "System-Audio war stumm — die Gegenseite fehlt im Transkript.")
                + " " + String(localized: "Berechtigung „System-Audio-Aufnahme“ prüfen.")
        case (false, false):
            captureWarning = nil
        }

        // Minted here rather than just before the SQLite write: the naming call
        // below is a provider round-trip whose spend is booked against this
        // meeting, and `llm_usage` carries no foreign key precisely so a row may
        // precede the recording it names.
        let recordingID = UUID().uuidString

        // Attribute remote speakers to real names when the evidence supports it
        // (attendee-anchored, conservative LLM relabel). Best-effort: any failure
        // leaves "Sprecher n" untouched; "Ich" is never relabelled. Only
        // transcript text + attendee names leave the device — same stance as
        // summarization. Default-on, switchable via "speakerNamingEnabled".
        //
        // Not attempted when the mic was stumm: the transcript is then one side
        // of a conversation, and the only name it attests is usually the local
        // user's own — spoken *at* them by the person who is actually talking,
        // which lands that name on the remote speaker. No evidence beats a
        // confident wrong name.
        let named: [MeetingTranscriptSegment]
        if !segments.isEmpty, !micSilent,
           UserDefaults.standard.object(forKey: "speakerNamingEnabled") as? Bool ?? true {
            let mapping = await SpeakerNameResolver.resolve(
                segments: segments,
                attendees: event?.attendeeNames ?? [],
                providerID: providerID,
                recordingID: recordingID
            )
            named = SpeakerNameResolver.applyMapping(segments, mapping: mapping)
        } else {
            named = segments
        }

        let duration = Double(max(micSamples.count, systemSamples.count))
            / Double(PCMDownsampler.targetSampleRate)
        // No calendar event ⇒ the title is a fallback ("Meeting") that the model
        // may replace with a concise generated one.
        let titleIsAuto = (event == nil)
        var finalTitle = event?.title ?? String(localized: "Meeting")

        var note = MarkdownProjector.Note(
            title: finalTitle,
            date: startedAt,
            calendarEventTitle: event?.title,
            attendees: event?.attendeeNames ?? [],
            segments: named.map { ($0.speaker, $0.text) },
            summary: nil,
            userNotes: userNotes
        )

        // New notes land in the Inbox; the user files them into project folders
        // from the note-management window.
        let inboxURL = folderURL.appendingPathComponent(NoteManager.inboxFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)

        // Write the transcript first — a summary failure must not lose it.
        var fileURL = inboxURL.appendingPathComponent(
            MarkdownProjector.uniqueFileName(title: finalTitle, date: startedAt, in: inboxURL)
        )
        try MarkdownProjector.render(note).write(to: fileURL, atomically: true, encoding: .utf8)
        // From here on this session has a note. The SQLite row is still to come,
        // and a crash in between used to leave the spool looking untouched — the
        // next launch then recovered it into a second "(2)" note.
        if let spool { SpoolStore.markNoteWritten(spool, noteURL: fileURL) }

        // Summarize with the chosen provider (no silent fallback) BEFORE the
        // SQLite write, so summary/subtitle/title land in the same record —
        // SQLite is the source of truth and a note re-renders fully from it.
        var subtitle: String?
        var summaryError: String?
        var retry: RetryPayload?
        if named.isEmpty {
            summaryError = "Kein Sprachinhalt erkannt."
        } else {
            let transcriptText = named
                .map { "\($0.speaker ?? "Unbekannt"): \($0.text)" }
                .joined(separator: "\n")
            let context = MeetingContext(title: finalTitle, date: startedAt, durationSeconds: duration, userNotes: userNotes)
            do {
                let summary = try await SummarizationService.summarize(
                    transcript: transcriptText,
                    context: context,
                    providerID: providerID
                )
                note.summary = summary.markdown
                subtitle = summary.subtitle
                // The recordings row lands further down; `llm_usage` carries no
                // foreign key precisely so the spend can be booked right here,
                // where the usage is still in hand.
                await UsageRecorder.record(
                    summary.usage, provider: summary.providerID,
                    purpose: .summary, recordingID: recordingID
                )

                // Auto title: only when there is no calendar event and the model
                // supplied one. Rename the file to match (collision-safe).
                if titleIsAuto,
                   let modelTitle = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !modelTitle.isEmpty {
                    finalTitle = modelTitle
                    note.title = modelTitle
                    let renamed = inboxURL.appendingPathComponent(
                        MarkdownProjector.uniqueFileName(
                            title: modelTitle, date: startedAt, in: inboxURL, excluding: fileURL
                        )
                    )
                    if renamed != fileURL {
                        try? FileManager.default.moveItem(at: fileURL, to: renamed)
                        fileURL = renamed
                    }
                }
                try MarkdownProjector.render(note).write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                summaryError = error.localizedDescription
                retry = RetryPayload(
                    recordingID: recordingID,
                    note: note, fileURL: fileURL, transcript: transcriptText, context: context
                )
            }
        }

        // Persist to SQLite (source of truth) — summary/subtitle/title/folder
        // included, so the whole note re-renders from the database.
        let recording = RecordingStore.Recording(
            id: recordingID,
            kind: .meeting,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            title: finalTitle,
            calendarEventID: event?.eventIdentifier,
            markdownPath: fileURL.path,
            summary: note.summary,
            subtitle: subtitle,
            folder: NoteManager.inboxFolder,
            titleIsAuto: titleIsAuto,
            userNotes: userNotes,
            // Stored, not only written into the front matter: every later
            // re-projection reads it back from here, so a rename no longer
            // drops the `event:` line.
            calendarEventTitle: event?.title,
            attendees: event?.attendeeNames ?? []
        )
        try await RecordingStore.shared.insertMeeting(
            recording,
            segments: named.map {
                RecordingStore.Segment(speaker: $0.speaker, start: $0.start, end: $0.end, text: $0.text)
            }
        )

        return NoteOutcome(
            url: fileURL,
            summaryError: summaryError,
            retry: retry,
            producedTranscript: !named.isEmpty,
            captureWarning: captureWarning
        )
    }
}
