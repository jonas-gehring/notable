import Foundation

/// Whether a note's `.md` carries changes Notable did not write, before
/// Notable replaces it.
///
/// The Markdown file is a projection of SQLite, and every rename, move,
/// "Eigene Notizen" save and speaker rename rebuilds it from the store. That
/// is what keeps it faithful, and it is also what silently threw away anything
/// typed into the file by hand — and since Spec 27 the notes sit in iCloud
/// Drive, where opening one in Obsidian or a text editor is the obvious thing
/// to do. The edit was gone at the next rename, without a word.
///
/// **What "Notable wrote this" means here:** the file is byte for byte the
/// projection of the state *before* the change — the record as the operation
/// loaded it, rendered by the current `MarkdownProjector`. No hash is stored:
/// the comparison works for every note that already exists, needs no schema
/// change, and covers the files `MeetingController` writes as well as the ones
/// `NoteManager` writes. Its one blind spot is a change to the projector's
/// output: a note written by an older version then differs from its fresh
/// render, and its first touch keeps a copy it did not need. That errs the
/// right way — a spare file is visible and deletable, a lost edit is neither.
enum HandEditGuard {
    enum Decision: Equatable, Sendable {
        /// Nothing on disk would be lost by writing.
        case overwrite
        /// The file differs from everything Notable could have put there:
        /// keep it under ``copyName(for:exists:)`` before writing.
        case keepCopy
    }

    /// `onDisk` is the file as read (nil: there is no file — nothing to keep;
    /// the caller treats a file that exists but cannot be read as edited). It
    /// is compared as bytes, because that is what
    /// `String.write(…, encoding: .utf8)` produced, and a text comparison would
    /// let an editor's normalisation through as "unchanged".
    static func decide(onDisk: Data?, lastWritten: String, replacement: String) -> Decision {
        guard let onDisk else { return .overwrite }
        // Already what is about to be written: writing loses nothing.
        if onDisk == Data(replacement.utf8) { return .overwrite }
        if onDisk == Data(lastWritten.utf8) { return .overwrite }
        return .keepCopy
    }

    /// The word the copy is marked with. A file name, so it stays German like
    /// every note file name; it is never shown inside Notable.
    static let editedMark = "bearbeitet"

    /// `2026-10-01 09.30 Titel.md` → `2026-10-01 09.30 Titel (bearbeitet).md`,
    /// then `(bearbeitet 2)`, `(bearbeitet 3)`, … — an earlier copy is never
    /// overwritten, because it holds an earlier edit.
    static func copyName(for fileName: String, exists: (String) -> Bool) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        func candidate(_ counter: Int) -> String {
            let mark = counter == 1 ? "(\(editedMark))" : "(\(editedMark) \(counter))"
            return ext.isEmpty ? "\(stem) \(mark)" : "\(stem) \(mark).\(ext)"
        }
        var counter = 1
        while exists(candidate(counter)) { counter += 1 }
        return candidate(counter)
    }
}
