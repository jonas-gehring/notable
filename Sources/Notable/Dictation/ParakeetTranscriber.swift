import FluidAudio
import Foundation

/// Parakeet TDT v3 (multilingual, 25 European languages) via FluidAudio —
/// CoreML on the Neural Engine. Models are downloaded from HuggingFace on
/// first use and cached locally.
final class ParakeetTranscriber: TranscriptionEngine, @unchecked Sendable {
    let displayName = "Parakeet TDT v3 (lokal, CoreML/ANE)"

    private let manager = AsrManager()
    /// Set once in `prepare()`, read-only afterwards.
    private var decoderLayers = 2

    /// Downloads (first run) and loads the CoreML models. Call once before
    /// the first `transcribe`; safe to call from a background task at launch.
    /// `progress` is FluidAudio's own download reporting, forwarded verbatim —
    /// Notable never downloads anything itself, it only listens.
    func prepare(progress: ProgressHandler? = nil) async throws {
        let models = try await AsrModels.downloadAndLoad(progressHandler: progress)
        try await manager.loadModels(models)
        decoderLayers = await manager.decoderLayerCount
    }

    /// Are the v3 weights already on disk? Authoritative — it is FluidAudio's own
    /// check against the files it needs, not a guess at a directory name.
    static var modelsArePresent: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    /// Incremental session for long dictations (carried decoder state).
    func makeSession() -> DictationSession {
        DictationSession(manager: manager, decoderLayers: decoderLayers)
    }

    func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        precondition(sampleRate == 16_000, "Parakeet erwartet 16 kHz mono")
        // Decoder state is per-utterance; push-to-talk clips are independent.
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return result.text
    }
}
