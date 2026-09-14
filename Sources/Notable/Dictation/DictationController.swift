import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation
import os

/// Owns the dictation state machine:
/// idle → (hotkey down) recording → (hotkey up) transcribing → pasting → idle.
@MainActor
final class DictationController: ObservableObject {
    private static let log = Logger(subsystem: "de.jonasgehring.notable", category: "dictation")

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
    /// The text of the most recent pasted dictation — onboarding shows it back.
    @Published private(set) var lastDictationText: String?
    /// The live input level, on its own object: thirty updates a second should
    /// re-render the one view that draws them (onboarding, Spec 33 §3.5), not
    /// every view that observes this controller.
    let meter = LevelMeter()

    private let appState: AppState
    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    /// Not private: the menu and the notification action need somewhere to show
    /// a paste failure, and the HUD is the one surface that is visible while
    /// another app is frontmost.
    let overlay = DictationOverlayController()
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
    /// Said after the paste of the recording it belongs to: the auto-stop, a
    /// microphone that changed mid-sentence, the sleep that ended it.
    private var pendingNotice: String?

    private var recordingStartedAt = Date.distantPast
    /// Set at key-down when the *second* hotkey started this recording. False
    /// for every normal dictation, which is what keeps the core path offline and
    /// as fast as before.
    private var enhanceRequested = false
    /// Numbers each recording. It is the job's key once the recording is
    /// released: Esc or a cancel removes the job from `jobs`, and the job checks
    /// after every await whether it is still there.
    private var recordingGeneration = 0
    /// True while the microphone is open.
    ///
    /// Capture and processing are separate states since Spec 29 — the split
    /// `MeetingController` got for back-to-back calls. `captureState` used to be
    /// one value, and a dictation still transcribing blocked the next key press
    /// without a sound. `appState.captureState` is now *derived* from these two
    /// (`publishCaptureState`), so the menu, the updater and the detector read
    /// the same combined state as before.
    private var isCapturing = false
    /// Released recordings still on their way to the paste, oldest first.
    private var jobs = JobQueue()
    private var jobTasks: [Int: Task<Void, Never>] = [:]
    /// The most recently started job. The next one waits for it before pasting,
    /// so two texts never land in the reverse of the order they were spoken.
    private var lastJobTask: Task<Void, Never>?
    /// A failure of an older job that arrived while a new recording ran. Said
    /// once nothing is running any more instead of covering the waveform.
    private var deferredFailure: DictationFailure?
    /// Name of the device this recording opened, for "nothing heard on …".
    private var recordingDevice: String?
    private var cachedInputContext: (context: InputDevicePolicy.Context, at: Date)?
    /// `resume` itself reconfigures the engine and posts another change.
    private var ignoreConfigurationChangesUntil = Date.distantPast
    private var sleepObserver: NSObjectProtocol?
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
    /// Hands-free idle-timeout (Spec 08 D), with hysteresis since Spec 29.
    private var idle = IdleDetector(timeout: 0)

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        hotkey.onKeyDown = { [weak self] role in
            guard let self else { return }
            let action = self.ptt.keyDown(at: ProcessInfo.processInfo.systemUptime)
            // The role belongs to the press that *starts* a recording (Spec 29).
            // The press that ends a hands-free one must not change whether its
            // text leaves the device.
            self.enhanceRequested = DictationPipeline.enhanceRequested(
                after: action, pressed: role, current: self.enhanceRequested
            )
            self.perform(action)
        }
        hotkey.onKeyUp = { [weak self] _ in
            guard let self else { return }
            let action = self.ptt.keyUp(at: ProcessInfo.processInfo.systemUptime)
            if self.ptt.isLocked {
                self.overlay.updateLocked(true)
                self.playCue(.locked)
            }
            self.perform(action)
        }
        overlay.prepare()
        // Stashes of dictations that never finished — a crash or a quit mid-job.
        LastClipStore.removeStrayStashes()
        prewarmLocalModel()
        hotkey.onEscape = { [weak self] in self?.cancelRecording() }
        // Esc is live while a recording runs *or* a released one is still on its
        // way to the paste. Only the first half used to count, so Esc during a
        // long enhancement went to the focused app instead (Spec 29).
        hotkey.isRecordingActive = { [weak self] in
            guard let self else { return false }
            return self.isCapturing || !self.jobs.isEmpty
        }
        hotkey.spec = HotkeySpec.current
        hotkey.enhanceSpec = EnhancementSettings.hotkey()
        activeEngine = ASREngineID.current

        // A route change moves the recording to the device the policy picks
        // now, instead of cancelling it (Spec 29).
        recorder.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.handleConfigurationChange() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishBeforeSleep() }
        }

        if hotkey.start() {
            setupError = nil
        } else {
            // Listen-only taps need Input Monitoring; the usual cause of failure.
            setupError = String(localized: "Hotkey inaktiv: Eingabeüberwachung fehlt (Einstellungen → Berechtigungen).")
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
            setupError = String(localized: "Hotkey inaktiv: Eingabeüberwachung fehlt (Einstellungen → Berechtigungen).")
        }
    }

    /// Applies a changed ASR-engine setting: unload nothing eagerly, just
    /// load the newly selected engine and route future recordings to it.
    func engineChanged() {
        discardActiveRecording(reason: String(localized: "ASR-Engine gewechselt — laufendes Diktat verworfen."))
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
                overlay.flashNotice(String(localized: "\(selected.shortLabel) aktiv — volle Qualität."))
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
        guard isCapturing else { return }
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
    ///
    /// Only the *selected* engine can be reloaded — `loadSelectedModel` reads
    /// `ASREngineID.current` — so a retry for any other slot would have cleared
    /// that slot and then loaded nothing, leaving the user with a spinner that
    /// never resolves. It was harmless only because the one caller always passes
    /// the selected engine; saying so out loud is cheaper than relying on it.
    func retryLoad(_ engine: ASREngineID) {
        guard engine == ASREngineID.current else { return }
        // An aborted download leaves a directory that FluidAudio's presence
        // check calls "there", so clearing the task alone would re-read the
        // same broken slot forever. This is the only thing that makes the
        // button mean anything — and it only ever touches a directory the
        // inventory can prove is incomplete.
        ModelInventory.discardIncomplete(for: engine)
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

    private var bootstrapEnabled: Bool { DefaultsKey.bootstrapModel.value() }

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
        discardActiveRecording(reason: String(localized: "Whisper-Modell gewechselt — laufendes Diktat verworfen."))
        whisperTask = nil
        whisperState = .loading
        if ASREngineID.current == .whisper {
            loadModel()
        }
    }

    /// What `InputDevicePolicy` decides from for a dictation: no call rule, and
    /// an idle headset is allowed as the last resort (Spec 23). A handful of
    /// property reads — nothing that shows up against the latency budget.
    private static func inputContext() -> InputDevicePolicy.Context {
        InputDevicePolicy.Context(
            devices: AudioDevices.inputDevices(),
            defaultInputID: AudioDevices.defaultInputID,
            pinnedUID: DefaultsKey.inputDeviceUID.value(),
            lidClosed: AudioDevices.isLidClosed(),
            allowIdleWireless: true
        )
    }

    /// The input context, cached briefly.
    ///
    /// Enumerating devices and reading the lid through IORegistry used to happen
    /// on every key-down. Two seconds is shorter than any realistic gap between
    /// plugging something in and dictating, and a route change drops the cache.
    private func inputContext(fresh: Bool = false) -> InputDevicePolicy.Context {
        if !fresh, let cached = cachedInputContext, Date().timeIntervalSince(cached.at) < 2 {
            return cached.context
        }
        let context = Self.inputContext()
        cachedInputContext = (context, Date())
        return context
    }

    private static func microphonePermission() -> DictationPipeline.MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    private func beginRecording() {
        // A running capture is the only thing that blocks a new one. A dictation
        // still being transcribed does not (Spec 29): its samples are already
        // out of the recorder, and the old `.idle` guard here dropped the second
        // dictation of a quick exchange without a sound.
        guard !isCapturing else {
            ptt.reset()
            return
        }
        let choice = InputDevicePolicy.choose(inputContext())
        switch DictationPipeline.start(
            permission: Self.microphonePermission(),
            secureInput: IsSecureEventInputEnabled(),
            knownSilent: choice.isKnownSilent
        ) {
        case .start:
            break
        case .requestPermission:
            ptt.reset()
            report(.microphoneRequested)
            Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
            return
        case .refuse(let failure):
            ptt.reset()
            report(failure)
            return
        }
        do {
            try recorder.start(device: choice.device?.id)
        } catch {
            ptt.reset()
            Self.log.error("Mikrofon: \(error.localizedDescription, privacy: .public)")
            report(.microphoneUnavailable)
            return
        }
        recordingGeneration += 1
        recordingDevice = choice.device?.name
        pendingNotice = nil
        ignoreConfigurationChangesUntil = .distantPast
        // After `recorder.start()` succeeded: a failed start must not leave the
        // Mac muted with nothing recording.
        media.begin()
        recordingStartedAt = Date()
        isCapturing = true
        publishCaptureState()
        // The overlay's "Esc verwirft" is only true if the tap came up; without
        // Accessibility it does not, and promising a way out that does not exist
        // is worse than not offering one.
        let escAvailable = hotkey.beginEscInterception()
        overlay.setEscapeAvailable(escAvailable)
        overlay.show(.recording)
        playCue(.start)

        idle = IdleDetector(timeout: DefaultsKey.dictationIdleTimeout.value())
        // 30 Hz (Spec 30 §3.4): at 10 Hz the waveform stepped instead of moving.
        // The idle and maximum rules measure time, not ticks, so the rate is free.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isCapturing else { return }
                let level = self.recorder.level
                self.overlay.updateLevel(level)
                self.meter.level = level

                // Hands-free idle-timeout: a forgotten lock stops on its own,
                // a soft speaker does not (hysteresis, `IdleDetector`).
                if self.ptt.isLocked,
                   self.idle.observe(level: level, at: ProcessInfo.processInfo.systemUptime) {
                    self.pendingNotice = String(localized: "Diktat nach \(Int(self.idle.timeout)) s Stille beendet.")
                    self.finishRecording()
                    return
                }
                // Hands-free lock has no key held down to end it: a forgotten
                // session would grow the sample buffer without bound. By wall
                // clock — a stalled main thread must not stretch the cap.
                if DictationPipeline.reachedMaximum(
                    startedAt: self.recordingStartedAt, now: Date(), maximum: Self.maximumRecordingSeconds
                ) {
                    self.pendingNotice = String(localized: "Diktat nach \(Int(Self.maximumRecordingSeconds / 60)) Minuten automatisch beendet.")
                    self.finishRecording()
                    return
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    /// Derives `appState.captureState` from the capture and the job queue, and
    /// does what "nothing running any more" implies.
    ///
    /// Recording wins over processing, as in `MeetingController.state`: a running
    /// capture is what the user needs to see. Once both are over, the Esc tap goes,
    /// a model swap that came due meanwhile happens, and a failure that arrived
    /// during a newer recording is finally said.
    private func publishCaptureState() {
        appState.captureState = isCapturing ? .recording : (jobs.isEmpty ? .idle : .transcribing)
        guard !isCapturing, jobs.isEmpty else { return }
        hotkey.endEscInterception()
        // Only after `.idle`: `updateActiveEngine` refuses to swap while a
        // capture is in flight, and asking earlier merely set `pendingSwap`
        // again with no later path asking.
        applyPendingSwap()
        if let failure = deferredFailure {
            deferredFailure = nil
            show(failure)
        }
    }

    /// Says a failure: a sound always, words unless a recording is running —
    /// then the words wait until nothing is (`publishCaptureState`).
    private func report(_ failure: DictationFailure) {
        playCue(failure.cue)
        Self.log.info("Diktat: \(failure.title, privacy: .public)")
        guard !isCapturing else {
            deferredFailure = failure
            return
        }
        show(failure)
    }

    private func show(_ failure: DictationFailure) {
        if failure.isNotice {
            overlay.flashNotice(failure.title, hint: failure.hint)
        } else {
            overlay.flashError(failure.title, hint: failure.hint)
        }
    }

    /// Is this job still wanted? Esc removes it from the queue, and a cancelled
    /// task must not paste into whatever field is focused by then. Read after
    /// every await of the job.
    private func isLive(_ generation: Int) -> Bool {
        jobs.contains(generation) && !Task.isCancelled
    }

    /// Hides the overlay unless a newer recording is using it.
    private func hideIfIdle() {
        guard !isCapturing else { return }
        overlay.hide()
    }

    private func cancelRecording() {
        switch DictationPipeline.escapeTarget(isCapturing: isCapturing, jobs: jobs) {
        case .recording:
            ptt.reset()
            stopLevelTimer()
            _ = recorder.stop()
            pendingNotice = nil
            // Cancelling counts as ending: the volume comes back either way.
            media.end()
            isCapturing = false
            overlay.hide()
            playCue(.cancelled)
            publishCaptureState()
        case .job(let generation):
            // Esc after the release: the newest job is the one whose text has
            // not appeared yet. During `.enhancing` it is waiting on a CLI
            // round-trip of up to a minute; cancelling the task also terminates
            // that process (`CLIProcessRunner` handles cancellation).
            jobs.finish(generation)
            jobTasks[generation]?.cancel()
            jobTasks[generation] = nil
            overlay.hide()
            playCue(.cancelled)
            publishCaptureState()
        case .none:
            return
        }
    }

    /// Performs a swap that came due while a recording was in flight.
    ///
    /// Called when capture and processing have both ended. `updateActiveEngine`
    /// is idempotent and clears the flag itself; a no-op here is the normal case.
    private func applyPendingSwap() {
        guard pendingSwap else { return }
        updateActiveEngine()
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        meter.level = 0
    }

    /// Plays the sound for a moment of the dictation (Spec 08 C; on by default
    /// since Spec 29).
    private func playCue(_ cue: SoundCue) {
        guard DefaultsKey.dictationSounds.value() else { return }
        NSSound(named: cue.systemSoundName)?.play()
    }

    /// A route change during a recording: device unplugged, AirPods connected.
    ///
    /// It used to cancel the recording and discard the audio. `resume` keeps the
    /// buffer, reinstalls the tap on the device the policy picks *now* and pads
    /// the gap with silence — what meetings have done all along. Only when that
    /// fails does the recording end, and then what was captured is transcribed:
    /// half a dictation beats a lost one.
    private func handleConfigurationChange() {
        cachedInputContext = nil
        guard isCapturing, Date() >= ignoreConfigurationChangesUntil else { return }
        let choice = InputDevicePolicy.choose(inputContext(fresh: true))
        ignoreConfigurationChangesUntil = Date().addingTimeInterval(1.5)
        do {
            try recorder.resume(device: choice.device?.id)
            if let name = choice.device?.name, name != recordingDevice {
                recordingDevice = name
                pendingNotice = String(localized: "Mikrofon gewechselt: „\(name)“.")
            }
        } catch {
            Self.log.error("Gerätewechsel: \(error.localizedDescription, privacy: .public)")
            pendingNotice = DictationFailure.deviceLost.message
            finishRecording()
        }
    }

    /// A recording must not run across a sleep: the audio engine may come back
    /// without a route change, and a hands-free lock would collect nothing but a
    /// hole. What was said before the lid closed is transcribed.
    private func finishBeforeSleep() {
        guard isCapturing else { return }
        pendingNotice = String(localized: "Diktat vor dem Ruhezustand beendet.")
        finishRecording()
    }

    private func finishRecording() {
        guard isCapturing else { return }
        let releasedAt = ContinuousClock.now
        // Freeze the target app now: the overlay is non-activating, so the
        // frontmost app is still the field the user dictated into (Spec 03).
        let targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        stopLevelTimer()
        let samples = recorder.stop()
        // Restored as soon as the microphone is closed — not after the paste.
        // Transcription takes long enough that waiting would feel like a bug.
        media.end()
        let sampleRate = recorder.targetSampleRate
        ptt.reset()
        isCapturing = false
        let generation = recordingGeneration
        let notice = pendingNotice
        pendingNotice = nil
        let duration = Double(samples.count) / Double(sampleRate)

        if case .refuse(let failure) = DictationPipeline.afterStop(
            duration: duration,
            minimumDuration: minimumDuration,
            peak: TrackSilence.peak(samples),
            device: recordingDevice
        ) {
            overlay.hide()
            publishCaptureState()
            report(failure)
            return
        }

        // Consumed once per recording: the release must not be able to enhance a
        // dictation that a later key-down never asked for.
        let wantsEnhancement = enhanceRequested
        enhanceRequested = false
        startJob(Job(
            generation: generation,
            samples: samples,
            sampleRate: sampleRate,
            duration: duration,
            startedAt: recordingStartedAt,
            releasedAt: releasedAt,
            targetBundleID: targetBundleID,
            wantsEnhancement: wantsEnhancement,
            notice: notice
        ))
    }

    /// A released recording on its way to the paste. A value, so a retried clip
    /// (Spec 30 §3.7) runs through exactly the same path as a fresh one.
    private struct Job: Sendable {
        let generation: Int
        let samples: [Float]
        let sampleRate: Int
        let duration: TimeInterval
        let startedAt: Date
        let releasedAt: ContinuousClock.Instant
        let targetBundleID: String?
        let wantsEnhancement: Bool
        let notice: String?
    }

    /// Retries the dictation whose transcription failed — from the menu, so the
    /// app the text is meant for is the frontmost one again.
    func retryLastClip() {
        guard !isCapturing, let clip = LastClipStore.pending() else { return }
        let samples = LastClipStore.samples()
        LastClipStore.clear()
        Task { await AppContainer.shared.dictationHistory.refresh() }
        if let text = clip.text {
            do {
                try Paster.insert(text)
                playCue(.done)
            } catch {
                report(.pasteBlocked)
            }
            return
        }
        guard !samples.isEmpty else { return }
        recordingGeneration += 1
        let sampleRate = recorder.targetSampleRate
        startJob(Job(
            generation: recordingGeneration,
            samples: samples,
            sampleRate: sampleRate,
            duration: Double(samples.count) / Double(sampleRate),
            startedAt: clip.recordedAt,
            releasedAt: .now,
            targetBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            wantsEnhancement: false,
            notice: nil
        ))
    }

    func discardLastClip() {
        LastClipStore.clear()
        Task { await AppContainer.shared.dictationHistory.refresh() }
    }

    /// The setting changed: warm the model now rather than on the first dictation.
    func localPolishModeChanged() {
        prewarmLocalModel()
    }

    private func prewarmLocalModel() {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), LocalPolish.Mode.current() != .off else { return }
        Task { await LocalPolisher.shared.prewarm() }
        #endif
    }

    /// The on-device stage, when this system has it (Spec 32). Nil means the
    /// stage does not exist here — not that it failed.
    private func runLocalPolish(_ text: String, category: AppCategory) async -> LocalPolishResult? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return nil }
        if !isCapturing { overlay.showAfterDelay(.formatting) }
        return await LocalPolisher.shared.polish(text, category: category)
        #else
        return nil
        #endif
    }

    private func startJob(_ job: Job) {
        let generation = job.generation
        jobs.enqueue(generation)
        publishCaptureState()
        // The model may still be downloading on first launch — say so instead
        // of promising a transcription that is minutes away. With a stand-in
        // ready there is nothing to wait for, so it marks the result as
        // provisional instead. A normal transcription shows its spinner only
        // once it has taken long enough to be worth seeing (Spec 30 §3.3).
        overlay.setProvisional(isUsingBootstrap)
        if modelState == .loading && !isUsingBootstrap {
            overlay.show(.loadingModel)
        } else {
            overlay.showAfterDelay(.transcribing)
        }

        let selectedTaskMissing: Bool
        switch ASREngineID.current {
        case .parakeetV3: selectedTaskMissing = engineTask == nil
        case .unifiedEnglish: selectedTaskMissing = streamTask == nil
        case .whisper: selectedTaskMissing = whisperTask == nil
        }
        if selectedTaskMissing {
            loadModel() // earlier download failed — retry now
        }

        let appContextEnabled = DefaultsKey.appContextFormatting.value()
        // Separate switch from the formatting one: a user may well want per-app
        // polishing without a per-app tally of where he dictates.
        let appStatisticsEnabled = DefaultsKey.appStatistics.value()
        let overrides = AppCategory.loadOverrides()
        let localMode = LocalPolish.Mode.current()
        let previous = lastJobTask
        // The safety copy is written next to the transcription, off the main
        // actor; it only has to exist by the time a failure wants to keep it.
        let stash = Task.detached(priority: .utility) {
            try? LastClipStore.stash(job.samples, generation: generation)
        }

        let task = Task {
            var keptClip: LastClip?
            defer {
                jobs.finish(generation)
                jobTasks[generation] = nil
                publishCaptureState()
                let kept = keptClip
                Task.detached(priority: .utility) {
                    await stash.value
                    if let kept {
                        try? LastClipStore.keep(kept, generation: generation)
                        await AppContainer.shared.dictationHistory.refresh()
                    } else {
                        LastClipStore.discard(generation: generation)
                    }
                }
            }

            do {
                let transcription = try await rawTranscript(samples: job.samples, sampleRate: job.sampleRate)
                let category: AppCategory = appContextEnabled
                    ? AppCategory.of(bundleID: job.targetBundleID, overrides: overrides)
                    : .unknown
                // Off the main actor: `polish` is pure, and it sits in the gap
                // between the key release and the paste. Pauses are read off the
                // raw transcript, whose sentences the tokens spell (Spec 31 §3.5).
                let options = PolishProfile.options(for: category)
                let polished = await Task.detached(priority: .userInitiated) {
                    var withPauses = options
                    withPauses.sentencePauses = transcription.tokens.flatMap {
                        SpeechPauses.sentenceBoundaryPauses(tokens: $0, text: transcription.text)
                    }
                    return TextPolisher.polish(transcription.text, options: withPauses)
                }.value
                guard isLive(generation) else { return }
                if let failure = DictationPipeline.afterTranscript(polished) {
                    hideIfIdle()
                    report(failure)
                    return
                }
                let trimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)

                // Stopped **here**, before any model stage: this is how long
                // transcription took. The on-device stage books its own time
                // (`polish_ms`), the CLI enhancement none.
                let elapsed = job.releasedAt.duration(to: .now)
                lastLatencyMillis = Int(Double(elapsed.components.seconds) * 1000
                    + Double(elapsed.components.attoseconds) / 1e15)

                var toPaste = trimmed
                var rawText: String?
                var polisher = "rules"
                var polishMs: Int?
                var stageNotice: String?

                // On the device, nothing leaves it (Spec 32).
                if LocalPolish.shouldRun(mode: localMode, category: category, text: trimmed),
                   let result = await runLocalPolish(trimmed, category: category) {
                    guard isLive(generation) else { return }
                    polishMs = result.milliseconds
                    if result.didPolish {
                        rawText = trimmed
                        toPaste = result.text
                        polisher = "local"
                    }
                    stageNotice = result.failure
                }

                // The only place dictation text may leave the device, and it
                // happens solely because *this* recording was started with the
                // enhancement hotkey.
                if job.wantsEnhancement, EnhancementSettings.isEnabled {
                    if !isCapturing { overlay.show(.enhancing) }
                    let result = await DictationEnhancer.forDictation().enhance(
                        toPaste,
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
                        rawText = rawText ?? trimmed
                        toPaste = result.text
                        polisher = "cli"
                    }
                    stageNotice = result.failure ?? stageNotice
                }

                // Texts land in the order they were spoken: wait for the job
                // before this one to paste, fail or be cancelled.
                await previous?.value
                guard isLive(generation) else { return }
                hideIfIdle()

                // The target was frozen at the release. If another app is in
                // front now, ⌘V would land there.
                let front = NSWorkspace.shared.frontmostApplication
                switch DictationPipeline.paste(
                    target: job.targetBundleID,
                    frontmost: front?.bundleIdentifier,
                    frontmostName: front?.localizedName,
                    secureInput: IsSecureEventInputEnabled()
                ) {
                case .clipboard(let failure):
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(toPaste, forType: .string)
                    report(failure)
                case .paste:
                    do {
                        try Paster.insert(toPaste)
                        playCue(.done)
                        lastDictationText = toPaste
                        if !isCapturing {
                            if let stageNotice {
                                overlay.flashError(stageNotice)
                            } else if let notice = job.notice {
                                // A notice, not an error: the dictation ended
                                // exactly as configured.
                                overlay.flashNotice(notice)
                            }
                        }
                    } catch {
                        // Without Accessibility the synthesized ⌘V goes nowhere;
                        // `Paster` left the text on the pasteboard.
                        report(.pasteBlocked)
                    }
                }
                lastAudioSeconds = job.duration
                lastDictationAt = Date()
                do {
                    try await RecordingStore.shared.saveDictation(
                        text: toPaste,
                        startedAt: job.startedAt,
                        duration: job.duration,
                        engine: transcription.engine,
                        latencyMs: lastLatencyMillis,
                        // Stays in SQLite and never goes into a prompt.
                        sourceApp: appStatisticsEnabled ? job.targetBundleID : nil,
                        // "Enhanced" counts text that left the device — the CLI
                        // stage only, never the local one.
                        enhanced: polisher == "cli",
                        // Set whenever a model changed the text.
                        rawText: rawText,
                        polisher: polisher,
                        polishMs: polishMs
                    )
                } catch {
                    // The text is pasted either way — but history and statistics
                    // would silently be missing this dictation.
                    Self.log.error("Diktat nicht gespeichert: \(error.localizedDescription, privacy: .public)")
                    if !isCapturing {
                        overlay.flashError(String(localized: "Diktat nicht gespeichert — Text ist eingefügt."))
                    }
                }
                // Keep the native menu's "letztes/letzte Diktate" and the
                // statistics line current — a `.menu` MenuBarExtra cannot refresh
                // itself on open.
                await AppContainer.shared.dictationHistory.refresh()
                await AppContainer.shared.usage.refresh()
            } catch {
                guard isLive(generation) else { return }
                Self.log.error("Transkription: \(error.localizedDescription, privacy: .public)")
                hideIfIdle()
                var failure = DictationFailure.transcriptionFailed
                if let summarization = error as? SummarizationError, case .notConfigured = summarization {
                    failure = .modelMissing
                }
                // The words never existed, so the audio is the dictation: kept,
                // and offered for a retry from the menu (Spec 30 §3.7).
                keptClip = LastClip(
                    recordedAt: job.startedAt,
                    duration: job.duration,
                    failure: failure.title,
                    targetBundleID: job.targetBundleID,
                    text: nil
                )
                report(failure)
            }
        }
        jobTasks[generation] = task
        lastJobTask = task
    }

    /// Whole-clip transcription of the finished recording — one pass, no
    /// incremental session or streaming state — robust over clever.
    ///
    /// Returns the statistics name of the engine that actually produced the
    /// text, not the one that is selected. On a cold cache those differ, and
    /// booking a stand-in run under the chosen engine put Tiny's latency into
    /// v3's p50/p95 and its word count into v3's share of the engine card.
    /// Token timings come back only from Parakeet v3 (Spec 31 §3.5).
    private func rawTranscript(
        samples: [Float],
        sampleRate: Int
    ) async throws -> (text: String, engine: String, tokens: [TimedToken]?) {
        // The stand-in, while it is the one carrying dictation. Its own slot, so
        // it can never be confused with a user-chosen Whisper of another size.
        if isUsingBootstrap, let bootstrapTask {
            let text = try await bootstrapTask.value.transcribe(samples: samples, sampleRate: sampleRate)
            return (text, BootstrapPolicy.bootstrapStatisticsName, nil)
        }
        let name = activeEngine.statisticsName
        switch activeEngine {
        case .whisper:
            guard let whisperTask else {
                throw SummarizationError.notConfigured(String(localized: "Kein ASR-Modell verfügbar."))
            }
            return (try await whisperTask.value.transcribe(samples: samples, sampleRate: sampleRate), name, nil)
        case .unifiedEnglish:
            guard let streamTask else {
                throw SummarizationError.notConfigured(String(localized: "Kein ASR-Modell verfügbar."))
            }
            let engine = try await streamTask.value
            try await engine.beginUtterance()
            try await engine.feed(samples)
            return (try await engine.finish(), name, nil)
        case .parakeetV3:
            guard let engineTask else {
                throw SummarizationError.notConfigured(String(localized: "Kein ASR-Modell verfügbar."))
            }
            let result = try await engineTask.value.transcribeDetailed(samples: samples, sampleRate: sampleRate)
            return (result.text, name, result.tokens)
        }
    }
}

/// See `DictationController.meter`.
@MainActor
final class LevelMeter: ObservableObject {
    @Published var level: Float = 0
}
