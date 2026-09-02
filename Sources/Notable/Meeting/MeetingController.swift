import Foundation

/// Manual meeting recording (Phase 4 first stage; auto-detection follows).
/// Records mic + system audio, then runs the on-device pipeline and writes
/// the Markdown note; summarization uses the provider chosen in Settings.
@MainActor
final class MeetingController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(since: Date)
        case processing

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .idle
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
                    self.statusMessage = "Audiogerät gewechselt — Aufnahme fortgesetzt."
                } catch {
                    self.statusMessage = "Audiogerät gewechselt — Mikrofonspur ab hier unvollständig."
                }
            }
        }
        // A tap that cannot be rebuilt after an output-device switch means the
        // remote side is no longer being recorded — a silent half-meeting looks
        // exactly like a successful one, so say it out loud.
        systemTap.onRebuildFailure = { [weak self] error in
            Task { @MainActor in
                guard let self, self.state.isRecording else { return }
                // systemTapActive stays true on purpose: stop() must still
                // drain the spool, or the audio captured before the switch
                // would be thrown away too.
                self.statusMessage = "System-Audio nach Gerätewechsel verloren — ab hier nur Mikrofon: \(error.localizedDescription)"
            }
        }
    }

    func toggle() {
        switch state {
        case .idle: start(auto: false)
        case .recording: stop()
        case .processing: break
        }
    }

    /// Auto-detection entry points (MeetingDetector).
    func startAutomatically(source: String) {
        guard state == .idle else { return }
        start(auto: true)
        // A warning from start() (no system audio, mic failure) outranks the
        // "recording" confirmation — never overwrite it.
        if state.isRecording, statusMessage == nil {
            statusMessage = "Meeting erkannt (\(source)) — Aufnahme läuft."
        }
    }

    /// Called when the detector says the call is over. Stops both auto-started
    /// recordings and manual ones that were started during the call — clicking
    /// "Später" and then recording from the menu used to leave a recording that
    /// never ended.
    func stopAutomatically() {
        guard state.isRecording, startedAutomatically || startedDuringCall else { return }
        stop()
    }

    private func start(auto: Bool) {
        guard state == .idle else { return }
        statusMessage = nil
        startedAutomatically = auto
        startedDuringCall = auto || isCallActive()
        // One start instant for the spool meta, the recording state and the
        // live-notes clock — three separate `Date()` calls used to drift apart.
        let startedAt = Date()

        // Calendar attribution: ask once, then match the running event.
        Task {
            let granted = await calendar.requestAccessIfNeeded()
            guard state.isRecording else { return } // stop() already consumed the event
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
                warnings.append("ohne Echo-Unterdrückung (\(reason)) — bei Lautsprecher-Ton kann die Gegenseite doppelt im Transkript landen")
            }
        } catch {
            statusMessage = "Meeting-Start fehlgeschlagen: \(error.localizedDescription)"
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
            warnings.append("ohne System-Audio, nur Mikrofon (\(error.localizedDescription))")
        }

        if !warnings.isEmpty {
            statusMessage = "Aufnahme läuft eingeschränkt: " + warnings.joined(separator: "; ") + "."
        }
        state = .recording(since: startedAt)
        startMicWatchdog()

        // Live notes open for business: the buffer is bound to this recording's
        // spool from here until stop() consumes it.
        liveNotes.begin(startedAt: startedAt, title: currentEvent?.title ?? "Meeting", spool: currentSpool)
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
        micWatchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.isRecording else {
                    self?.stopMicWatchdog()
                    return
                }
                if self.micRecorder.level > TrackSilence.peakThreshold {
                    self.stopMicWatchdog()
                    return
                }
                guard Date() >= deadline else { return }
                self.stopMicWatchdog()
                self.statusMessage = "Mikrofon liefert nur Stille — deine eigene Stimme wird nicht aufgezeichnet. "
                    + "Mikrofon-Berechtigung für Notable prüfen (Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon)."
            }
        }
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

    private func stop() {
        guard case .recording(let startedAt) = state else { return }

        stopMicWatchdog()
        let micSamples = micRecorder.stop()
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
        state = .processing
        statusMessage = "Verarbeite Aufnahme…"

        let providerID = UserDefaults.standard.string(forKey: "summarizationProvider")
            ?? SummarizationProviderID.anthropicAPI.rawValue
        try? notesFolder.ensureExists()
        let folderURL = notesFolder.folderURL

        Task {
            do {
                let note = try await Self.produceNote(
                    micSamples: micSamples,
                    systemSamples: systemSamples,
                    startedAt: startedAt,
                    providerID: providerID,
                    folderURL: folderURL,
                    event: event,
                    userNotes: userNotes
                )
                lastNoteURL = note.url
                if note.retry != nil || summaryRetry?.fileURL == note.url {
                    summaryRetry = note.retry
                }
                AppContainer.shared.usage.refreshSoon()
                if note.producedTranscript {
                    if let spool { SpoolStore.archive(spool) }
                    // The capture warning leads: a transcript missing one side
                    // still looks finished, and only this line says otherwise.
                    statusMessage = (note.captureWarning.map { $0 + " " } ?? "")
                        + (note.summaryError.map { "Notiz gespeichert, aber ohne Zusammenfassung: \($0)" }
                            ?? "Notiz gespeichert: \(note.url.lastPathComponent)")
                    if let captureWarning = note.captureWarning {
                        notifyReady(title: "Aufnahme unvollständig",
                                    body: captureWarning, noteURL: note.url)
                    } else if let summaryError = note.summaryError {
                        notifyReady(title: "Notiz gespeichert — ohne Zusammenfassung",
                                    body: "\(summaryError) — im Menü erneut versuchen.",
                                    noteURL: note.url)
                    } else {
                        notifyReady(title: "Zusammenfassung fertig",
                                    body: note.url.deletingPathExtension().lastPathComponent,
                                    noteURL: note.url)
                    }
                    Self.runMeetingHook(noteURL: note.url)
                } else {
                    // No speech recognized despite a recording — almost always a
                    // capture failure (denied system-audio TCC, or VPIO gating the
                    // mic during a call). Keep the raw tracks instead of deleting
                    // them, so the failure is diagnosable rather than a silent
                    // empty note.
                    if let spool { SpoolStore.markFailed(spool) }
                    // The note file was still written, so notes typed during the
                    // call are in the Inbox even when the audio yielded nothing.
                    statusMessage = (userNotes == nil ? "" : "Notizen gespeichert: \(note.url.lastPathComponent). ")
                        + "Kein Sprachinhalt erkannt — Rohaufnahme unter spool-failed gesichert. "
                        + "Systemaudio-Berechtigung und Mikrofon (Echo-Unterdrückung) prüfen."
                    notifyReady(title: "Kein Sprachinhalt erkannt",
                                body: "Rohaufnahme gesichert. Systemaudio-Berechtigung und Mikrofon prüfen.",
                                noteURL: nil)
                }
            } catch {
                // Spool stays on disk — the next launch retries via recovery.
                statusMessage = "Meeting-Verarbeitung fehlgeschlagen: \(error.localizedDescription)"
                notifyReady(title: "Meeting-Verarbeitung fehlgeschlagen",
                            body: error.localizedDescription, noteURL: nil)
            }
            state = .idle
        }
    }

    /// Recovers spooled recordings a crash left behind, one at a time.
    func recoverOrphanedRecordings() {
        guard state == .idle, let (session, meta) = SpoolStore.orphans().first else { return }

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

        state = .processing
        statusMessage = "Stelle unterbrochene Aufnahme wieder her…"
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
                    userNotes: recoveredNotes
                )
                lastNoteURL = note.url
                // Never clobber a pending retry from another note — only this
                // note's own outcome may replace it.
                if note.retry != nil || summaryRetry?.fileURL == note.url {
                    summaryRetry = note.retry
                }
                AppContainer.shared.usage.refreshSoon()
                if note.producedTranscript {
                    statusMessage = "Unterbrochene Aufnahme wiederhergestellt: \(note.url.lastPathComponent)"
                    SpoolStore.archive(session)
                    notifyReady(title: "Unterbrochene Aufnahme wiederhergestellt",
                                body: note.url.deletingPathExtension().lastPathComponent,
                                noteURL: note.url)
                    Self.runMeetingHook(noteURL: note.url)
                } else {
                    // Same reasoning as stop(): recovered audio with no recognized
                    // speech is preserved for inspection, not discarded.
                    statusMessage = "Wiederhergestellte Aufnahme ohne erkannten Sprachinhalt — Rohdaten unter spool-failed aufbewahrt."
                    SpoolStore.markFailed(session)
                }
            } catch {
                statusMessage = "Wiederherstellung fehlgeschlagen — Rohdaten unter spool-failed aufbewahrt."
                SpoolStore.markFailed(session)
            }
            state = .idle
            recoverOrphanedRecordings()
        }
    }

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
        guard let payload = summaryRetry, state == .idle else { return }
        state = .processing
        statusMessage = "Erzeuge Zusammenfassung…"
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
                        title: rec.title ?? "Meeting", date: rec.startedAt,
                        calendarEventTitle: nil,
                        segments: loaded.segments.map { ($0.speaker, $0.text) },
                        summary: rec.summary, userNotes: rec.userNotes
                    )
                    let url = rec.markdownPath.map { URL(fileURLWithPath: $0) } ?? payload.fileURL
                    try? MarkdownProjector.render(note).write(to: url, atomically: true, encoding: .utf8)
                }
                summaryRetry = nil
                statusMessage = "Zusammenfassung ergänzt: \(payload.fileURL.lastPathComponent)"
            } catch {
                statusMessage = "Zusammenfassung weiterhin fehlgeschlagen: \(error.localizedDescription)"
            }
            state = .idle
        }
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
        userNotes: String? = nil
    ) async throws -> NoteOutcome {
        // Transcribe + diarize (detached — CoreML work must not block main).
        // Parakeet v3 is shared with dictation's cache (no second copy of the
        // weights); Whisper is loaded fresh for the meeting when selected.
        let segments = try await Task.detached(priority: .userInitiated) {
            let transcriber = try await meetingTranscriber()
            return try await MeetingPipeline.process(
                micSamples: micSamples,
                systemSamples: systemSamples,
                transcriber: transcriber
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
            captureWarning = "Beide Spuren waren stumm — es wurde nichts aufgezeichnet."
        case (true, false):
            captureWarning = "Mikrofon war stumm — deine eigene Stimme fehlt im Transkript. "
                + "Mikrofon-Berechtigung für Notable prüfen."
        case (false, true):
            captureWarning = "System-Audio war stumm — die Gegenseite fehlt im Transkript. "
                + "Berechtigung \"System-Audio-Aufnahme\" prüfen."
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
        var finalTitle = event?.title ?? "Meeting"

        var note = MarkdownProjector.Note(
            title: finalTitle,
            date: startedAt,
            calendarEventTitle: event?.title,
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
            userNotes: userNotes
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
