import Foundation

/// Disk spool for in-flight meeting recordings: one raw PCM file per track
/// plus a metadata file. A crash mid-meeting leaves the session on disk;
/// the next launch recovers it into a note instead of losing the meeting.
///
/// The sample format lives in the file extension — see ``SpoolAudio``.
enum SpoolStore {
    struct Meta: Codable, Sendable {
        var startedAt: Date
        var eventTitle: String?
        var eventID: String?
    }

    /// The two audio tracks a session records. Their base names are fixed; the
    /// extension says what is in them.
    enum Track: String, CaseIterable, Sendable {
        case mic
        case system
    }

    struct Session: Sendable {
        let directory: URL

        /// Where a *new* recording writes this track.
        func writeURL(_ track: Track) -> URL {
            directory
                .appendingPathComponent(track.rawValue)
                .appendingPathExtension(SpoolAudio.current.fileExtension)
        }

        /// The file that actually holds this track, whatever wrote it.
        ///
        /// A spool that survives an update was written by the previous version,
        /// so recovery has to find `mic.pcm` as readily as `mic.i16` — the one
        /// case where getting the format wrong loses a whole meeting.
        func recordedURL(_ track: Track) -> URL? {
            let candidates: [SpoolAudio.Format] = [.int16, .float32, .alac]
            return candidates
                .map { directory.appendingPathComponent(track.rawValue).appendingPathExtension($0.fileExtension) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }

        var micURL: URL { writeURL(.mic) }
        var systemURL: URL { writeURL(.system) }
        var metaURL: URL { directory.appendingPathComponent("meta.json") }
        /// The notes typed during the call. Lives beside the audio so a crash
        /// (or a deferred, recovery-bound meeting) keeps them together with the
        /// recording they belong to.
        var notesURL: URL { directory.appendingPathComponent("notes.md") }
        /// Written the moment the note's Markdown file exists on disk — see
        /// ``markNoteWritten(_:)``.
        var doneURL: URL { directory.appendingPathComponent("note-written") }
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

    /// Marks a session as having produced its note.
    ///
    /// There is a window between the `.md` being written and the SQLite row
    /// being inserted. A crash inside it — or an `insertMeeting` that throws —
    /// left the spool looking untouched, so the next launch recovered it and
    /// wrote a *second* note, "Titel (2)", for a meeting that already had one.
    /// The marker is written first and costs nothing; the worst it can do is
    /// skip a recovery for a note that does exist.
    static func markNoteWritten(_ session: Session, noteURL: URL) {
        try? Data(noteURL.path.utf8).write(to: session.doneURL, options: .atomic)
    }

    /// Sessions left behind by a crash (meta.json present) that have not already
    /// produced a note.
    static func orphans(base: URL = SpoolStore.baseURL) -> [(session: Session, meta: Meta)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil
        ) else { return [] }

        return entries.compactMap { directory in
            let session = Session(directory: directory)
            guard let data = try? Data(contentsOf: session.metaURL),
                  let meta = try? JSONDecoder().decode(Meta.self, from: data)
            else { return nil }
            // Its note was already written; recovering it would duplicate it.
            guard !FileManager.default.fileExists(atPath: session.doneURL.path) else {
                archive(session)
                return nil
            }
            return (session, meta)
        }
        .sorted { $0.meta.startedAt < $1.meta.startedAt }
    }

    /// Reads a spool file in whichever format its extension declares; a
    /// missing file is an empty track.
    static func readSamples(_ url: URL) -> [Float] {
        SpoolAudio.read(url)
    }

    /// Reads one track of a session, finding the file whatever version wrote it.
    static func readTrack(_ track: Track, of session: Session) -> [Float] {
        guard let url = session.recordedURL(track) else { return [] }
        return SpoolAudio.read(url)
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
        let destination = archiveURL.appendingPathComponent(session.directory.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: session.directory, to: destination)
        } catch {
            return
        }
        // The move is a rename and is instant; the re-encode is minutes of I/O,
        // so it happens afterwards and out of the way. Failing it leaves the
        // raw tracks in place — the session stays large, nothing is lost.
        SpoolArchiver.compressInBackground(sessionAt: destination)
    }
}
