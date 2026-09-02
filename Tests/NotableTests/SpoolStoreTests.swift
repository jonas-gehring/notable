import AVFoundation
import XCTest

final class SpoolStoreTests: XCTestCase {
    func testSpoolRoundTripAndOrphanListing() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-spool-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let meta = SpoolStore.Meta(
            startedAt: Date(timeIntervalSince1970: 1234),
            eventTitle: "Standup",
            eventID: "ev-1"
        )
        let session = try SpoolStore.create(meta: meta, base: base)

        // Raw Float32 PCM round trip.
        let samples: [Float] = [0.1, -0.5, 0.25, 1.0, -1.0]
        try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: session.micURL)
        XCTAssertEqual(SpoolStore.readSamples(session.micURL), samples)
        XCTAssertTrue(SpoolStore.readSamples(session.systemURL).isEmpty, "Fehlende Datei = leere Spur")

        let orphans = SpoolStore.orphans(base: base)
        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first?.meta.eventTitle, "Standup")
        XCTAssertEqual(orphans.first?.meta.startedAt, meta.startedAt)

        SpoolStore.remove(session)
        XCTAssertTrue(SpoolStore.orphans(base: base).isEmpty)
    }

    /// Notes typed during the call live in the session next to the audio, so a
    /// crash-recovered meeting still carries them into the note.
    func testLiveNotesRoundTripInTheSpool() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-spool-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let session = try SpoolStore.create(meta: SpoolStore.Meta(startedAt: Date()), base: base)
        XCTAssertNil(SpoolStore.readNotes(session), "Ohne Notizen gibt es keine Datei")

        SpoolStore.writeNotes("[00:12] Budget bis Q3 fixieren", to: session)
        XCTAssertEqual(SpoolStore.readNotes(session), "[00:12] Budget bis Q3 fixieren")

        // Deleting everything must remove the file, not leave a stale copy that
        // recovery would resurrect into the next note.
        SpoolStore.writeNotes("   \n ", to: session)
        XCTAssertNil(SpoolStore.readNotes(session))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.notesURL.path))

        SpoolStore.writeNotes("wieder da", to: session)
        SpoolStore.writeNotes(nil, to: session)
        XCTAssertNil(SpoolStore.readNotes(session))
    }

    func testDownsamplerSpoolsToDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-spooltest-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: url) }

        let downsampler = PCMDownsampler()
        try downsampler.reset(spoolingTo: url)

        // 16kHz mono buffer goes straight through the converter.
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for i in 0..<1600 { buffer.floatChannelData![0][i] = sinf(Float(i) * 0.1) * 0.3 }
        downsampler.append(buffer)

        XCTAssertTrue(downsampler.snapshot().isEmpty, "Im Spool-Modus bleibt RAM leer")
        let drained = downsampler.drain()
        XCTAssertEqual(drained.count, 1600)
        XCTAssertEqual(drained[10], sinf(1.0) * 0.3, accuracy: 0.01)
    }
}
