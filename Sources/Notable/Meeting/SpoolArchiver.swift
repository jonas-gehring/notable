import Foundation
import os

/// Turns the raw tracks of an archived session into Apple Lossless.
///
/// The archive is the one place in the spool that Notable **never reads back**:
/// crash recovery walks `spool/`, retention only ever measures directory sizes.
/// That is what makes re-encoding it safe — no other code has an opinion about
/// the format, only a human rescuing a recording by hand does, and for them a
/// `.m4a` that QuickTime opens is a clear improvement over a headerless `.pcm`.
///
/// The compression is deliberately *lossless*. The archive exists so that a
/// recording whose transcription failed can still be salvaged; putting it
/// through a codec that discards the quiet passages — which are exactly the
/// ones such a rescue is about — would be the wrong trade, however much smaller
/// the result.
enum SpoolArchiver {
    private static let log = Logger(subsystem: "de.jonasgehring.notable", category: "spool-archiver")

    /// Serial and off the cooperative pool: compressing an 800 MB session is
    /// minutes of I/O, and two of them at once only makes both slower.
    private static let queue = DispatchQueue(
        label: "de.jonasgehring.notable.spool-archiver", qos: .utility
    )

    struct Outcome: Sendable, Equatable {
        var compressedTracks = 0
        var bytesBefore: Int64 = 0
        var bytesAfter: Int64 = 0
        var failures: [String] = []

        var reclaimed: Int64 { max(0, bytesBefore - bytesAfter) }
    }

    /// What compressing everything in an archive directory would cost and save.
    ///
    /// The estimate is the measured factor for 16 kHz speech, stated as such —
    /// this is shown to the user before a job that runs for minutes, and a
    /// number pretending to be exact would be worse than an honest range.
    struct Plan: Sendable, Equatable {
        var sessions = 0
        var tracks = 0
        var currentBytes: Int64 = 0

        var isEmpty: Bool { tracks == 0 }
        /// ALAC on 16 kHz mono speech lands around 55 % of Int16; a Float32
        /// source halves first, so it lands around 27 % of what it is now.
        var estimatedBytes: Int64 { Int64(Double(currentBytes) * 0.55) }
    }

    // MARK: - One session

    /// Compresses a session's raw tracks in the background. Called on the way
    /// into the archive, where the alternative — doing it inline — would make
    /// the end of every meeting wait on minutes of encoding.
    static func compressInBackground(sessionAt directory: URL) {
        queue.async { _ = compress(sessionAt: directory) }
    }

    /// Compresses every raw track in one session directory. Synchronous.
    ///
    /// **The raw file is removed only after the compressed one has been read
    /// back and compared sample for sample.** Anything else — a failed encode,
    /// a mismatch, a crash halfway — leaves the original exactly where it was;
    /// the worst outcome is a session that stays large.
    static func compress(sessionAt directory: URL) -> Outcome {
        var outcome = Outcome()
        for track in SpoolStore.Track.allCases {
            let session = SpoolStore.Session(directory: directory)
            guard let source = session.recordedURL(track),
                  SpoolAudio.Format.of(source) != .alac else { continue }

            let sourceBytes = byteSize(source)
            let destination = directory
                .appendingPathComponent(track.rawValue)
                .appendingPathExtension(SpoolAudio.Format.alac.fileExtension)
            // A leftover from an interrupted earlier run would make
            // AVAudioFile(forWriting:) append to a file it did not create.
            try? FileManager.default.removeItem(at: destination)

            do {
                try SpoolAudio.compress(source, to: destination)
                guard try SpoolAudio.verify(destination, matches: source) else {
                    throw SpoolAudio.CompressionError.verificationFailed
                }
                try FileManager.default.removeItem(at: source)
                outcome.compressedTracks += 1
                outcome.bytesBefore += sourceBytes
                outcome.bytesAfter += byteSize(destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                outcome.failures.append("\(directory.lastPathComponent)/\(track.rawValue): \(error.localizedDescription)")
                log.error("Archiv-Komprimierung fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            }
        }
        return outcome
    }

    // MARK: - A whole archive directory

    static func plan(in root: URL, fileManager: FileManager = .default) -> Plan {
        var plan = Plan()
        for directory in sessionDirectories(in: root, fileManager: fileManager) {
            let session = SpoolStore.Session(directory: directory)
            var tracksHere = 0
            for track in SpoolStore.Track.allCases {
                guard let url = session.recordedURL(track),
                      SpoolAudio.Format.of(url) != .alac else { continue }
                tracksHere += 1
                plan.currentBytes += byteSize(url)
            }
            if tracksHere > 0 {
                plan.sessions += 1
                plan.tracks += tracksHere
            }
        }
        return plan
    }

    /// Compresses every session in an archive directory, oldest first.
    ///
    /// Offered from the storage pane, never run unasked: it is hours of I/O
    /// over files the user is keeping for an emergency, and starting that by
    /// itself at launch is not something a tool gets to decide.
    static func compressAll(in root: URL) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async {
                var total = Outcome()
                for directory in sessionDirectories(in: root) {
                    let outcome = compress(sessionAt: directory)
                    total.compressedTracks += outcome.compressedTracks
                    total.bytesBefore += outcome.bytesBefore
                    total.bytesAfter += outcome.bytesAfter
                    total.failures += outcome.failures
                }
                continuation.resume(returning: total)
            }
        }
    }

    private static func sessionDirectories(
        in root: URL, fileManager: FileManager = .default
    ) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func byteSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }
}
