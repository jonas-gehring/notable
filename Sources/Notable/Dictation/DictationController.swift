import AppKit
import Combine
import Foundation
import os

/// Owns the dictation state machine:
/// idle → (hotkey down) recording → (hotkey up) transcribing → pasting → idle.
///
/// Since Spec 29 it decides *when* and hands off *what*: the transcribers live in
/// `DictationEngines`, the microphone in `DictationInput`, failure lines and
/// sounds in `DictationFeedback`, the text stages in `DictationTextStages`, and
/// every decision in the pure, tested `DictationPipeline`.
@MainActor
final class DictationController: ObservableObject {
    private static let log = Logger(subsystem: "de.jonasgehring.notable", category: "dictation")
    typealias ModelState = DictationEngines.ModelState

    /// Surfaced in the menu — a missing permission must be visible, never silent.
    @Published private(set) var setupError: String?
    /// Release→polish duration of the most recent dictation, in milliseconds.
    @Published private(set) var lastLatencyMillis: Int?
    @Published private(set) var lastAudioSeconds: Double?
    /// The most recent dictation — onboarding watches it land.
    @Published private(set) var lastDictationAt: Date?
    /// The text of the most recent pasted dictation — onboarding shows it back.
    @Published private(set) var lastDictationText: String?
    /// The live input level, on its own object: thirty updates a second should
    /// re-render the one view that draws them (Spec 33 §3.5), not every observer.
    let meter = LevelMeter()
    let engines = DictationEngines()
    /// Not private: the menu and the notification action show paste failures here.
    let overlay: DictationOverlayController

    private let appState: AppState
    private let feedback: DictationFeedback
    private let hotkey = HotkeyMonitor()
    private let input = DictationInput()
    /// Pauses playback / mutes output during a dictation; both switches default off.
    private let media = MediaInterrupter()
    private var engineObservation: AnyCancellable?

    /// Recordings shorter than this are treated as accidental taps.
    private let minimumDuration: TimeInterval = 0.3
    /// Upper bound for a single dictation (hands-free lock has no key to release).
    static let maximumRecordingSeconds: TimeInterval = 600
    /// Said after the paste of the recording it belongs to.
    private var pendingNotice: String?
    private var recordingStartedAt = Date.distantPast
    /// The role of the key that started this recording.
    private var startRole: HotkeyRole = .plain
    /// Numbers each recording; the job's key once it is released.
    private var recordingGeneration = 0
    /// True while the microphone is open. Capture and processing are separate
    /// states (Spec 29): `appState.captureState` is derived from this and `jobs`.
    private var isCapturing = false
    /// Released recordings still on their way to the paste, oldest first.
    private var jobs = JobQueue()
    private var jobTasks: [Int: Task<Void, Never>] = [:]
    /// The next job waits for this one before pasting — texts land in spoken order.
    private var lastJobTask: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var ptt = PTTStateMachine()
    private var levelTimer: Timer?
    private var idle = IdleDetector(timeout: 0)

    init(appState: AppState) {
        self.appState = appState
        let overlay = DictationOverlayController()
        self.overlay = overlay
        feedback = DictationFeedback(overlay: overlay)
        feedback.isCapturing = { [weak self] in self?.isCapturing ?? false }
        engines.isBusy = { [weak self] in self?.appState.captureState != .idle }
        engines.onSwap = { [weak self] engine in
            self?.overlay.flashNotice(String(localized: "\(engine.shortLabel) aktiv — volle Qualität."))
        }
        engineObservation = engines.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        overlay.onCancel = { [weak self] in self?.cancelRecording() }
    }

    var modelState: ModelState { engines.modelState }
    var downloadProgress: Double? { engines.downloadProgress }
    var isUsingBootstrap: Bool { engines.isUsingBootstrap }
    func modelState(for engine: ASREngineID) -> ModelState { engines.modelState(for: engine) }
    func retryLoad(_ engine: ASREngineID) { engines.retryLoad(engine) }

    func start() {
        hotkey.onKeyDown = { [weak self] role in
            guard let self else { return }
            let action = self.ptt.keyDown(at: ProcessInfo.processInfo.systemUptime)
            // The role belongs to the press that *starts* a recording (Spec 29):
            // the press that ends a hands-free one must not decide whether its
            // text leaves the device.
            self.startRole = DictationPipeline.startedRole(after: action, pressed: role, current: self.startRole)
            self.perform(action)
        }
        hotkey.onKeyUp = { [weak self] _ in
            guard let self else { return }
            let action = self.ptt.keyUp(at: ProcessInfo.processInfo.systemUptime)
            if self.ptt.isLocked {
                self.overlay.updateLocked(true)
                self.feedback.playCue(.locked)
            }
            self.perform(action)
        }
        hotkey.onEscape = { [weak self] in self?.cancelRecording() }
        hotkey.acceptsEscape = { [weak self] in
            guard let self else { return false }
            return self.isCapturing || !self.jobs.isEmpty
        }
        hotkey.spec = HotkeySpec.current
        hotkey.enhanceSpec = EnhancementSettings.hotkey()
        hotkey.commandSpec = LocalPolish.commandHotkey()
        overlay.prepare()
        LastClipStore.removeStrayStashes()
        DictationTextStages.prewarmLocalModel()

        input.recorder.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.handleRouteChange() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishBeforeSleep() }
        }
        installHotkey()
        engines.load()
    }

    private func installHotkey() {
        setupError = hotkey.start()
            ? nil
            : String(localized: "Hotkey inaktiv: Eingabeüberwachung fehlt (Einstellungen → Berechtigungen).")
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
        hotkey.commandSpec = LocalPolish.commandHotkey()
        installHotkey()
    }

    func engineChanged() {
        discardActiveRecording(reason: String(localized: "ASR-Engine gewechselt — laufendes Diktat verworfen."))
        engines.engineChanged()
    }

    func whisperModelChanged() {
        discardActiveRecording(reason: String(localized: "Whisper-Modell gewechselt — laufendes Diktat verworfen."))
        engines.whisperModelChanged()
    }

    func localPolishModeChanged() {
        DictationTextStages.prewarmLocalModel()
    }

    /// Settings changes that invalidate a running recording. Dropping audio the
    /// user is speaking into is fine — dropping it silently is not.
    private func discardActiveRecording(reason: String) {
        guard isCapturing else { return }
        cancelRecording()
        overlay.flashError(reason)
    }

    // MARK: - Recording

    private func beginRecording() {
        // A running capture is the only thing that blocks a new one; a dictation
        // still being transcribed does not (Spec 29).
        guard !isCapturing else {
            ptt.reset()
            return
        }
        switch input.open() {
        case .opened:
            break
        case .askedForPermission:
            ptt.reset()
            feedback.report(.microphoneRequested)
            return
        case .refused(let failure):
            ptt.reset()
            feedback.report(failure)
            return
        }
        recordingGeneration += 1
        pendingNotice = nil
        media.begin()
        recordingStartedAt = Date()
        isCapturing = true
        publishCaptureState()
        overlay.setEscapeAvailable(hotkey.beginEscInterception())
        overlay.show(.recording)
        feedback.playCue(.start)

        idle = IdleDetector(timeout: DefaultsKey.dictationIdleTimeout.value())
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    /// 30 Hz (Spec 30 §3.4). The idle and maximum rules measure time, not ticks.
    private func tick() {
        guard isCapturing else { return }
        let level = input.recorder.level
        overlay.updateLevel(level)
        meter.level = level
        if ptt.isLocked, idle.observe(level: level, at: ProcessInfo.processInfo.systemUptime) {
            // A forgotten lock stops on its own, a soft speaker does not.
            pendingNotice = String(localized: "Diktat nach \(Int(idle.timeout)) s Stille beendet.")
            finishRecording()
        } else if DictationPipeline.reachedMaximum(
            startedAt: recordingStartedAt, now: Date(), maximum: Self.maximumRecordingSeconds
        ) {
            pendingNotice = String(localized: "Diktat nach \(Int(Self.maximumRecordingSeconds / 60)) Minuten automatisch beendet.")
            finishRecording()
        }
    }

    /// Derives `appState.captureState` and does what "nothing running" implies:
    /// the Esc tap goes, a due model swap happens, a waiting failure is said.
    private func publishCaptureState() {
        appState.captureState = isCapturing ? .recording : (jobs.isEmpty ? .idle : .transcribing)
        guard !isCapturing, jobs.isEmpty else { return }
        hotkey.endEscInterception()
        // Only after `.idle`: the engines refuse to swap while a capture is in flight.
        engines.applyPendingSwap()
        feedback.flushDeferred()
    }

    /// Is this job still wanted? Esc removes it; a cancelled task must not paste.
    private func isLive(_ generation: Int) -> Bool {
        jobs.contains(generation) && !Task.isCancelled
    }

    private func cancelRecording() {
        switch DictationPipeline.escapeTarget(isCapturing: isCapturing, jobs: jobs) {
        case .recording:
            ptt.reset()
            stopLevelTimer()
            _ = input.recorder.stop()
            pendingNotice = nil
            media.end()
        case .job(let generation):
            jobs.finish(generation)
            jobTasks[generation]?.cancel()
            jobTasks[generation] = nil
        case .none:
            return
        }
        isCapturing = false
        // Shrinks instead of fading (Spec 37 §3.2): once the capsule is gone,
        // nothing else distinguishes "discarded" from "pasted".
        overlay.hide(.shrink)
        feedback.playCue(.cancelled)
        publishCaptureState()
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        meter.level = 0
    }

    private func handleRouteChange() {
        switch input.handleRouteChange(isCapturing: isCapturing) {
        case .ignored, .unchanged:
            break
        case .switched(let name):
            // Said at once, beside the waveform: the partial line takes a short
            // remark without hiding the HUD mid-dictation (Spec 29 §3.6).
            let remark = String(localized: "Mikrofon: \(name)")
            overlay.updatePartial(remark)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard let self, self.isCapturing else { return }
                self.overlay.updatePartial("")
            }
        case .lost:
            // Half a dictation beats a lost one: what was captured is transcribed.
            pendingNotice = DictationFailure.deviceLost.message
            finishRecording()
        }
    }

    /// A recording must not run across a sleep; what was said is transcribed.
    private func finishBeforeSleep() {
        guard isCapturing else { return }
        pendingNotice = String(localized: "Diktat vor dem Ruhezustand beendet.")
        finishRecording()
    }

    private func finishRecording() {
        guard isCapturing else { return }
        let releasedAt = ContinuousClock.now
        // Freeze the target now: the overlay is non-activating, so the frontmost
        // app is still the field the user dictated into (Spec 03).
        let targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        stopLevelTimer()
        let samples = input.recorder.stop()
        media.end()
        let sampleRate = input.recorder.targetSampleRate
        ptt.reset()
        isCapturing = false
        let notice = pendingNotice
        pendingNotice = nil
        let duration = Double(samples.count) / Double(sampleRate)

        if case .refuse(let failure) = DictationPipeline.afterStop(
            duration: duration, minimumDuration: minimumDuration,
            peak: TrackSilence.peak(samples), device: input.deviceName
        ) {
            overlay.hide()
            publishCaptureState()
            feedback.report(failure)
            return
        }
        let role = startRole
        startRole = .plain
        startJob(DictationJob(
            generation: recordingGeneration, samples: samples, sampleRate: sampleRate,
            duration: duration, startedAt: recordingStartedAt, releasedAt: releasedAt, targetBundleID: targetBundleID,
            role: role, target: TargetTextAccess.capture(wantsContext: role != .command), notice: notice
        ))
    }

    // MARK: - Jobs

    /// Retries the dictation that failed — from the menu, so the app the text is
    /// meant for is frontmost again.
    func retryLastClip() {
        guard !isCapturing, let clip = LastClipStore.pending() else { return }
        let samples = LastClipStore.samples()
        LastClipStore.clear()
        Task { await AppContainer.shared.dictationHistory.refresh() }
        if let text = clip.text {
            switch DictationTextStages.deliver(text, target: nil) {
            case .pasted: feedback.playCue(.done)
            case .notPasted(let failure): feedback.report(failure)
            }
            return
        }
        guard !samples.isEmpty else { return }
        recordingGeneration += 1
        let sampleRate = input.recorder.targetSampleRate
        startJob(DictationJob(
            generation: recordingGeneration, samples: samples, sampleRate: sampleRate,
            duration: Double(samples.count) / Double(sampleRate), startedAt: clip.recordedAt,
            releasedAt: .now, targetBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            role: .plain, target: nil, notice: nil
        ))
    }

    func discardLastClip() {
        LastClipStore.clear()
        Task { await AppContainer.shared.dictationHistory.refresh() }
    }

    private func startJob(_ job: DictationJob) {
        let generation = job.generation
        jobs.enqueue(generation)
        publishCaptureState()
        // A loading model says so at once; a normal transcription shows its
        // spinner only once it is worth seeing (Spec 30 §3.3).
        overlay.setProvisional(engines.isUsingBootstrap)
        if engines.modelState == .loading && !engines.isUsingBootstrap {
            overlay.show(.loadingModel)
        } else {
            overlay.showAfterDelay(.transcribing)
        }
        engines.loadIfMissing()

        let category: AppCategory = DefaultsKey.appContextFormatting.value()
            ? AppCategory.of(bundleID: job.targetBundleID, overrides: AppCategory.loadOverrides())
            : .unknown
        let sourceApp = DefaultsKey.appStatistics.value() ? job.targetBundleID : nil
        let localMode = LocalPolish.Mode.current()
        let previous = lastJobTask
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
                let transcription = try await engines.transcribe(samples: job.samples, sampleRate: job.sampleRate)
                let outcome = await DictationTextStages.produce(
                    DictationTextStages.Input(
                        transcript: transcription.text, tokens: transcription.tokens,
                        category: category, role: job.role, capture: job.target, localMode: localMode
                    ),
                    isLive: { self.isLive(generation) },
                    show: { state, delayed in
                        guard !self.isCapturing else { return }
                        if delayed { self.overlay.showAfterDelay(state) } else { self.overlay.show(state) }
                    }
                )
                let text: DictationTextStages.Text
                switch outcome {
                case .cancelled:
                    return
                case .failed(let failure):
                    feedback.hideIfIdle()
                    feedback.report(failure)
                    return
                case .produced(let produced):
                    text = produced
                }
                lastLatencyMillis = DictationTextStages.milliseconds(from: job.releasedAt, to: text.polishedAt)

                // Texts land in spoken order: wait for the job before this one.
                await previous?.value
                guard isLive(generation) else { return }
                feedback.hideIfIdle()
                var pasted = false
                switch DictationTextStages.deliver(text.toPaste, target: job.targetBundleID) {
                case .pasted:
                    pasted = true
                    feedback.playCue(.done)
                    lastDictationText = text.toPaste
                    DictationTextStages.watchForCorrections(text.toPaste, capture: job.target)
                    if !isCapturing {
                        if let notice = text.notice {
                            overlay.flashError(notice)
                        } else if let notice = job.notice {
                            overlay.flashNotice(notice)
                        }
                    }
                case .notPasted(let failure):
                    // The words exist but are not in the field: kept with the clip,
                    // so "Wiederholen" pastes them where they belong (Spec 30 §3.7).
                    keptClip = LastClip(
                        recordedAt: job.startedAt, duration: job.duration, failure: failure.title,
                        targetBundleID: job.targetBundleID, text: text.toPaste
                    )
                    feedback.report(failure)
                }
                lastAudioSeconds = job.duration
                lastDictationAt = Date()
                let saved = await DictationTextStages.save(
                    text, job: job, engine: transcription.engine, latencyMs: lastLatencyMillis, sourceApp: sourceApp
                )
                if !saved, !isCapturing {
                    overlay.flashError(String(localized: "Diktat nicht gespeichert — Text ist eingefügt."))
                }
                // The success moment (Spec 37 §3.2) — here, after the paste and
                // after the save, and nowhere earlier: the measured stretch
                // ended at `deliver` above.
                if let moment = DictationTextStages.successMoment(
                    text, job: job, pasted: pasted, saved: saved, isCapturing: isCapturing
                ) {
                    overlay.flashDone(moment)
                }
                await AppContainer.shared.dictationHistory.refresh()
                await AppContainer.shared.usage.refresh()
            } catch {
                guard isLive(generation) else { return }
                Self.log.error("Transkription: \(error.localizedDescription, privacy: .public)")
                feedback.hideIfIdle()
                var failure = DictationFailure.transcriptionFailed
                if let summarization = error as? SummarizationError, case .notConfigured = summarization {
                    failure = .modelMissing
                }
                // The words never existed, so the audio is the dictation.
                keptClip = LastClip(
                    recordedAt: job.startedAt, duration: job.duration, failure: failure.title,
                    targetBundleID: job.targetBundleID, text: nil
                )
                feedback.report(failure)
            }
        }
        jobTasks[generation] = task
        lastJobTask = task
    }
}

/// See `DictationController.meter`.
@MainActor
final class LevelMeter: ObservableObject {
    @Published var level: Float = 0
}
