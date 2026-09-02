import AVFoundation
import Foundation

/// Accumulates PCM buffers of arbitrary format into 16 kHz mono Float32 —
/// the input format for VAD, ASR, and diarization. Append is called from
/// audio threads; the buffer is guarded by a lock.
final class PCMDownsampler: @unchecked Sendable {
    static let targetSampleRate = 16_000

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(PCMDownsampler.targetSampleRate),
        channels: 1,
        interleaved: false
    )!

    private let lock = NSLock()
    private var samples: [Float] = []
    private var levelValue: Float = 0
    private var spoolHandle: FileHandle?
    private var spoolURL: URL?
    /// Samples written since reset() — RAM and spool together.
    private var capturedCount = 0
    /// Wall clock at reset(); the reference for gap padding.
    private var anchor: Date?

    /// RMS of the most recent chunk (0…~1), for level metering.
    var currentLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return levelValue
    }
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func reset(spoolingTo url: URL? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
        levelValue = 0
        capturedCount = 0
        anchor = Date()
        converter = nil
        sourceFormat = nil
        try? spoolHandle?.close()
        spoolHandle = nil
        spoolURL = url
        if let url {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            spoolHandle = try FileHandle(forWritingTo: url)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        // The input block is invoked synchronously inside convert(); the
        // Sendable annotations on the imported API are stricter than reality.
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let inputBuffer = buffer
        var error: NSError?
        converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard error == nil, let channel = out.floatChannelData else { return }

        let count = Int(out.frameLength)
        let chunk = UnsafeBufferPointer(start: channel[0], count: count)
        var sumOfSquares: Float = 0
        for sample in chunk { sumOfSquares += sample * sample }
        let rms = count > 0 ? (sumOfSquares / Float(count)).squareRoot() : 0

        lock.lock()
        writeLocked(chunk)
        levelValue = rms
        lock.unlock()
    }

    /// Caller holds the lock.
    private func writeLocked(_ chunk: UnsafeBufferPointer<Float>) {
        if let spoolHandle {
            // Long recordings (meetings) go to disk — survives a crash and
            // keeps a 60-minute meeting out of RAM. The throwing write
            // variant avoids an uncatchable NSException on disk-full; on
            // failure we fall back to RAM accumulation.
            do {
                try spoolHandle.write(contentsOf: Data(buffer: chunk))
            } catch {
                try? spoolHandle.close()
                self.spoolHandle = nil
                samples.append(contentsOf: chunk)
            }
        } else {
            samples.append(contentsOf: chunk)
        }
        capturedCount += chunk.count
    }

    /// Fills the wall-clock hole an interrupted capture left behind (output
    /// device switched: the tap is re-installed a second or two later). The
    /// track is a timeline — without the silence, every later segment is
    /// stamped too early and the mic/system merge interleaves the wrong
    /// speaker for the rest of the meeting.
    func padGapToWallClock() {
        lock.lock()
        defer { lock.unlock() }
        guard let anchor else { return }
        let expected = Int(Date().timeIntervalSince(anchor) * Double(Self.targetSampleRate))
        let missing = expected - capturedCount
        // Ignore sub-100 ms drift (clock jitter); cap the pad so a slept
        // machine cannot allocate an unbounded block of silence.
        guard missing > Self.targetSampleRate / 10 else { return }

        // Pad the FULL gap. Capping it (an earlier version stopped at 60 s to
        // bound the allocation) turns a long outage — device gone for five
        // minutes, then reconnected — into exactly the timestamp drift this
        // exists to prevent, and the drift then also cuts the ASR slices from
        // the wrong offsets. Write it in chunks instead, so a long hole costs
        // time but never a single huge allocation.
        let chunk = Self.targetSampleRate * 10
        let silence = [Float](repeating: 0, count: min(missing, chunk))
        var written = 0
        while written < missing {
            let count = min(chunk, missing - written)
            silence.withUnsafeBufferPointer { buffer in
                writeLocked(UnsafeBufferPointer(rebasing: buffer[0..<count]))
            }
            written += count
        }
    }

    /// Copy of everything captured so far, without stopping.
    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func drain() -> [Float] {
        lock.lock()
        defer {
            samples.removeAll()
            lock.unlock()
        }
        if let spoolURL {
            try? spoolHandle?.close()
            spoolHandle = nil
            self.spoolURL = nil
            // RAM part is non-empty when a spool write failed mid-recording.
            return SpoolStore.readSamples(spoolURL) + samples
        }
        return samples
    }
}
