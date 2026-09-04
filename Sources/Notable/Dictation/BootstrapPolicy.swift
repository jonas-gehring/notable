import Foundation

/// Whether a small stand-in model carries dictation while the chosen one is
/// still downloading, and when the two may be swapped.
///
/// Pure, like `PTTStateMachine`: no models, no disk, no clock. The rules are
/// short but each one exists because getting it wrong costs a dictation — a swap
/// in the middle of a recording, or a bootstrap that quietly stays active after
/// the real model arrived.
///
/// Only relevant with a **cold** model cache. With a warm cache this never
/// fires; it matters for the first launch after a DMG install, which is
/// currently dead for minutes.
enum BootstrapPolicy {
    /// The stand-in. Whisper Tiny is already a full engine here (~75 MB,
    /// multilingual), so this adds no new model format and no new download path.
    static let bootstrapEngine = ASREngineID.whisper
    static let bootstrapSize = WhisperModelSize.tiny

    /// What a dictation carried by the stand-in is booked as.
    ///
    /// Not `bootstrapEngine.statisticsName`: that one reads the *chosen* Whisper
    /// size out of the defaults, so a stand-in run would be filed under whatever
    /// size the user picked and Tiny's latency would land in that model's p95.
    /// The stand-in always runs Tiny, so the name says Tiny.
    static let bootstrapStatisticsName = "\(bootstrapEngine.rawValue)-\(bootstrapSize.rawValue)"

    /// Load a stand-in at all?
    ///
    /// Only when the chosen model is genuinely missing. A present model means
    /// today's behaviour exactly — no second model, no extra memory.
    static func needsBootstrap(
        selected: ASREngineID,
        selectedModelPresent: Bool,
        selectedWhisperSize: WhisperModelSize,
        enabled: Bool
    ) -> Bool {
        guard enabled, !selectedModelPresent else { return false }
        // Bootstrapping Tiny with Tiny would be a loop with extra steps.
        if selected == bootstrapEngine, selectedWhisperSize == bootstrapSize { return false }
        return true
    }

    /// Which engine transcribes *right now*.
    enum Engine: Equatable {
        /// The chosen model is ready — the normal case.
        case selected
        /// The chosen model is not ready but the stand-in is.
        case bootstrap
        /// Neither is ready: today's behaviour, the overlay says "loading".
        case wait
    }

    static func engine(selectedReady: Bool, bootstrapReady: Bool) -> Engine {
        if selectedReady { return .selected }
        return bootstrapReady ? .bootstrap : .wait
    }

    /// What to do the moment the chosen model reports ready.
    enum Swap: Equatable {
        case now
        /// Never mid-recording, and never between the recording and the paste —
        /// the transcriber the audio was recorded for has to finish the job.
        case deferred
    }

    static func swap(isRecording: Bool) -> Swap {
        isRecording ? .deferred : .now
    }
}
