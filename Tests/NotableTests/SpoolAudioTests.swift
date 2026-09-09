import AVFoundation
import XCTest

/// The spool format is the one place where a mistake destroys the only copy of
/// a recording whose transcription already failed. So every claim the format
/// makes — the round trip, the error bound, the archive being lossless, the old
/// files staying readable — is pinned here rather than believed.
final class SpoolAudioTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-audio-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A test signal with quiet passages, loud passages, and both extremes.
    private func signal(count: Int = 4096) -> [Float] {
        (0 ..< count).map { index in
            let phase = Float(index) * 0.037
            let envelope = index % 512 < 64 ? Float(0.00005) : Float(0.8)
            return sinf(phase) * envelope
        } + [1.0, -1.0, 0, 0.5, -0.5]
    }

    // MARK: - Format identification

    func testFormatComesFromTheExtension() {
        XCTAssertEqual(SpoolAudio.Format.of(URL(fileURLWithPath: "/tmp/mic.i16")), .int16)
        XCTAssertEqual(SpoolAudio.Format.of(URL(fileURLWithPath: "/tmp/mic.pcm")), .float32)
        XCTAssertEqual(SpoolAudio.Format.of(URL(fileURLWithPath: "/tmp/mic.m4a")), .alac)
        // Anything unlabelled is what the very first spools were.
        XCTAssertEqual(SpoolAudio.Format.of(URL(fileURLWithPath: "/tmp/mic")), .float32)
    }

    // MARK: - Int16

    func testInt16RoundTripStaysInsideTheStatedError() {
        for sample in signal() {
            let back = SpoolAudio.decode(SpoolAudio.encode(sample))
            XCTAssertEqual(back, sample, accuracy: SpoolAudio.roundTripError)
        }
    }

    func testInt16ClampsInsteadOfWrapping() {
        // A converter can hand over values outside ±1; wrapping them would turn
        // the loudest sample of a recording into the quietest.
        XCTAssertEqual(SpoolAudio.encode(2.0), 32_767)
        XCTAssertEqual(SpoolAudio.encode(-2.0), -32_767)
        XCTAssertEqual(SpoolAudio.encode(.infinity), 32_767)
        XCTAssertEqual(SpoolAudio.encode(.nan), 0, "NaN darf nicht in eine Konvertierung laufen")
    }

    /// The reason the format change is invisible to everything else: the
    /// rounding error is four orders of magnitude below the threshold that
    /// decides whether a track counts as silent.
    func testQuantizationDoesNotChangeTheSilenceVerdict() {
        let quiet = (0 ..< 1000).map { sinf(Float($0)) * 5e-4 }
        let silent = [Float](repeating: 0, count: 1000)
        let requantize: ([Float]) -> [Float] = { $0.map { SpoolAudio.decode(SpoolAudio.encode($0)) } }

        // A low sample rate makes 1000 samples long enough to be judged at all
        // (`TrackSilence.minimumSeconds`); the verdict itself is about levels.
        let judge: ([Float]) -> Bool = { TrackSilence.isSilent($0, sampleRate: 100) }
        XCTAssertTrue(SpoolAudio.roundTripError < TrackSilence.peakThreshold)
        XCTAssertEqual(judge(quiet), judge(requantize(quiet)))
        XCTAssertEqual(judge(silent), judge(requantize(silent)))
        XCTAssertTrue(judge(requantize(silent)))
        XCTAssertFalse(judge(requantize(quiet)), "Eine leise Spur bleibt hörbar")
    }

    func testInt16FileIsHalfTheSizeOfFloat32() throws {
        let directory = temporaryDirectory()
        let samples = signal()
        let float = directory.appendingPathComponent("a.pcm")
        let int16 = directory.appendingPathComponent("a.i16")
        var scratch: [Int16] = []
        try samples.withUnsafeBufferPointer { buffer in
            try SpoolAudio.encode(buffer, as: .float32, scratch: &scratch).write(to: float)
            try SpoolAudio.encode(buffer, as: .int16, scratch: &scratch).write(to: int16)
        }
        let floatBytes = try Data(contentsOf: float).count
        let int16Bytes = try Data(contentsOf: int16).count
        XCTAssertEqual(floatBytes, int16Bytes * 2)
        XCTAssertEqual(SpoolAudio.read(float), samples)
        for (read, original) in zip(SpoolAudio.read(int16), samples) {
            XCTAssertEqual(read, original, accuracy: SpoolAudio.roundTripError)
        }
    }

    /// A crash can cut the file mid-sample. Whole samples only, no crash.
    func testTruncatedFileYieldsWholeSamples() throws {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("t.i16")
        try Data([0x01, 0x02, 0x03]).write(to: url)
        XCTAssertEqual(SpoolAudio.read(url).count, 1)
        XCTAssertTrue(SpoolAudio.read(directory.appendingPathComponent("nothing.i16")).isEmpty)
    }

    // MARK: - ALAC

    func testAlacRoundTripIsSampleIdentical() throws {
        let directory = temporaryDirectory()
        let samples = signal()
        let source = directory.appendingPathComponent("mic.i16")
        let destination = directory.appendingPathComponent("mic.m4a")
        var scratch: [Int16] = []
        try samples.withUnsafeBufferPointer {
            try SpoolAudio.encode($0, as: .int16, scratch: &scratch).write(to: source)
        }

        try SpoolAudio.compress(source, to: destination)
        XCTAssertTrue(try SpoolAudio.verify(destination, matches: source))

        let original = SpoolAudio.read(source)
        let decoded = SpoolAudio.read(destination)
        XCTAssertEqual(decoded.count, original.count)
        XCTAssertEqual(decoded, original, "ALAC ist verlustfrei — kein Toleranzbereich")
    }

    /// The verification has to actually be able to fail, or it is decoration.
    func testVerifyRejectsAMismatch() throws {
        let directory = temporaryDirectory()
        let samples = signal()
        let source = directory.appendingPathComponent("mic.i16")
        let other = directory.appendingPathComponent("other.i16")
        let destination = directory.appendingPathComponent("mic.m4a")
        var scratch: [Int16] = []
        try samples.withUnsafeBufferPointer {
            try SpoolAudio.encode($0, as: .int16, scratch: &scratch).write(to: source)
        }
        try samples.reversed().withUnsafeBufferPointer {
            try SpoolAudio.encode($0, as: .int16, scratch: &scratch).write(to: other)
        }
        try SpoolAudio.compress(source, to: destination)
        XCTAssertFalse(try SpoolAudio.verify(destination, matches: other))

        // Same start, different length.
        let shorter = directory.appendingPathComponent("shorter.i16")
        try Array(samples.prefix(1000)).withUnsafeBufferPointer {
            try SpoolAudio.encode($0, as: .int16, scratch: &scratch).write(to: shorter)
        }
        XCTAssertFalse(try SpoolAudio.verify(destination, matches: shorter))
    }

    /// A Float32 archive is quantized on the way in — that is Stufe 1 applied
    /// retroactively, and what comes back must equal what went in *after* that
    /// step, not the raw floats.
    func testCompressingALegacyFloat32TrackQuantizesAndVerifies() throws {
        let directory = temporaryDirectory()
        let samples = signal()
        let source = directory.appendingPathComponent("mic.pcm")
        let destination = directory.appendingPathComponent("mic.m4a")
        try samples.withUnsafeBufferPointer { try Data(buffer: $0).write(to: source) }

        try SpoolAudio.compress(source, to: destination)
        XCTAssertTrue(try SpoolAudio.verify(destination, matches: source))
        for (decoded, original) in zip(SpoolAudio.read(destination), samples) {
            XCTAssertEqual(decoded, original, accuracy: SpoolAudio.roundTripError)
        }
    }

    // MARK: - The archiver

    func testArchiverCompressesASessionAndKeepsNothingRaw() throws {
        let directory = temporaryDirectory()
        let session = SpoolStore.Session(directory: directory)
        let samples = signal()
        var scratch: [Int16] = []
        for track in SpoolStore.Track.allCases {
            try samples.withUnsafeBufferPointer {
                try SpoolAudio.encode($0, as: .int16, scratch: &scratch)
                    .write(to: session.writeURL(track))
            }
        }

        let outcome = SpoolArchiver.compress(sessionAt: directory)
        XCTAssertEqual(outcome.compressedTracks, 2)
        XCTAssertTrue(outcome.failures.isEmpty)
        for track in SpoolStore.Track.allCases {
            XCTAssertEqual(session.recordedURL(track)?.pathExtension, "m4a")
            XCTAssertFalse(FileManager.default.fileExists(atPath: session.writeURL(track).path),
                           "Die Rohspur wird erst nach der Prüfung entfernt — und dann ganz")
            XCTAssertEqual(SpoolStore.readTrack(track, of: session), samples.map {
                SpoolAudio.decode(SpoolAudio.encode($0))
            })
        }

        // Idempotent: a second pass has nothing left to do.
        XCTAssertEqual(SpoolArchiver.compress(sessionAt: directory).compressedTracks, 0)
    }

    func testArchivePlanCountsOnlyWhatIsStillRaw() throws {
        let root = temporaryDirectory()
        let samples = signal()
        var scratch: [Int16] = []
        for name in ["a", "b"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try samples.withUnsafeBufferPointer {
                try SpoolAudio.encode($0, as: .int16, scratch: &scratch)
                    .write(to: SpoolStore.Session(directory: directory).writeURL(.mic))
            }
        }

        let before = SpoolArchiver.plan(in: root)
        XCTAssertEqual(before.sessions, 2)
        XCTAssertEqual(before.tracks, 2)
        XCTAssertGreaterThan(before.currentBytes, 0)

        _ = SpoolArchiver.compress(sessionAt: root.appendingPathComponent("a", isDirectory: true))
        let after = SpoolArchiver.plan(in: root)
        XCTAssertEqual(after.sessions, 1, "Eine bereits komprimierte Sitzung steht nicht mehr im Plan")
        XCTAssertTrue(SpoolArchiver.plan(in: root.appendingPathComponent("gibtesnicht")).isEmpty)
    }
}
