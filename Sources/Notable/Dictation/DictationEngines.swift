import Foundation

/// The transcribers behind dictation: which one is loaded, which one transcribes,
/// and the stand-in that carries a cold first launch (Spec 10).
///
/// Taken out of `DictationController` in Spec 29 §9 — roughly a third of that
/// file, and none of it about recording or pasting. The controller still
/// forwards the four published values the views read.
@MainActor
final class DictationEngines: ObservableObject {
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

    @Published private(set) var modelState: ModelState = .loading
    /// Download progress of the selected model, 0…1, or nil when nothing is
    /// downloading. **Separate from `modelState` on purpose**: folding it in as
    /// `.loading(Double?)` would break every existing `== .ready` comparison.
    @Published private(set) var downloadProgress: Double?
    /// What is actually transcribing. Equal to `ASREngineID.current` except while
    /// a stand-in carries dictation during a cold first download.
    @Published private(set) var activeEngine: ASREngineID = ASREngineID.current
    /// True while the stand-in produces the text — the UI has to say so, because
    /// Tiny is markedly weaker than v3.
    @Published private(set) var isUsingBootstrap = false

    /// Is a dictation in flight? A swap waits until the answer is no.
    var isBusy: () -> Bool = { false }
    /// A completed swap from the stand-in to the chosen model, to be announced once.
    var onSwap: (ASREngineID) -> Void = { _ in }

    private var engineTask: Task<ParakeetTranscriber, Error>?
    private var streamTask: Task<EnglishStreamingTranscriber, Error>?
    private var whisperTask: Task<WhisperTranscriber, Error>?
    private var v3State: ModelState = .loading
    private var streamState: ModelState = .loading
    private var whisperState: ModelState = .loading
    /// The stand-in slot (Whisper Tiny), separate from `whisperTask`.
    private var bootstrapTask: Task<WhisperTranscriber, Error>?
    private var bootstrapState: ModelState = .loading
    /// Set when the selected model became ready mid-dictation. The swap then
    /// happens after the paste, never between the audio and its text.
    private var pendingSwap = false

    func load() {
        loadSelectedModel()
        startBootstrapIfNeeded()
    }

    /// An earlier load failed and left no task: retry now, before transcribing.
    func loadIfMissing() {
        let missing = switch ASREngineID.current {
        case .parakeetV3: engineTask == nil
        case .unifiedEnglish: streamTask == nil
        case .whisper: whisperTask == nil
        }
        if missing { load() }
    }

    func engineChanged() {
        // A swap that was waiting for the *old* selection is meaningless now.
        pendingSwap = false
        load()
    }

    /// Drops the loaded Whisper so the next load picks up the new size.
    func whisperModelChanged() {
        whisperTask = nil
        whisperState = .loading
        if ASREngineID.current == .whisper { load() }
    }

    /// Performs a swap that came due while a dictation was in flight. Idempotent;
    /// a no-op is the normal case.
    func applyPendingSwap() {
        guard pendingSwap else { return }
        updateActiveEngine()
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

    /// Retries a failed load without waiting for the next dictation. Only the
    /// *selected* engine can be reloaded — `loadSelectedModel` reads
    /// `ASREngineID.current`, so any other slot would clear and load nothing.
    func retryLoad(_ engine: ASREngineID) {
        guard engine == ASREngineID.current else { return }
        // An aborted download leaves a directory FluidAudio calls "there";
        // clearing the task alone would re-read the same broken slot forever.
        ModelInventory.discardIncomplete(for: engine)
        switch engine {
        case .parakeetV3: engineTask = nil
        case .unifiedEnglish: streamTask = nil
        case .whisper: whisperTask = nil
        }
        loadSelectedModel()
    }

    /// Is the chosen model already on disk? Only answered properly for Parakeet
    /// v3 (FluidAudio's own file check); the other two report "present", which
    /// switches the stand-in off for them — a fresh install always starts on v3.
    static func modelIsPresent(for engine: ASREngineID) -> Bool {
        switch engine {
        case .parakeetV3: ParakeetTranscriber.modelsArePresent
        case .unifiedEnglish, .whisper: true
        }
    }

    /// Whole-clip transcription — one pass, robust over clever.
    ///
    /// Returns the statistics name of the engine that actually produced the text:
    /// on a cold cache that is the stand-in, and booking it under the chosen
    /// engine put Tiny's latency into v3's p50/p95. Token timings come back only
    /// from Parakeet v3 (Spec 31 §3.5).
    func transcribe(samples: [Float], sampleRate: Int) async throws -> (text: String, engine: String, tokens: [TimedToken]?) {
        if isUsingBootstrap, let bootstrapTask {
            let text = try await bootstrapTask.value.transcribe(samples: samples, sampleRate: sampleRate)
            return (text, BootstrapPolicy.bootstrapStatisticsName, nil)
        }
        let name = activeEngine.statisticsName
        let missing = SummarizationError.notConfigured(String(localized: "Kein ASR-Modell verfügbar."))
        switch activeEngine {
        case .whisper:
            guard let whisperTask else { throw missing }
            return (try await whisperTask.value.transcribe(samples: samples, sampleRate: sampleRate), name, nil)
        case .unifiedEnglish:
            guard let streamTask else { throw missing }
            let engine = try await streamTask.value
            try await engine.beginUtterance()
            try await engine.feed(samples)
            return (try await engine.finish(), name, nil)
        case .parakeetV3:
            guard let engineTask else { throw missing }
            let result = try await engineTask.value.transcribeDetailed(samples: samples, sampleRate: sampleRate)
            return (result.text, name, result.tokens)
        }
    }

    // MARK: - Loading

    /// Decides which engine transcribes, and announces a completed swap once.
    private func updateActiveEngine() {
        let selected = ASREngineID.current
        let decision = BootstrapPolicy.engine(
            selectedReady: modelState(for: selected) == .ready,
            bootstrapReady: bootstrapState == .ready && bootstrapTask != nil
        )
        switch decision {
        case .selected:
            if isUsingBootstrap {
                // Never mid-dictation: the transcriber the audio was recorded
                // for has to finish the job first.
                guard BootstrapPolicy.swap(isRecording: isBusy()) == .now else {
                    pendingSwap = true
                    return
                }
                onSwap(selected)
            }
            activeEngine = selected
            isUsingBootstrap = false
            pendingSwap = false
            // The stand-in's weights go — the resident baseline must not grow
            // by a second model.
            bootstrapTask = nil
            bootstrapState = .loading
        case .bootstrap:
            activeEngine = BootstrapPolicy.bootstrapEngine
            isUsingBootstrap = true
        case .wait:
            activeEngine = selected
            isUsingBootstrap = false
        }
    }

    private func publishModelState() {
        modelState = modelState(for: ASREngineID.current)
        if modelState == .ready { downloadProgress = nil }
        updateActiveEngine()
    }

    /// Loads Whisper Tiny alongside the chosen model when that one is missing, so
    /// a cold first launch dictates in about a minute instead of after a download.
    private func startBootstrapIfNeeded() {
        guard bootstrapTask == nil else { return }
        guard BootstrapPolicy.needsBootstrap(
            selected: ASREngineID.current,
            selectedModelPresent: Self.modelIsPresent(for: ASREngineID.current),
            selectedWhisperSize: WhisperModelSize.current,
            enabled: DefaultsKey.bootstrapModel.value()
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
                // A failing stand-in must never become an extra failure mode.
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
                    Task { @MainActor in AppContainer.shared.dictation.engines.reportDownloadProgress(fraction) }
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
                    engineTask = nil
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
                    whisperTask = nil
                }
                publishModelState()
            }
        }
        publishModelState()
    }
}
