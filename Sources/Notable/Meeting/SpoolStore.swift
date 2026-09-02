import Foundation

/// Disk spool for in-flight meeting recordings: raw Float32 PCM per track
/// plus a metadata file. A crash mid-meeting leaves the session on disk;
/// the next launch recovers it into a note instead of losing the meeting.
enum SpoolStore {
    struct Meta: Codable, Sendable {
        var startedAt: Date
        var eventTitle: String?
        var eventID: String?
    }

    struct Session: Sendable {
        let directory: URL

        var micURL: URL { directory.appendingPathComponent("mic.pcm") }
        var systemURL: URL { directory.appendingPathComponent("system.pcm") }
        var metaURL: URL { directory.appendingPathComponent("meta.json") }
        /// The notes typed during the call. Lives beside the audio so a crash
        /// (or a deferred, recovery-bound meeting) keeps them together with the
        /// recording they belong to.
        var notesURL: URL { directory.appendingPathComponent("notes.md") }
    }

    static var baseURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notable/spool", isDirectory: true)
    }

    static func create(meta: Meta, base: URL = SpoolStore.baseURL) throws -> Session {
        let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = Session(directory: directory)
        try JSONEncoder().encode(meta).write(to: session.metaURL, options: .atomic)
        return session
    }

    /// Recovery failures are parked here instead of deleted — salvageable
    /// by hand, never retried automatically.
    static var failedURL: URL { baseURL.deletingLastPathComponent().appendingPathComponent("spool-failed", isDirectory: true) }

    static func markFailed(_ session: Session) {
        try? FileManager.default.createDirectory(at: failedURL, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(
            at: session.directory,
            to: failedURL.appendingPathComponent(session.directory.lastPathComponent)
        )
    }

    /// Sessions left behind by a crash (meta.json present).
    static func orphans(base: URL = SpoolStore.baseURL) -> [(session: Session, meta: Meta)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil
        ) else { return [] }

        return entries.compactMap { directory in
            let session = Session(directory: directory)
            guard let data = try? Data(contentsOf: session.metaURL),
                  let meta = try? JSONDecoder().decode(Meta.self, from: data)
            else { return nil }
            return (session, meta)
        }
        .sorted { $0.meta.startedAt < $1.meta.startedAt }
    }

    /// Reads a raw Float32 PCM spool file; missing file = empty track.
    /// Memory-mapped: an hour-long track is ~230 MB, and the pipeline reads
    /// two of them — eager `Data(contentsOf:)` would double the peak on top
    /// of the unavoidable [Float] copy (the ASR API takes [Float]).
    static func readSamples(_ url: URL) -> [Float] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), !data.isEmpty else { return [] }
        // A crash can truncate the file mid-float; convert whole floats only.
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        samples.withUnsafeMutableBufferPointer { buffer in
            _ = data.copyBytes(to: buffer, from: 0 ..< count * MemoryLayout<Float>.size)
        }
        return samples
    }

    static func remove(_ session: Session) {
        try? FileManager.default.removeItem(at: session.directory)
    }

    // MARK: - Live notes

    /// Mirrors the notes typed during the call into the session. `nil` (or an
    /// all-whitespace buffer) removes the file, so "no notes" never leaves a
    /// stale copy behind for recovery to pick up. Called off the main actor by
    /// the autosave, hence the plain, throw-free file writes.
    static func writeNotes(_ text: String?, to session: Session) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try? FileManager.default.removeItem(at: session.notesURL)
            return
        }
        try? text.write(to: session.notesURL, atomically: true, encoding: .utf8)
    }

    /// Notes left in a session, or `nil` when none were typed.
    static func readNotes(_ session: Session) -> String? {
        guard let text = try? String(contentsOf: session.notesURL, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Retained raw audio of successfully-processed meetings — kept (not deleted)
    /// so a meeting can be re-transcribed and so capture problems stay
    /// diagnosable — the "keep audio until everything is reliable" decision. Out of the crash-recovery scan (different dir), so it is never
    /// reprocessed automatically.
    static var archiveURL: URL { baseURL.deletingLastPathComponent().appendingPathComponent("spool-archive", isDirectory: true) }

    static func archive(_ session: Session) {
        try? FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(
            at: session.directory,
            to: archiveURL.appendingPathComponent(session.directory.lastPathComponent)
        )
    }
}
