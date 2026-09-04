import Foundation
import WhisperKit

/// Selectable size for the on-device Whisper model. All multilingual — Notable
/// dictates in German and English, so the `.en`-only variants are out.
enum WhisperModelSize: String, CaseIterable, Identifiable {
    case tiny
    case base
    case small
    case largeV3 = "large-v3"

    static let storageKey = "whisperModelSize"

    static var current: WhisperModelSize {
        UserDefaults.standard.string(forKey: storageKey).flatMap(WhisperModelSize.init(rawValue:)) ?? .base
    }

    var id: String { rawValue }

    /// WhisperKit model identifier, resolved against the HuggingFace repo
    /// `argmaxinc/whisperkit-coreml`. The bare names are the multilingual
    /// CoreML bundles (`tiny`/`base`/`small`/`large-v3`).
    var modelName: String { rawValue }

    /// Download size alone, for the engine picker's status line.
    var sizeLabel: String {
        switch self {
        case .tiny: "~75 MB"
        case .base: "~145 MB"
        case .small: "~465 MB"
        case .largeV3: "~1,5 GB"
        }
    }

    var label: String {
        switch self {
        case .tiny: String(localized: "Tiny (schnell, ~75 MB)")
        case .base: String(localized: "Base (Standard, ~145 MB)")
        case .small: String(localized: "Small (genauer, ~465 MB)")
        case .largeV3: String(localized: "Large v3 (am genauesten, ~1,5 GB)")
        }
    }
}

/// OpenAI Whisper via WhisperKit — CoreML on the Neural Engine (Apple Silicon).
/// The model is downloaded from HuggingFace (`argmaxinc/whisperkit-coreml`) on
/// first use and cached locally, mirroring the Parakeet path. A whole-clip
/// engine: unlike the streaming/incremental engines it decodes the finished
/// recording in one pass, so it is a dictation-only alternative and does not
/// touch the meeting pipeline (which stays on Parakeet).
final class WhisperTranscriber: TranscriptionEngine, @unchecked Sendable {
    let displayName = "Whisper (OpenAI, lokal, CoreML/ANE)"

    private let modelName: String
    /// Set once in `prepare()`, read-only afterwards.
    private var pipe: WhisperKit?

    init(modelName: String = WhisperModelSize.current.modelName) {
        self.modelName = modelName
    }

    /// Downloads (first run) and loads the CoreML model. Call once before the
    /// first `transcribe`; safe to call from a background task at launch.
    func prepare() async throws {
        // The convenience init downloads (download: true) and loads the model.
        pipe = try await WhisperKit(model: modelName)
    }

    func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        precondition(sampleRate == 16_000, "Whisper erwartet 16 kHz mono")
        let pipe = try await loadedPipe()
        // Detect the spoken language per clip. Without this WhisperKit's default
        // (usePrefillPrompt = true ⇒ detectLanguage = false, language = nil) pins
        // the language to English, so German speech comes out *translated* into
        // English rather than transcribed. `.transcribe` (never `.translate`)
        // keeps the words in whatever language was actually spoken (DE or EN).
        let options = Self.decodingOptions(languages: SpokenLanguages.load())
        // WhisperKit consumes 16 kHz mono Float32 — exactly what Notable records.
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decoding options for a spoken-language profile.
    ///
    /// With exactly one language in the profile there is nothing to detect:
    /// pinning it skips the detection pass and removes a whole class of
    /// misrecognition. With two, detection stays on — WhisperKit has no
    /// candidate-list option like whisper.cpp, so it is all or one.
    ///
    /// `.transcribe` (never `.translate`) either way: without it German speech
    /// comes back translated into English rather than transcribed.
    static func decodingOptions(languages: [String]) -> DecodingOptions {
        let codes = languages.isEmpty ? SpokenLanguages.fallback : languages
        guard codes.count == 1, let only = codes.first else {
            return DecodingOptions(task: .transcribe, detectLanguage: true)
        }
        return DecodingOptions(task: .transcribe, language: only, detectLanguage: false)
    }

    /// Lazily loads on first use if `prepare()` was never called (e.g. the
    /// warm-load at launch failed and the user dictates anyway).
    private func loadedPipe() async throws -> WhisperKit {
        if let pipe { return pipe }
        try await prepare()
        guard let pipe else { throw WhisperError.notLoaded }
        return pipe
    }

    enum WhisperError: LocalizedError {
        case notLoaded
        var errorDescription: String? { String(localized: "Whisper-Modell nicht geladen.") }
    }
}
