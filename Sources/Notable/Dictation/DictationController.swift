import AppKit
import Foundation

/// Owns the dictation state machine:
/// idle → (hotkey down) recording → (hotkey up) transcribing → pasting → idle.
@MainActor
final class DictationController: ObservableObject {
    enum ModelState: Equatable {
        case loading
        case ready
        case failed(String)

        var label: String {
            let key: String.LocalizationValue = switch self {
            case .loading: "ASR-Modell wird geladen…"
            case .ready: "ASR-Modell bereit"
            case .failed(let message): "ASR-Modell fehlgeschlagen: \(message)"
            }
            return String(localized: key)
        }
    }

    /// Surfaced in the menu — a missing permission must be visible, never silent.
    @Published private(set) var setupError: String?
    @Published private(set) var modelState: ModelState = .loading
    /// Download progress of the selected model, 0…1, or nil when nothing is
    /// downloading. **Separate from `modelState` on purpose**: folding it in as
    /// `.loading(Double?)` would break every existing `== .ready` comparison, and
    /// those comparisons are correct as they are.
    @Published private(set) var downloadProgress: Double?
    /// What is actually transcribing. Equal to `ASREngineID.current` except while
    /// a stand-in carries dictation during a cold first download.
    @Published private(set) var activeEngine: ASREngineID = ASREngineID.current
    /// True while the stand-in is the one producing text — the UI has to say so,
    /// because Tiny is markedly weaker than v3 and its output would otherwise
    /// read as Notable's normal quality.
    @Published private(set) var isUsingBootstrap = false
    /// Release→paste duration of the most recent dictation, in milliseconds.
    @Published private(set) var lastLatencyMillis: Int?
    @Published private(set) var lastAudioSeconds: Double?
    /// Timestamp of the most recent successful dictation — the onboarding flow
    /// watches this to confirm the user's first dictation landed.
    @Published private(set) var lastDictationAt: Date?

    private let appState: AppState
    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let overlay = DictationOverlayController()
    /// Pauses playback / mutes output for the duration of a dictation. Both
    /// switches default to off — this reaches outside Notable.
    private let media = MediaInterrupter()

    /// Resolves once the Parakeet v3 models are downloaded and loaded.
    private var engineTask: Task<ParakeetTranscriber, Error>?
    /// Resolves once the Parakeet Unified (English streaming) models are loaded.
    private var streamTask: Task<EnglishStreamingTranscriber, Error>?
    /// Resolves once the Whisper (WhisperKit) model is downloaded and loaded.
    private var whisperTask: Task<WhisperTranscriber, Error>?

    /// Recordings shorter than this are treated as accidental taps.
    private let minimumDuration: TimeInterval = 0.3
    /// Upper bound for a single dictation (hands-free lock has no key to release).
    static let maximumRecordingSeconds: TimeInterval = 600
    private static let maximumRecordingTicks = Int(maximumRecordingSeconds * 10) // 0.1 s ticks
    /// Set when the 10-minute cap ended the recording; shown after the paste.
    private var autoStopNotice: String?

    private var recordingStartedAt = Date.distantPast
    /// Set at key-down when the *second* hotkey started this recording. False
    /// for every normal dictation, which is what keeps the core path offline and
    /// as fast as before.
    private var enhanceRequested = false
    /// Bumped on every begin/finish/cancel — async work from an older
    /// recording checks it after each await and bails instead of
    /// contaminating the current one.
    private var recordingGeneration = 0
    /// Per-engine load state; `modelState` mirrors the selected engine.
    private var v3State: ModelState = .loading
    private var streamState: ModelState = .loading
    private var whisperState: ModelState = .loading
    /// The stand-in slot (Whisper Tiny), separate from `whisperTask` — that one
    /// holds whatever size the user chose.
    private var bootstrapTask: Task<WhisperTranscriber, Error>?
    private var bootstrapState: ModelState = .loading
    /// Set when the selected model became ready mid-recording. The swap then
    /// happens after the paste, never between the audio and the text it belongs
    /// to.
    private var pendingSwap = false
    private var ptt = PTTStateMachine()
    private var levelTimer: Timer?
    private var timerTicks = 0
    /// Consecutive silent 0.1 s ticks, for the hands-free idle-timeout (Spec 08 D).
    private var silentTicks = 0
    /// Seconds of silence that auto-end a hands-free lock (0 = off), read at start.
    private var idleTimeoutSeconds = 0.0

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        hotkey.onKeyDown = { [weak self] role in
            guard let self else { return }
            // Decided at the *start* of the recording and remembered, so the
            // release does not have to look the setting up again.
            self.enhanceRequested = role == .enhanced
            self.perform(self.ptt.keyDown(at: ProcessInfo.processInfo.systemUptime))
        }
        hotkey.onKeyUp = { [weak self] _ in
            guard let self else { return }
            let action = self.ptt.keyUp(at: ProcessInfo.processInfo.systemUptime)
            if self.ptt.isLocked {
                self.overlay.updateLocked(true)
            }
            self.perform(action)
        }
        hotkey.onEscape = { [weak self] in self?.cancelRecording() }
        hotkey.isRecordingActive = { [weak self] in
            self?.appState.captureState == .recording
        }
        hotkey.spec = HotkeySpec.current
        hotkey.enhanceSpec = EnhancementSettings.hotkey()
        activeEngine = ASREngineID.current

        recorder.onConfigurationChange = { [weak self] in
            Task { @MainActor in
                guard let self, self.appState.captureState == .recording else { return }
                self.cancelRecording()
                self.overlay.flashError(String(localized: "Audiogerät hat gewechselt — Aufnahme abgebrochen."))
            }
        }

        if hotkey.start() {
            setupError = nil
        } else {
            // Listen-only taps need Input Monitoring; the usual cause of failure.
            setupError = "Hotkey inaktiv: Eingabeüberwachung fehlt (Einstellungen → Berechtigungen)."
        }

        loadModel()
    }

    private func perform(_ action: PTTStateMachine.Action) {
        switch action {
        case .start: beginRecording()
        case .finish: finishRecording()
        case .none: break
        }
    }

    /// Applies a changed hotkey setting immediately.
    func hotkeyChanged() {
        // A running recording would never see its keyUp on the new key.
        discardActiveRecording(reason: String(localized: "Hotkey geändert — laufendes Diktat verworfen."))
        hotkey.stop()
        hotkey.spec = HotkeySpec.current
        hotkey.enhanceSpec = EnhancementSettings.hotkey()
        if hotkey.start() {
            setupError = nil
        } else {
            setupError = "Hotkey inaktiv: Eingabeüberwachung fehlt (Einstellungen → Berechtigungen)."
        }
    }

    /// Applies a changed ASR-engine setting: unload nothing eagerly, just
    /// load the newly selected engine and route future recordings to it.
    func engineChanged() {
        discardActiveRecording(reason: "ASR-Engine gewechselt — laufendes Diktat verworfen.")
        // A swap that was waiting for the *old* selection is meaningless now.
        pendingSwap = false
        loadModel()
    }

    /// Decides which engine transcribes, and announces a completed swap once.
    ///
    /// Called after every load state change and after every paste — the two
    /// moments where the answer can change.
    private func updateActiveEngine() {
        let selected = ASREngineID.current
        let decision = BootstrapPolicy.engine(
            selectedReady: modelState(for: selected) == .ready,
            bootstrapReady: bootstrapState == .ready && bootstrapTask != nil
        )

        switch decision {
        case .selected:
            if isUsingBootstrap {
                // Never mid-recording: the transcriber the audio was recorded
                // for has to finish the job first.
                guard BootstrapPolicy.swap(isRecording: appState.captureState != .idle) == .now else {
                    pendingSwap = true
                    return
                }
                overlay.flashNotice("\(selected.shortLabel) aktiv — volle Qualität.")
            }
            activeEngine = selected
            isUsingBootstrap = false
            pendingSwap = false
            releaseBootstrap()
        case .bootstrap:
            activeEngine = BootstrapPolicy.bootstrapEngine
            isUsingBootstrap = true
        case .wait:
            activeEngine = selected
            isUsingBootstrap = false
        }
    }

    /// Frees the stand-in's weights after the swap — the ~120 MB resident
    /// baseline must not permanently grow by a second model.
    private func releaseBootstrap() {
        bootstrapTask = nil
        bootstrapState = .loading
    }

    /// Settings changes that invalidate a running recording. Dropping audio
    /// the user is speaking into is fine — dropping it silently is not.
    private func discardActiveRecording(reason: String) {
        guard appState.captureState == .recording else { return }
        cancelRecording()
        overlay.flashError(reason)
    }

    /// Called from FluidAudio's download callback. Nil once the model is ready —
    /// a bar stuck at 100 % is worse than no bar.
    func reportDownloadProgress(_ fraction: Double) {
        downloadProgress = fraction >= 1 ? nil : fraction
    }

    func modelState(for engine: ASREngineID) -> ModelState {
        switch engine {
        case .parakeetV3: v3State
        case .unifiedEnglish: streamState
        case .whisper: whisperState
        }
    }

    /// Retries a failed load without waiting for the next dictation.
    func retryLoad(_ engine: ASREngineID) {
        switch engine {
        case .parakeetV3: engineTask = nil
        case .unifiedEnglish: streamTask = nil
        case .whisper: whisperTask = nil
        }
        loadSelectedModel()
    }

    private func publishModelState() {
        modelState = modelState(for: ASREngineID.current)
        if modelState == .ready { downloadProgress = nil }
        updateActiveEngine()
    }

    private func loadModel() {
        loadSelectedModel()
        startBootstrapIfNeeded()
    }

    /// Is the chosen model already on disk?
    ///
    /// Only answered properly for Parakeet v3 — FluidAudio's own file check. The
    /// other two report "present", which switches the stand-in off for them, and
    /// that is the right conservative direction: a fresh install always starts on
    /// v3, so it is the only engine a cold cache can strand. Someone who picks
    /// Unified or Whisper does it from a working app and can watch the download
    /// on the picker (Spec 11).
    static func modelIsPresent(for engine: ASREngineID) -> Bool {
        switch engine {
        case .parakeetV3: ParakeetTranscriber.modelsArePresent
        case .unifiedEnglish, .whisper: true
        }
    }

    private var bootstrapEnabled: Bool {
        UserDefaults.standard.object(forKey: "bootstrapModel") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "bootstrapModel")
    }

    /// Loads Whisper Tiny alongside the chosen model when that one is missing, so
    /// a cold first launch is dictatable in about a minute instead of after a
    /// multi-hundred-megabyte download.
    private func startBootstrapIfNeeded() {
        guard bootstrapTask == nil else { return }
        guard BootstrapPolicy.needsBootstrap(
            selected: ASREngineID.current,
            selectedModelPresent: Self.modelIsPresent(for: ASREngineID.current),
            selectedWhisperSize: WhisperModelSize.current,
            enabled: bootstrapEnabled
        ) else { return }

        bootstrapState = .loading
        let task = Task<WhisperTranscriber, Error> {
            let transcriber = WhisperTranscriber(modelName: BootstrapPolicy.bootstrapSize.modelName)
            try await transcriber.prepare()
            return transcriber
        }
        bootstrapTask = task
        Task {
            do {
                _ = try await task.value
                bootstrapState = .ready
            } catch {
                // A failing stand-in must never become an extra failure mode:
                // it just goes away and the app waits for the real model, which
                // is exactly today's behaviour.
                bootstrapState = .failed(error.localizedDescription)
                bootstrapTask = nil
            }
            publishModelState()
        }
    }

    private func loadSelectedModel() {
        switch ASREngineID.current {
        case .parakeetV3:
            guard engineTask == nil else { publishModelState(); return }
            v3State = .loading
            // Shared with meeting processing — one copy of the weights, and one
            // progress observer, so a download is never reported twice.
            let task = Task<ParakeetTranscriber, Error> {
                await ParakeetModelCache.shared.setProgressObserver { fraction in
                    Task { @MainActor in AppContainer.shared.dictation.reportDownloadProgress(fraction) }
                }
                return try await ParakeetModelCache.shared.transcriber()
            }
            engineTask = task
            Task {
                do {
                    _ = try await task.value
                    v3State = .ready
                } catch {
                    v3State = .failed(error.localizedDescription)
                    engineTask = nil // allow retry on next attempt
                }
                publishModelState()
            }
        case .unifiedEnglish:
            guard streamTask == nil else { publishModelState(); return }
            streamState = .loading
            let task = Task<EnglishStreamingTranscriber, Error> {
                let transcriber = EnglishStreamingTranscriber()
                try await transcriber.prepare()
                return transcriber
            }
            streamTask = task
            Task {
                do {
                    _ = try await task.value
                    streamState = .ready
                } catch {
                    streamState = .failed(error.localizedDescription)
                    streamTask = nil
                }
                publishModelState()
            }
        case .whisper:
            guard whisperTask == nil else { publishModelState(); return }
            whisperState = .loading
            let task = Task<WhisperTranscriber, Error> {
                let transcriber = WhisperTranscriber()
                try await transcriber.prepare()
                return transcriber
            }
            whisperTask = task
            Task {
                do {
                    _ = try await task.value
                    whisperState = .ready
                } catch {
                    whisperState = .failed(error.localizedDescription)
                    whisperTask = nil // allow retry on next attempt
                }
                publishModelState()
            }
        }
        publishModelState()
    }

    /// Applies a changed Whisper model-size setting: drop the loaded model so
    /// the next load picks up the new size, and reload eagerly if Whisper is
    /// the active engine.
    func whisperModelChanged() {
        discardActiveRecording(reason: "Whisper-Modell gewechselt — laufendes Diktat verworfen.")
        whisperTask = nil
        whisperState = .loading
        if ASREngineID.current == .whisper {
            loadModel()
        }
    }

    private func beginRecording() {
        guard appState.captureState == .idle else {
            // The PTT machine already advanced on keyDown — resync it, or a
            // quick tap during processing would fake-lock with no recording.
            ptt.reset()
            return
        }
        do {
            try recorder.start()
        } catch {
            ptt.reset()
            overlay.flashError("Mikrofon nicht verfügbar: \(error.localizedDescription)")
            return
        }
        recordingGeneration += 1
        autoStopNotice = nil
        // After `recorder.start()` succeeded: a failed start must not leave the
        // Mac muted with nothing recording.
        media.begin()
        recordingStartedAt = Date()
        appState.captureState = .recording
        hotkey.beginEscInterception()
        overlay.show(.recording)
        playCue("Tink")

        timerTicks = 0
        silentTicks = 0
        idleTimeoutSeconds = UserDefaults.standard.double(forKey: "dictationIdleTimeout")
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.appState.captureState == .recording else { return }
                self.overlay.updateLevel(self.recorder.level)
                self.timerTicks += 1

                // Hands-free idle-timeout: end a locked session after a run of
                // silence, so a forgotten lock stops on its own (Spec 08 D).
                if self.ptt.isLocked, self.idleTimeoutSeconds > 0 {
                    if self.recorder.level < 0.04 { self.silentTicks += 1 } else { self.silentTicks = 0 }
                    if self.silentTicks >= Int(self.idleTimeoutSeconds * 10) {
                        self.autoStopNotice = "Diktat nach \(Int(self.idleTimeoutSeconds)) s Stille beendet."
                        self.finishRecording()
                        return
                    }
                }
                // Hands-free lock has no key held down to end it: a forgotten
                // session would grow the sample buffer without bound (~64 KB/s,
                // plus an O(n) copy per snapshot). Dictation is not meeting
                // capture — cut it off and transcribe what there is.
                if self.timerTicks >= Self.maximumRecordingTicks {
                    // Shown once the transcript is in — the transcribing
                    // overlay would otherwise swallow the notice immediately.
                    self.autoStopNotice = "Diktat nach \(Int(Self.maximumRecordingSeconds / 60)) Minuten automatisch beendet."
                    self.finishRecording()
                    return
                }
                // Whole-clip dictation: no incremental/streaming
                // pre-decoding during recording — just the level meter. The
                // clip is transcribed once, on release, which is fast for
                // normal-length dictations and far more robust.
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func cancelRecording() {
        guard appState.captureState == .recording else { return }
        recordingGeneration += 1
        ptt.reset()
        hotkey.endEscInterception()
        stopLevelTimer()
        _ = recorder.stop()
        autoStopNotice = nil
        // Cancelling counts as ending: the volume comes back either way.
        media.end()
        appState.captureState = .idle
        overlay.hide()
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    /// Plays a short system sound cue if enabled (Spec 08 C). Off by default.
    private func playCue(_ name: String) {
        guard UserDefaults.standard.bool(forKey: "dictationSounds") else { return }
        NSSound(named: name)?.play()
    }

    private func finishRecording() {
        guard appState.captureState == .recording else { return }
        let releasedAt = ContinuousClock.now
        // Freeze the target app now: the overlay is non-activating, so the
        // frontmost app is still the field the user dictated into (Spec 03).
        let targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let appContextEnabled = UserDefaults.standard.object(forKey: "appContextFormatting") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "appContextFormatting")
        // Separate switch from the formatting one: a user may well want per-app
        // polishing without a per-app tally of where he dictates.
        let appStatisticsEnabled = UserDefaults.standard.object(forKey: "appStatistics") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "appStatistics")
        hotkey.endEscInterception()
        stopLevelTimer()
        let samples = recorder.stop()
        // Restored as soon as the microphone is closed — not after the paste.
        // Transcription takes long enough that waiting would feel like a bug.
        media.end()
        let sampleRate = recorder.targetSampleRate

        ptt.reset()
        recordingGeneration += 1
        let duration = Double(samples.count) / Double(sampleRate)
        guard duration >= minimumDuration else {
            appState.captureState = .idle
            overlay.hide()
            return
        }

        appState.captureState = .transcribing
        // The model may still be downloading on first launch — say so instead
        // of promising a transcription that is minutes away. With a stand-in
        // ready there is nothing to wait for, so it says "transcribing" and
        // marks the result as provisional instead.
        overlay.setProvisional(isUsingBootstrap)
        overlay.show(modelState == .loading && !isUsingBootstrap ? .loadingModel : .transcribing)

        let selectedTaskMissing: Bool
        switch ASREngineID.current {
        case .parakeetV3: selectedTaskMissing = engineTask == nil
        case .unifiedEnglish: selectedTaskMissing = streamTask == nil
        case .whisper: selectedTaskMissing = whisperTask == nil
        }
        if selectedTaskMissing {
            loadModel() // earlier download failed — retry now
        }

        // Consumed once per recording: the release must not be able to enhance a
        // dictation that a later key-down never asked for.
        let wantsEnhancement = enhanceRequested
        enhanceRequested = false

        Task {
            defer {
                appState.captureState = .idle
            }
            do {
                let text = try await rawTranscript(samples: samples, sampleRate: sampleRate)
                let category: AppCategory = appContextEnabled
                    ? AppCategory.of(bundleID: targetBundleID)
                    : .unknown
                let polished = TextPolisher.polish(text, options: PolishProfile.options(for: category))
                let trimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    overlay.hide()
                    return
                }

                // The only place dictation text may leave the device, and it
                // happens solely because *this* recording was started with the
                // enhancement hotkey. A normal dictation does not evaluate a
                // single line of this: no await, no availability check, no
                // network — it falls straight through to the paste below.
                var toPaste = trimmed
                var rawText: String?
                var enhancementNotice: String?
                if wantsEnhancement, EnhancementSettings.isEnabled {
                    overlay.show(.enhancing)
                    let result = await DictationEnhancer.forDictation().enhance(
                        trimmed,
                        profile: EnhancementSettings.profile(for: category)
                    )
                    // Booked even when the guardrails rejected the answer: the
                    // point of this row is counting how often dictation text
                    // left the device, not what it cost.
                    await UsageRecorder.record(
                        result.usage,
                        provider: DictationEnhancer.dictationProvider.id,
                        purpose: .dictationEnhance,
                        recordingID: nil,
                        countEvenWhenUnknown: true
                    )
                    if result.didEnhance {
                        rawText = trimmed
                        toPaste = result.text
                    }
                    enhancementNotice = result.failure
                }

                overlay.hide()
                do {
                    try Paster.insert(toPaste)
                    playCue("Pop")
                    if let enhancementNotice {
                        overlay.flashError(enhancementNotice)
                    } else if let autoStopNotice {
                        overlay.flashError(autoStopNotice)
                        self.autoStopNotice = nil
                    }
                } catch {
                    // Without Accessibility the synthesized ⌘V goes nowhere and
                    // the transcript would vanish without a trace. It is on the
                    // pasteboard now — say so, loudly.
                    overlay.flashError(error.localizedDescription)
                }
                let elapsed = releasedAt.duration(to: .now)
                lastLatencyMillis = Int(Double(elapsed.components.seconds) * 1000
                    + Double(elapsed.components.attoseconds) / 1e15)
                lastAudioSeconds = duration
                lastDictationAt = Date()
                try? await RecordingStore.shared.saveDictation(
                    text: toPaste,
                    startedAt: self.recordingStartedAt,
                    duration: duration,
                    engine: ASREngineID.current.statisticsName,
                    latencyMs: lastLatencyMillis,
                    // Stays in SQLite. It is already part of this path (that is
                    // how `AppCategory` picks a profile); issue #5 only persists
                    // it, and it never goes into a prompt or off the machine.
                    sourceApp: appStatisticsEnabled ? targetBundleID : nil,
                    enhanced: rawText != nil,
                    // Only set when the model actually changed something —
                    // otherwise there is nothing to compare against.
                    rawText: rawText
                )
                // Keep the native menu's "letztes/letzte Diktate" and the
                // statistics line current — a `.menu` MenuBarExtra is built from
                // NSMenuItems and cannot refresh itself on open (no onAppear).
                await AppContainer.shared.dictationHistory.refresh()
                await AppContainer.shared.usage.refresh()
                // A swap that came due mid-recording happens here — after the
                // text has landed, never between the audio and its transcript.
                if pendingSwap { updateActiveEngine() }
            } catch {
                // flashError hides itself after 3 s — no defer-hide racing it.
                overlay.flashError("Transkription fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    /// Whole-clip transcription of the finished recording — one pass, no
    /// incremental session or streaming state — robust over clever.
    private func rawTranscript(samples: [Float], sampleRate: Int) async throws -> String {
        // The stand-in, while it is the one carrying dictation. Its own slot, so
        // it can never be confused with a user-chosen Whisper of another size.
        if isUsingBootstrap, let bootstrapTask {
            return try await bootstrapTask.value.transcribe(samples: samples, sampleRate: sampleRate)
        }
        switch activeEngine {
        case .whisper:
            guard let whisperTask else {
                throw SummarizationError.notConfigured("Kein ASR-Modell verfügbar.")
            }
            return try await whisperTask.value.transcribe(samples: samples, sampleRate: sampleRate)
        case .unifiedEnglish:
            guard let streamTask else {
                throw SummarizationError.notConfigured("Kein ASR-Modell verfügbar.")
            }
            let engine = try await streamTask.value
            try await engine.beginUtterance()
            try await engine.feed(samples)
            return try await engine.finish()
        case .parakeetV3:
            guard let engineTask else {
                throw SummarizationError.notConfigured("Kein ASR-Modell verfügbar.")
            }
            return try await engineTask.value.transcribe(samples: samples, sampleRate: sampleRate)
        }
    }
}
