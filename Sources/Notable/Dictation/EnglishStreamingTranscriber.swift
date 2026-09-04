import AVFoundation
import FluidAudio
import Foundation

/// Selectable ASR engines. Parakeet v3 is the multilingual default;
/// Parakeet Unified is English-only but streams in real time and adds
/// punctuation/capitalization (WER 2.2 % streaming).
enum ASREngineID: String, CaseIterable, Identifiable {
    case parakeetV3 = "parakeet-v3"
    case unifiedEnglish = "unified-en"
    case whisper = "whisper"

    static let storageKey = "asrEngine"

    static var current: ASREngineID {
        UserDefaults.standard.string(forKey: storageKey).flatMap(ASREngineID.init(rawValue:)) ?? .parakeetV3
    }

    var id: String { rawValue }

    /// What goes into `recordings.engine` — the Whisper case carries its model
    /// size, because "whisper" alone says nothing about speed or quality and the
    /// latency card would average three different models into one number.
    var statisticsName: String {
        self == .whisper ? "whisper-\(WhisperModelSize.current.rawValue)" : rawValue
    }

    /// Just the name, for a one-line message where the qualifier is noise.
    var shortLabel: String {
        switch self {
        case .parakeetV3: "Parakeet v3"
        case .unifiedEnglish: "Parakeet Unified"
        case .whisper: "Whisper"
        }
    }

    /// Measured on disk (2026-09-01), not estimated: the spec guessed 2.4 GB for
    /// v3 and it is a fifth of that.
    var downloadSize: String {
        switch self {
        case .parakeetV3: "~485 MB"
        case .unifiedEnglish: "~580 MB"
        case .whisper: WhisperModelSize.current.sizeLabel
        }
    }

    /// `String(localized:)` per branch, like every other plain-`String` label:
    /// a `Text(engine.label)` renders this verbatim, so an unwrapped literal is
    /// German in an English window with nothing to warn about it.
    var label: String {
        switch self {
        case .parakeetV3: String(localized: "Parakeet v3 — mehrsprachig (Standard)")
        case .unifiedEnglish: String(localized: "Parakeet Unified — Englisch, Streaming")
        case .whisper: String(localized: "Whisper (OpenAI) — mehrsprachig")
        }
    }
}

/// Parakeet Unified: true streaming ASR. Chunks are fed while the user
/// speaks; on release only `finish()` remains.
final class EnglishStreamingTranscriber: @unchecked Sendable {
    private let manager = StreamingUnifiedAsrManager()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    /// Downloads (first run) and loads the CoreML models.
    func prepare() async throws {
        try await manager.loadModels()
    }

    /// Call before each utterance — clears window and transcript state.
    func beginUtterance() async throws {
        try await manager.reset()
    }

    /// Feeds 16 kHz mono samples and decodes all complete windows.
    func feed(_ chunk: [Float]) async throws {
        guard !chunk.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(chunk.count)
        chunk.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: chunk.count)
        }
        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
    }

    func partial() async -> String {
        await manager.getPartialTranscript()
    }

    /// Flushes the remaining audio and returns the final transcript.
    func finish() async throws -> String {
        try await manager.finish()
    }
}
