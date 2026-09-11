import Foundation

// The pure rules behind the notes folder (Spec 27): where a new setup puts it,
// how an existing one keeps its place, whether it syncs, how its path reads,
// when Notable may put its mark on it, and how stored paths follow a move.
// `NotesFolderManager` does the file work around them.

enum NotesFolderDefault {
    /// iCloud Drive's root, as a non-sandboxed app sees it. Measured: Notable
    /// writes there without any entitlement. `url(forUbiquityContainerIdentifier:)`
    /// is no help — it needs an iCloud entitlement and returns the app's own
    /// container, not iCloud Drive.
    static func iCloudDriveRoot(home: URL) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// Where a **new** setup puts its notes: iCloud Drive when it is there,
    /// the documents folder otherwise (the old default).
    static func resolve(iCloudDriveRoot: URL?, documents: URL) -> URL {
        (iCloudDriveRoot ?? documents).appendingPathComponent("Notable", isDirectory: true)
    }

    enum Resolution: Equatable {
        /// A folder was chosen before — nothing changes.
        case stored(URL)
        /// Never chosen, but notes already lie in the old default: written down,
        /// so new notes keep landing next to the old ones.
        case pinLegacy(URL)
        /// Nothing there yet: the new default, written down as well, so the
        /// folder does not wander if iCloud Drive is switched on or off later.
        case fresh(URL)

        var url: URL {
            switch self {
            case .stored(let url), .pinLegacy(let url), .fresh(let url): url
            }
        }
    }

    /// The first launch of a version with the new default. **Nothing that is
    /// already set up moves** — silently relocating notes, or worse, writing
    /// new ones somewhere other than the old ones, is not an option.
    static func initialFolder(storedPath: String?, legacy: URL, legacyExists: Bool, fresh: URL) -> Resolution {
        if let storedPath, !storedPath.isEmpty { return .stored(URL(fileURLWithPath: storedPath, isDirectory: true)) }
        if legacyExists { return .pinLegacy(legacy) }
        return .fresh(fresh)
    }
}

/// Whether the notes reach other devices — the line under the folder in Settings.
enum NotesFolderSync: Equatable {
    case iCloud
    case local
    /// The folder lies inside iCloud Drive, and iCloud Drive is gone. It must
    /// **not** be recreated: `createDirectory(withIntermediateDirectories:)`
    /// would quietly rebuild `Mobile Documents/com~apple~CloudDocs/…` as a
    /// plain local folder that never syncs.
    case iCloudDriveOff

    /// `isUbiquitous` covers the other way into iCloud: "Schreibtisch &
    /// Dokumente" synchronises `~/Documents` without it living under
    /// `Mobile Documents` (measured on this Mac: `isUbiquitousItem` is true).
    static func classify(folder: String, iCloudRoot: String, iCloudRootExists: Bool, isUbiquitous: Bool) -> NotesFolderSync {
        if isInside(folder, iCloudRoot) { return iCloudRootExists ? .iCloud : .iCloudDriveOff }
        return isUbiquitous ? .iCloud : .local
    }

    static func isInside(_ path: String, _ root: String) -> Bool {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        return path == base || path.hasPrefix(base + "/")
    }
}

enum NotesFolderDisplay {
    /// "iCloud Drive › Codus › Meetings" instead of
    /// `/Users/…/Library/Mobile Documents/com~apple~CloudDocs/Codus/Meetings`.
    ///
    /// `display` are `FileManager.componentsToDisplay` of the folder, `anchor`
    /// those of the root it reads relative to — iCloud Drive (its name shown)
    /// or the home folder (its name dropped). Measured: for iCloud Drive the
    /// components run "… › Mobile Documents › iCloud Drive › Codus", so cutting
    /// at the anchor is what removes the plumbing. Outside both, the whole
    /// display path.
    static func readable(display: [String], anchor: [String], showAnchor: Bool) -> String {
        guard !anchor.isEmpty, display.count > anchor.count, Array(display.prefix(anchor.count)) == anchor else {
            return display.joined(separator: " › ")
        }
        return display.dropFirst(showAnchor ? anchor.count - 1 : anchor.count).joined(separator: " › ")
    }
}

/// When Notable puts its mark on the notes folder, and when it takes it back.
///
/// The marker (`notesFolderIconPath`) is the only way to know whose icon a
/// folder carries: Finder stores every custom icon the same way, as a hidden
/// `Icon\r` file. So an icon Notable did not set is **never** overwritten —
/// someone, or Finder's "Ordner anpassen", designed it.
enum FolderIconRule {
    enum Action: Equatable {
        case set(String)
        case remove(String)
    }

    static func actions(enabled: Bool, folder: String, marker: String?, folderHasIcon: Bool) -> [Action] {
        var actions: [Action] = []
        let marker = marker.flatMap { $0.isEmpty ? nil : $0 }
        // Notable's mark on a folder that is no longer the notes folder.
        if let marker, marker != folder { actions.append(.remove(marker)) }
        guard enabled else {
            if marker == folder, folderHasIcon { actions.append(.remove(folder)) }
            return actions
        }
        if folderHasIcon { return actions } // ours already, or someone else's
        actions.append(.set(folder))
        return actions
    }

    /// The marker after the actions ran: the folder Notable's icon now sits on.
    static func marker(after actions: [Action], previous: String?) -> String? {
        var marker = previous.flatMap { $0.isEmpty ? nil : $0 }
        for action in actions {
            switch action {
            case .set(let path): marker = path
            case .remove(let path) where path == marker: marker = nil
            case .remove: break
            }
        }
        return marker
    }
}

/// Stufe 2 of Spec 27: moving the whole notes folder into iCloud Drive.
enum NotesRelocation {
    /// The stored path of a note that lived under `oldRoot`, now under
    /// `newRoot`; `nil` for anything outside it (left alone).
    static func rewrite(_ path: String, from oldRoot: String, to newRoot: String) -> String? {
        let old = oldRoot.hasSuffix("/") ? String(oldRoot.dropLast()) : oldRoot
        let new = newRoot.hasSuffix("/") ? String(newRoot.dropLast()) : newRoot
        guard path.hasPrefix(old + "/") else { return nil }
        return new + path.dropFirst(old.count)
    }

    /// "Notable", else "Notable 2", … — never into a folder that exists, which
    /// would merge two sets of notes into one.
    static func targetName(base: String = "Notable", existing: Set<String>) -> String {
        guard existing.contains(base) else { return base }
        var number = 2
        while existing.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}
