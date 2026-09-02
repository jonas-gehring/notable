import FluidAudio
import Foundation

/// Incremental decoding for long dictations: while recording, completed
/// stretches are transcribed with a carried decoder state; on release only
/// the short tail remains. Measured baseline (warm, M2 Pro): whole-clip is
/// ~120 ms at 5 s but ~400 ms at 60 s — this keeps long dictations under
/// the 200 ms release→paste target.
enum IncrementalDictation {
    /// Only clips longer than this get incremental treatment.
    static let minimumPendingSeconds = 8.0
    /// The most recent audio is never pre-transcribed (speech may continue).
    static let keepTailSeconds = 3.0
    /// Hard upper bound for a single decoder call. Above ASRConstants
    /// .maxModelSamples (240 000 = 15 s) FluidAudio's `transcribe(_:decoderState:)`
    /// routes into its *stateless* ChunkProcessor: the carried decoder state
    /// is then neither read nor written, so the thread of context silently
    /// snaps. Staying below it keeps every call on the stateful path.
    static let maximumSliceSeconds = 14.0
    /// FluidAudio rejects anything shorter (ASRConstants.minimumAudioDurationSeconds).
    static let minimumSliceSeconds = 0.3

    /// Finds the quietest 100 ms window in `samples[searchStart..<searchEnd]`
    /// and returns its center — a seam where cutting does not split a word.
    /// Pure and unit-tested.
    static func cutPoint(in samples: [Float], searchStart: Int, searchEnd: Int, sampleRate: Int) -> Int {
        let window = sampleRate / 10
        let start = max(0, searchStart)
        let end = min(samples.count, searchEnd)
        guard end - start >= window else { return end }

        var quietestStart = start
        var quietestEnergy = Float.greatestFiniteMagnitude
        var index = start
        while index + window <= end {
            var energy: Float = 0
            for sample in samples[index..<(index + window)] {
                energy += sample * sample
            }
            if energy < quietestEnergy {
                quietestEnergy = energy
                quietestStart = index
            }
            index += window / 2
        }
        return quietestStart + window / 2
    }

    /// True when a slice is too long for FluidAudio's *stateful* decoding path.
    ///
    /// Splitting it ourselves is not an option: a seam hands the next slice a
    /// decoder state built from cut-off audio, and TDT then predicts a token
    /// duration from it and jumps the frame pointer. Measured on a 26 s clip —
    /// a mid-sentence seam swallowed the following five seconds whole; even a
    /// seam placed inside a real pause ate the first word after it, because the
    /// encoder has no left context for the onset. FluidAudio's own chunker gets
    /// this right (overlap + token dedup) but is stateless, so the answer is to
    /// bail out to the whole-clip path instead of inventing seams.
    static func exceedsStatefulLimit(sampleCount: Int, sampleRate: Int) -> Bool {
        sampleCount > Int(maximumSliceSeconds * Double(sampleRate))
    }
}

/// One dictation's incremental decoding session. Calls must be serialized
/// by the owner (DictationController does).
final class DictationSession: @unchecked Sendable {
    /// Thrown when the session cannot absorb the audio without breaking the
    /// decoder state. The owner falls back to whole-clip transcription, which
    /// is always correct — just slower.
    enum SessionError: Error {
        case sliceExceedsStatefulLimit
    }

    private let manager: AsrManager
    private var state: TdtDecoderState
    private(set) var text = ""
    /// Samples already fed into the decoder.
    private(set) var processedCount = 0

    init(manager: AsrManager, decoderLayers: Int) {
        self.manager = manager
        self.state = TdtDecoderState.make(decoderLayers: decoderLayers)
    }

    /// Feeds `samples[processedCount..<cut]` where `cut` is a silence seam.
    /// Returns false when there is not enough pending audio to bother.
    func feedStableHead(from snapshot: [Float], sampleRate: Int) async throws -> Bool {
        let pending = snapshot.count - processedCount
        guard Double(pending) / Double(sampleRate) >= IncrementalDictation.minimumPendingSeconds else {
            return false
        }
        let keep = Int(IncrementalDictation.keepTailSeconds * Double(sampleRate))
        let cut = IncrementalDictation.cutPoint(
            in: snapshot,
            searchStart: snapshot.count - keep - sampleRate,
            searchEnd: snapshot.count - keep,
            sampleRate: sampleRate
        )
        guard cut > processedCount else { return false }
        try await feed(Array(snapshot[processedCount..<cut]), sampleRate: sampleRate)
        processedCount = cut
        return true
    }

    /// Final call after the recorder stopped: everything not yet processed.
    func finish(with allSamples: [Float], sampleRate: Int) async throws -> String {
        if allSamples.count > processedCount {
            try await feed(Array(allSamples[processedCount...]), sampleRate: sampleRate)
            processedCount = allSamples.count
        }
        return text
    }

    private func feed(_ samples: [Float], sampleRate: Int) async throws {
        // Above the limit FluidAudio would silently switch to its stateless
        // chunker: the carried state is then neither read nor updated, so
        // everything decoded so far stops informing what follows. Give up the
        // session instead — the caller re-runs the whole clip, correctly.
        guard !IncrementalDictation.exceedsStatefulLimit(
            sampleCount: samples.count, sampleRate: sampleRate
        ) else {
            throw SessionError.sliceExceedsStatefulLimit
        }
        let minimum = Int(IncrementalDictation.minimumSliceSeconds * Double(sampleRate))
        guard samples.count >= minimum else { return }
        // Copy-out/copy-in: inout of a stored property cannot cross an
        // actor call; the state is moved through a local.
        var local = state
        let result = try await manager.transcribe(samples, decoderState: &local)
        state = local
        let piece = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        text = text.isEmpty ? piece : text + " " + piece
    }
}
