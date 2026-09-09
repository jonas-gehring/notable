import AVFoundation
import Foundation

/// How a spooled audio track is stored on disk — and the only place that
/// knows how to turn each variant back into `[Float]`.
///
/// **The format is the file extension, not an assumption.** Up to v1.1 the
/// spool was raw Float32 and both sides simply agreed on it: the writer wrote
/// `Data(buffer:)`, the reader divided the file size by
/// `MemoryLayout<Float>.size`. That works exactly as long as there is only ever
/// one format, and it fails silently the moment there are two — a Float32 file
/// read as Int16 is not an error, it is twice as many samples of noise. So the
/// extension carries the format, a file written by an older version stays
/// readable forever, and the decision lives in one function instead of on both
/// sides of it.
enum SpoolAudio {
    enum Format: Sendable {
        /// `.pcm` — raw Float32. Written up to v1.1, still read.
        case float32
        /// `.i16` — raw Int16. Half the bytes, same speech.
        case int16
        /// `.m4a` — Apple Lossless. Written when a session is archived.
        case alac

        var fileExtension: String {
            switch self {
            case .float32: "pcm"
            case .int16: "i16"
            case .alac: "m4a"
            }
        }

        static func of(_ url: URL) -> Format {
            switch url.pathExtension.lowercased() {
            case "i16": .int16
            case "m4a": .alac
            default: .float32
            }
        }
    }

    /// The format new recordings are written in.
    ///
    /// 16 kHz mono Float32 is 64 KB/s; Int16 is 32 KB/s for the same speech.
    /// The ASR models are trained on 16-bit audio and everything upstream comes
    /// out of an `AVAudioConverter` fed by a microphone — there is no dynamic
    /// range in there that 24 bits of mantissa are protecting.
    static let current: Format = .int16

    // MARK: - Sample conversion

    /// Int16 full scale. 32767 rather than 32768 so that +1.0 and −1.0 map to
    /// the two endpoints symmetrically; the asymmetry that buys (−1.0 is one
    /// step short of Int16.min) is worth less than a round-trip that is exact
    /// in both directions.
    private static let fullScale: Float = 32_767

    @inline(__always)
    static func encode(_ sample: Float) -> Int16 {
        let scaled = (sample * fullScale).rounded()
        // NaN compares false against everything, so neither clamp below would
        // catch it and `Int16(Float.nan)` traps. Infinity is *not* the same
        // case: it is a level, absurdly loud, and belongs at the endpoint —
        // sending it to zero would turn the loudest sample into silence.
        guard !scaled.isNaN else { return 0 }
        if scaled >= fullScale { return Int16(fullScale) }
        if scaled <= -fullScale { return Int16(-fullScale) }
        return Int16(scaled)
    }

    @inline(__always)
    static func decode(_ value: Int16) -> Float {
        Float(value) / fullScale
    }

    /// The rounding error of one `encode`/`decode` round-trip.
    ///
    /// 1.5·10⁻⁵ — four orders of magnitude below `TrackSilence.peakThreshold`
    /// (1e-4), which is what makes the format change invisible to the silence
    /// detection that guards every capture regression.
    static let roundTripError: Float = 0.5 / fullScale

    // MARK: - Reading

    /// Reads a spooled track; a missing file is an empty track, never an error.
    ///
    /// Memory-mapped for the raw formats: an hour-long track is ~230 MB (~115 MB
    /// as Int16) and the pipeline reads two of them, so an eager
    /// `Data(contentsOf:)` would double the peak on top of the unavoidable
    /// `[Float]` copy that the ASR API demands.
    static func read(_ url: URL) -> [Float] {
        switch Format.of(url) {
        case .float32: readRaw(url, as: Float.self, convert: { $0 })
        case .int16: readRaw(url, as: Int16.self, convert: decode)
        case .alac: readCompressed(url)
        }
    }

    private static func readRaw<T: AdditiveArithmetic>(
        _ url: URL, as type: T.Type, convert: (T) -> Float
    ) -> [Float] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), !data.isEmpty else { return [] }
        // A crash can truncate the file mid-sample; whole samples only.
        let count = data.count / MemoryLayout<T>.size
        guard count > 0 else { return [] }
        var raw = [T](repeating: .zero, count: count)
        raw.withUnsafeMutableBufferPointer { buffer in
            _ = data.copyBytes(to: buffer, from: 0 ..< count * MemoryLayout<T>.size)
        }
        return raw.map(convert)
    }

    private static func readCompressed(_ url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        else { return [] }
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames)
        else { return [] }
        while true {
            do { try file.read(into: buffer) } catch { return samples }
            let count = Int(buffer.frameLength)
            guard count > 0, let channel = buffer.int16ChannelData else { break }
            for index in 0 ..< count { samples.append(decode(channel[0][index])) }
        }
        return samples
    }

    // MARK: - Writing

    /// Encodes one converted chunk for the spool file. `scratch` is the
    /// caller's reusable buffer — this runs once per audio chunk on the ingest
    /// thread, and an allocation per chunk is a cost with no upside.
    static func encode(
        _ chunk: UnsafeBufferPointer<Float>, as format: Format, scratch: inout [Int16]
    ) -> Data {
        switch format {
        case .float32:
            return Data(buffer: chunk)
        case .int16, .alac:
            // `.alac` cannot be written incrementally; it is only ever produced
            // by `compress`, so treat it as the raw format it is derived from.
            if scratch.count < chunk.count {
                scratch = [Int16](repeating: 0, count: chunk.count)
            }
            for index in 0 ..< chunk.count { scratch[index] = encode(chunk[index]) }
            return scratch.withUnsafeBytes {
                Data($0.prefix(chunk.count * MemoryLayout<Int16>.size))
            }
        }
    }

    // MARK: - Lossless compression

    /// Frames per read/write buffer — one second of 16 kHz audio. Small enough
    /// that compressing a 400 MB track never holds more than a few hundred
    /// kilobytes at once, which is the whole point of doing it streaming.
    private static let chunkFrames: AVAudioFrameCount = 16_384

    private static var alacSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: Double(PCMDownsampler.targetSampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16,
        ]
    }

    enum CompressionError: LocalizedError {
        case unreadableSource
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .unreadableSource: String(localized: "Die Rohspur ließ sich nicht lesen.")
            case .verificationFailed: String(localized: "Die komprimierte Spur stimmt nicht mit der Rohspur überein.")
            }
        }
    }

    /// Rewrites a raw spool track as Apple Lossless.
    ///
    /// **Lossless with respect to Int16, not to the Float32 file.** A `.pcm`
    /// source is quantized on the way in — that is Stufe 1 applied to an old
    /// file, and it is the only sensible reading, since ALAC is a 16-bit
    /// container. What is guaranteed, and verified, is that what comes back out
    /// equals what went in.
    ///
    /// Streaming throughout: the source is memory-mapped and walked in chunks,
    /// so an 800 MB session costs time and not memory.
    static func compress(_ source: URL, to destination: URL) throws {
        guard let data = try? Data(contentsOf: source, options: .alwaysMapped) else {
            throw CompressionError.unreadableSource
        }
        let file = try AVAudioFile(
            forWriting: destination, settings: alacSettings,
            commonFormat: .pcmFormatInt16, interleaved: true
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames)
        else { throw CompressionError.unreadableSource }

        try forEachChunk(of: data, format: Format.of(source)) { samples in
            guard let channel = buffer.int16ChannelData else { throw CompressionError.unreadableSource }
            for (index, value) in samples.enumerated() { channel[0][index] = value }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            try file.write(from: buffer)
        }
    }

    /// Reads `compressed` back and compares it with `source`, sample for
    /// sample. Streaming, so verifying costs no more memory than compressing.
    ///
    /// This is not belt-and-braces: the archive exists so a recording whose
    /// transcription failed can still be rescued by hand, and a compression
    /// that quietly mangled it would only be discovered on the day it is needed.
    static func verify(_ compressed: URL, matches source: URL) throws -> Bool {
        guard let data = try? Data(contentsOf: source, options: .alwaysMapped) else {
            throw CompressionError.unreadableSource
        }
        let file = try AVAudioFile(forReading: compressed, commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames)
        else { return false }

        var pending: [Int16] = []
        var mismatch = false
        try forEachChunk(of: data, format: Format.of(source)) { samples in
            var offset = 0
            while offset < samples.count {
                if pending.isEmpty {
                    try file.read(into: buffer)
                    guard buffer.frameLength > 0, let channel = buffer.int16ChannelData else {
                        mismatch = true
                        return
                    }
                    pending = Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
                }
                let take = min(pending.count, samples.count - offset)
                if !pending.prefix(take).elementsEqual(samples[offset ..< offset + take]) {
                    mismatch = true
                    return
                }
                pending.removeFirst(take)
                offset += take
            }
        }
        guard !mismatch else { return false }
        // Anything left on either side means the lengths differ.
        if !pending.isEmpty { return false }
        try? file.read(into: buffer)
        return buffer.frameLength == 0
    }

    /// Walks a mapped raw track in Int16 chunks, whatever it was written as.
    private static func forEachChunk(
        of data: Data, format: Format, _ body: ([Int16]) throws -> Void
    ) throws {
        let stride = format == .float32 ? MemoryLayout<Float>.size : MemoryLayout<Int16>.size
        let total = data.count / stride
        var offset = 0
        while offset < total {
            let count = min(Int(chunkFrames), total - offset)
            var chunk = [Int16](repeating: 0, count: count)
            if format == .float32 {
                var floats = [Float](repeating: 0, count: count)
                floats.withUnsafeMutableBufferPointer { buffer in
                    _ = data.copyBytes(to: buffer, from: offset * stride ..< (offset + count) * stride)
                }
                for index in 0 ..< count { chunk[index] = encode(floats[index]) }
            } else {
                chunk.withUnsafeMutableBufferPointer { buffer in
                    _ = data.copyBytes(to: buffer, from: offset * stride ..< (offset + count) * stride)
                }
            }
            try body(chunk)
            offset += count
        }
    }
}
