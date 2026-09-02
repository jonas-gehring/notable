import Foundation

/// Abstraction over the ASR model. Parakeet TDT (CoreML/ANE) is the planned
/// default; Whisper variants and Qwen3 ASR slot in behind the same protocol
/// as user-switchable alternatives (Phase 2.3).
protocol TranscriptionEngine: Sendable {
    var displayName: String { get }
    /// `samples` are 16 kHz mono Float32 PCM.
    func transcribe(samples: [Float], sampleRate: Int) async throws -> String
}

/// Placeholder until the CoreML model lands. Lets the full dictation flow
/// (hotkey → record → transcribe → paste) be exercised end-to-end.
struct StubTranscriber: TranscriptionEngine {
    let displayName = "Stub (kein ASR-Modell)"

    func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        let seconds = Double(samples.count) / Double(sampleRate)
        return String(format: "[Notable: %.1f s Audio aufgenommen — ASR-Modell folgt in Phase 2.3]", seconds)
    }
}
