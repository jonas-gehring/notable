import AVFoundation
import Foundation
import os

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

    // MARK: - Real-time capture path

    /// Buffers handed over by a CoreAudio IO proc but not yet converted.
    private var ingest: RealtimeIngest?

    /// Buffers the IO proc could not hand over because the ring was full.
    /// A drop shortens the track against the wall clock, so it must be
    /// countable rather than invisible.
    var droppedBuffers: Int { ingest?.dropped ?? 0 }

    /// Opens the real-time path for a tap delivering `format`.
    ///
    /// Must be called before the device is started and after `reset` — the
    /// consumer thread it starts is what does all the actual work.
    func beginRealtimeCapture(format: AVAudioFormat) {
        endRealtimeCapture()
        ingest = RealtimeIngest(format: format) { [weak self] buffer in
            self?.append(buffer)
        }
    }

    /// Hands the IO proc's buffer list over. **This is the only method that may
    /// be called from a CoreAudio IO thread.**
    ///
    /// It does exactly one thing: `memcpy` into a slot that was allocated
    /// before the device started. No conversion, no `Data`, no `FileHandle`,
    /// no lock that anything slow also takes. The previous version ran the
    /// whole `append` path here — two `AVAudioPCMBuffer` allocations, an
    /// `AVAudioConverter`, an `NSLock` that `padGapToWallClock` could hold for
    /// *minutes*, and a write syscall — on the thread CoreAudio gives a
    /// deadline of one buffer period. Overrunning it drops tap buffers, which
    /// shortens the system track against the wall clock and mis-assigns every
    /// later speaker: precisely the damage the gap padding exists to prevent.
    func appendFromIOProc(_ list: UnsafePointer<AudioBufferList>) {
        ingest?.submit(list)
    }

    /// Stops the consumer thread and waits for the ring to be emptied, so
    /// everything the tap delivered is in the spool before `drain` reads it.
    func endRealtimeCapture() {
        ingest?.finish()
        ingest = nil
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
        // Anything still in the ring belongs to this recording.
        endRealtimeCapture()
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

/// Single-producer/single-consumer hand-off between a CoreAudio IO thread and
/// a normal thread.
///
/// The slots are `AVAudioPCMBuffer`s allocated once, up front: the producer
/// only ever memcpys into one and moves an index, which is what makes it usable
/// from a thread with a hard deadline. The consumer is a dedicated thread
/// woken by a semaphore rather than a `DispatchQueue` — `dispatch_async` may
/// allocate, `sema.signal()` does not.
///
/// A full ring drops the buffer and counts it. Dropping is the correct
/// behaviour under sustained overload (the alternative is blocking the IO
/// thread, which drops it anyway *and* takes the rest of the system with it),
/// but it must be visible, so the count is exposed.
private final class RealtimeIngest: @unchecked Sendable {
    /// 24 slots × 16384 frames covers roughly eight seconds of stereo audio at
    /// 48 kHz — long enough to ride out a spool write that hits a slow disk,
    /// small enough (≈ 3 MB) to allocate without thinking about it.
    private static let slotCount = 24
    private static let slotFrames: AVAudioFrameCount = 16_384

    private let slots: [AVAudioPCMBuffer]
    private let consume: (AVAudioPCMBuffer) -> Void
    private let semaphore = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)

    /// Guards `writeIndex`/`readIndex` only. Held for a handful of
    /// instructions with no allocation, no syscall and no I/O inside — the
    /// property that makes it acceptable on the audio thread, and the property
    /// the old `NSLock` around the whole conversion did not have.
    private let indexLock = OSAllocatedUnfairLock(initialState: Indices())
    private struct Indices { var write = 0; var read = 0 }

    private let droppedLock = OSAllocatedUnfairLock(initialState: 0)
    var dropped: Int { droppedLock.withLock { $0 } }

    private var running = true
    private var thread: Thread?

    init?(format: AVAudioFormat, consume: @escaping (AVAudioPCMBuffer) -> Void) {
        var allocated: [AVAudioPCMBuffer] = []
        allocated.reserveCapacity(Self.slotCount)
        for _ in 0..<Self.slotCount {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.slotFrames) else {
                return nil
            }
            allocated.append(buffer)
        }
        slots = allocated
        self.consume = consume

        let thread = Thread { [weak self] in self?.run() }
        thread.name = "de.jonasgehring.notable.pcm-ingest"
        // Above default, below the audio thread: this is the consumer of a
        // real-time producer, so falling behind costs recorded audio.
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    /// Called from the IO thread.
    func submit(_ list: UnsafePointer<AudioBufferList>) {
        let indices = indexLock.withLock { $0 }
        guard indices.write - indices.read < Self.slotCount else {
            droppedLock.withLock { $0 += 1 }
            return
        }
        let slot = slots[indices.write % Self.slotCount]
        guard Self.copy(from: list, into: slot) else {
            droppedLock.withLock { $0 += 1 }
            return
        }
        indexLock.withLock { $0.write += 1 }
        semaphore.signal()
    }

    /// memcpy per channel buffer. Returns false when the layout does not match
    /// the format the slots were allocated for, or the chunk is larger than a
    /// slot — both are drops, not crashes.
    private static func copy(from list: UnsafePointer<AudioBufferList>, into slot: AVAudioPCMBuffer) -> Bool {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let destination = UnsafeMutableAudioBufferListPointer(slot.mutableAudioBufferList)
        guard source.count == destination.count, let first = source.first else { return false }

        let channelsPerBuffer = max(Int(first.mNumberChannels), 1)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channelsPerBuffer)
        guard frames > 0, frames <= Int(slot.frameCapacity) else { return false }
        // Sets every destination `mDataByteSize` — do it before the copy.
        slot.frameLength = AVAudioFrameCount(frames)

        for index in 0..<source.count {
            guard let sourceData = source[index].mData, let destinationData = destination[index].mData else {
                return false
            }
            let bytes = min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize))
            memcpy(destinationData, sourceData, bytes)
        }
        return true
    }

    /// Consumer thread: convert, meter and spool, off the audio thread.
    private func run() {
        while true {
            semaphore.wait()
            if !running, indexLock.withLock({ $0.read == $0.write }) { break }
            while true {
                let indices = indexLock.withLock { $0 }
                guard indices.read < indices.write else { break }
                consume(slots[indices.read % Self.slotCount])
                indexLock.withLock { $0.read += 1 }
            }
            if !running { break }
        }
        finished.signal()
    }

    /// Stops the consumer once the ring is empty. Called from `drain`/`stop`,
    /// so nothing the tap delivered is lost between the last buffer and the
    /// spool being read.
    func finish() {
        guard thread != nil else { return }
        running = false
        semaphore.signal()
        finished.wait()
        thread = nil
    }
}
