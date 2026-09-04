import Foundation

/// Coordinates note management (list / rename / move) while keeping SQLite and
/// the Markdown files in agreement. SQLite is the source of truth; every write
/// here re-projects the `.md` purely from the stored `Recording` + `Segment`s,
/// so the file can never drift from the database.
@MainActor
final class NoteManager: ObservableObject {
    /// The folder key every new note lands in; also the target of "move to Inbox".
    static let inboxFolder = "Inbox"

    /// Recent meeting notes, newest first — the list UI binds to this.
    @Published private(set) var notes: [RecordingStore.Recording] = []
    /// The project subfolders, cached.
    ///
    /// `projectFolders()` is a synchronous `contentsOfDirectory` scan, and it
    /// used to be called from inside the per-row `Menu` builder — up to two
    /// hundred directory listings while the list draws. It changes only when a
    /// folder is created or a note is moved, both of which end in `reload()`.
    @Published private(set) var projectFolders: [String] = []

    private let store: RecordingStore
    private let notesFolder: NotesFolderManager

    init(notesFolder: NotesFolderManager, store: RecordingStore = .shared) {
        self.notesFolder = notesFolder
        self.store = store
    }

    // MARK: - Listing

    func reload() async {
        notes = (try? await store.recentMeetings(limit: 200)) ?? []
        projectFolders = scanProjectFolders()
    }

    // MARK: - Folder model (Inbox + one flat level of project folders)

    /// The absolute directory for a folder key. `nil`/`""` means the notes root
    /// (legacy flat notes); anything else is a subfolder of the root.
    func url(forFolder key: String?) -> URL {
        guard let key, !key.isEmpty else { return notesFolder.folderURL }
        return notesFolder.folderURL.appendingPathComponent(key, isDirectory: true)
    }

    /// Existing project subfolders (every subdirectory of the root except the
    /// Inbox), sorted case-insensitively.
    func scanProjectFolders() -> [String] {
        let root = notesFolder.folderURL
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .filter { $0 != Self.inboxFolder }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Creates a project folder under the root and returns its sanitized key.
    /// Rejects empty names and the reserved "Inbox".
    @discardableResult
    func createFolder(named rawName: String) throws -> String {
        let key = Self.sanitizeFolderName(rawName)
        guard !key.isEmpty else { throw NoteError.invalidFolderName }
        guard key != Self.inboxFolder else { throw NoteError.reservedFolderName }
        try FileManager.default.createDirectory(at: url(forFolder: key), withIntermediateDirectories: true)
        return key
    }

    // MARK: - Rename

    /// Renames a note: re-projects the `.md` from the store under a fresh,
    /// collision-free name in the *same* folder, moves the file, and records the
    /// new title + path. The title is now user-owned (`titleIsAuto = false`).
    func rename(_ recording: RecordingStore.Recording, to newTitle: String) async throws {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw NoteError.emptyTitle }

        guard let loaded = try await store.meeting(id: recording.id) else { throw NoteError.notFound }
        let record = loaded.recording

        let directory = currentDirectory(for: record)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let currentURL = record.markdownPath.map { URL(fileURLWithPath: $0) }
        let target = directory.appendingPathComponent(
            MarkdownProjector.uniqueFileName(title: title, date: record.startedAt, in: directory, excluding: currentURL)
        )

        // Write, record, *then* delete. The other order deleted the old file
        // first, so a failing store write left `markdown_path` pointing at a
        // file that no longer existed and "Im Finder zeigen" stopped working.
        try writeProjection(record: record, segments: loaded.segments, title: title, to: target)
        try await store.updateTitle(title, titleIsAuto: false, markdownPath: target.path, for: record.id)
        removeStaleFile(currentURL, keeping: target)
        await reload()
    }

    // MARK: - Move

    /// Moves a note into `folder` (Inbox or a project folder). The file content
    /// is re-projected (title/date unchanged, so it is identical) at a fresh
    /// collision-free name in the destination; the old file is removed.
    func move(_ recording: RecordingStore.Recording, toFolder folder: String) async throws {
        let key = folder == Self.inboxFolder ? folder : Self.sanitizeFolderName(folder)
        guard !key.isEmpty else { throw NoteError.invalidFolderName }

        guard let loaded = try await store.meeting(id: recording.id) else { throw NoteError.notFound }
        let record = loaded.recording

        let destination = url(forFolder: key)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let currentURL = record.markdownPath.map { URL(fileURLWithPath: $0) }
        let title = record.title ?? "Meeting"
        let target = destination.appendingPathComponent(
            MarkdownProjector.uniqueFileName(title: title, date: record.startedAt, in: destination, excluding: currentURL)
        )

        // Same order as `rename`: the old file only goes once the store knows
        // about the new one.
        try writeProjection(record: record, segments: loaded.segments, title: title, to: target)
        try await store.updateLocation(folder: key, markdownPath: target.path, for: record.id)
        removeStaleFile(currentURL, keeping: target)
        await reload()
    }

    // MARK: - Faithful projection

    /// Directory a note currently lives in: its file's parent if the recorded
    /// path is usable, otherwise derived from the stored folder key. Keeps a
    /// rename in the same folder even if the recorded path is stale.
    private func currentDirectory(for record: RecordingStore.Recording) -> URL {
        if let path = record.markdownPath, !path.isEmpty {
            return URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        return url(forFolder: record.folder)
    }

    /// Rebuilds the whole `.md` from the stored record + segments (never from the
    /// on-disk file), so the projection stays faithful even if the file was
    /// hand-edited or deleted.
    private func writeProjection(
        record: RecordingStore.Recording,
        segments: [RecordingStore.Segment],
        title: String,
        to target: URL
    ) throws {
        // The event title comes out of SQLite like everything else. It used to
        // be passed as `nil` here, so every rename, move and notes-save silently
        // dropped the front-matter `event:` line from a file that had it.
        let note = MarkdownProjector.Note(
            title: title,
            date: record.startedAt,
            calendarEventTitle: record.calendarEventTitle,
            attendees: record.attendees,
            segments: segments.map { ($0.speaker, $0.text) },
            summary: record.summary,
            userNotes: record.userNotes
        )
        try MarkdownProjector.render(note).write(to: target, atomically: true, encoding: .utf8)
    }

    // MARK: - Eigene Notizen

    /// Saves the user's own notes for a note, then re-projects the .md so the
    /// verbatim "## Eigene Notizen" section appears immediately.
    func saveUserNotes(_ notes: String, for recording: RecordingStore.Recording) async throws {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        try await store.setUserNotes(trimmed.isEmpty ? nil : trimmed, for: recording.id)
        try await reproject(recording.id)
        await reload()
    }

    /// Re-summarizes including the user's notes (woven into the Zusammenfassung),
    /// stores the new summary, and re-projects. No transcript ⇒ no-op.
    func resummarizeWithNotes(_ recording: RecordingStore.Recording, providerID: String) async throws {
        guard let loaded = try await store.meeting(id: recording.id) else { throw NoteError.notFound }
        let record = loaded.recording
        guard !loaded.segments.isEmpty else { return }
        let transcript = loaded.segments
            .map { "\($0.speaker ?? "Unbekannt"): \($0.text)" }
            .joined(separator: "\n")
        let duration = (record.endedAt ?? record.startedAt).timeIntervalSince(record.startedAt)
        let context = MeetingContext(
            title: record.title, date: record.startedAt,
            durationSeconds: duration, userNotes: record.userNotes
        )
        let summary = try await SummarizationService.summarize(
            transcript: transcript, context: context, providerID: providerID
        )
        try await store.setSummary(summary.markdown, subtitle: summary.subtitle, for: record.id)
        await UsageRecorder.record(
            summary.usage, provider: summary.providerID,
            purpose: .summary, recordingID: record.id, store: store
        )
        try await reproject(record.id)
        await reload()
    }

    /// Rebuilds the note's .md from the stored record at its current path.
    private func reproject(_ id: String) async throws {
        guard let loaded = try await store.meeting(id: id) else { return }
        let record = loaded.recording
        let title = record.title ?? "Meeting"
        let target = record.markdownPath.map { URL(fileURLWithPath: $0) }
            ?? currentDirectory(for: record).appendingPathComponent(
                MarkdownProjector.uniqueFileName(title: title, date: record.startedAt, in: currentDirectory(for: record))
            )
        try writeProjection(record: record, segments: loaded.segments, title: title, to: target)
        if record.markdownPath == nil {
            try await store.updateLocation(folder: record.folder, markdownPath: target.path, for: id)
        }
    }

    /// Removes the previous file after a successful re-projection, unless it is
    /// the same path we just wrote. A missing old file is not an error.
    private func removeStaleFile(_ old: URL?, keeping target: URL) {
        guard let old, old.standardizedFileURL.path != target.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: old)
    }

    private static func sanitizeFolderName(_ name: String) -> String {
        name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum NoteError: LocalizedError {
        case emptyTitle
        case invalidFolderName
        case reservedFolderName
        case notFound

        var errorDescription: String? {
            switch self {
            case .emptyTitle: String(localized: "Der Titel darf nicht leer sein.")
            case .invalidFolderName: String(localized: "Ungültiger Ordnername.")
            case .reservedFolderName: String(localized: "„Inbox“ ist reserviert.")
            case .notFound: String(localized: "Notiz nicht gefunden.")
            }
        }
    }
}
