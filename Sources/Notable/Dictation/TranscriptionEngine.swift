import Foundation

/// Abstraction over the ASR model. Parakeet TDT (CoreML/ANE) is the planned
/// default; Whisper variants and Qwen3 ASR slot in behind the same protocol
/// as user-switchable alternatives (Phase 2.3).
protocol TranscriptionEngine: Sendable {
    var displayName: String { get }
    /// `samples` are 16 kHz mono Float32 PCM.
    func transcribe(samples: [Float], sampleRate: Int) async throws -> String
    /// The text and, where the engine reports them, token timings (Spec 31 §3.5).
    /// A requirement rather than only an extension method, so a call through
    /// `any TranscriptionEngine` still reaches an engine's own implementation.
    func transcribeDetailed(samples: [Float], sampleRate: Int) async throws -> TranscriptionResult
}

/// What a transcription produced. `tokens` is nil for every engine that does
/// not report timings — the paragraph rule then counts sentences, as before.
struct TranscriptionResult: Sendable, Equatable {
    var text: String
    var tokens: [TimedToken]?
}

extension TranscriptionEngine {
    func transcribeDetailed(samples: [Float], sampleRate: Int) async throws -> TranscriptionResult {
        TranscriptionResult(text: try await transcribe(samples: samples, sampleRate: sampleRate), tokens: nil)
    }
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
