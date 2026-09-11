import AppKit
import Foundation
import SwiftUI

/// The folder for Markdown notes — the product surface. Not sandboxed, so a
/// plain path in UserDefaults is sufficient.
///
/// Spec 27: a new setup puts it in iCloud Drive while an existing one keeps its
/// place (`NotesFolderDefault`), it carries Notable's mark in Finder
/// (`FolderIconRule`), a folder that cannot be reached is **said** instead of
/// `try?`-ed away, and a folder that stays on this Mac can be moved into iCloud
/// Drive with its stored paths following (`NotesRelocation`).
@MainActor
final class NotesFolderManager: ObservableObject {
    static let defaultsKey = "notesFolderPath"

    @Published private(set) var folderURL: URL
    /// Why the folder could not be created or reached — the menu and Settings
    /// show it. `nil` while all is well.
    @Published private(set) var lastError: String?

    private let fileManager = FileManager.default

    init() {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let legacy = documents.appendingPathComponent("Notable", isDirectory: true)
        let resolution = NotesFolderDefault.initialFolder(
            storedPath: UserDefaults.standard.string(forKey: Self.defaultsKey),
            legacy: legacy,
            legacyExists: fm.fileExists(atPath: legacy.path),
            fresh: NotesFolderDefault.resolve(iCloudDriveRoot: Self.usableICloudDriveRoot(), documents: documents)
        )
        folderURL = resolution.url
        // Written down on the first launch of this version, whichever way it
        // went, so the folder never wanders with iCloud Drive's state later.
        if case .stored = resolution {} else {
            UserDefaults.standard.set(resolution.url.path, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Where it is

    static var iCloudDriveRoot: URL {
        NotesFolderDefault.iCloudDriveRoot(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    private static func usableICloudDriveRoot() -> URL? {
        let root = iCloudDriveRoot
        return FileManager.default.isWritableFile(atPath: root.path) ? root : nil
    }

    var sync: NotesFolderSync {
        let ubiquitous = (try? folderURL.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
        return NotesFolderSync.classify(
            folder: folderURL.path,
            iCloudRoot: Self.iCloudDriveRoot.path,
            iCloudRootExists: fileManager.fileExists(atPath: Self.iCloudDriveRoot.path),
            isUbiquitous: ubiquitous
        )
    }

    var exists: Bool { fileManager.fileExists(atPath: folderURL.path) }

    /// "iCloud Drive › Codus › Meetings", in the names Finder shows. A folder
    /// that does not exist yet reads through its nearest existing parent.
    var readablePath: String {
        var existing = folderURL
        var tail: [String] = []
        var display = fileManager.componentsToDisplay(forPath: existing.path) ?? []
        while display.isEmpty, existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
            display = fileManager.componentsToDisplay(forPath: existing.path) ?? []
        }
        guard !display.isEmpty else { return folderURL.path }
        let inICloud = NotesFolderSync.isInside(folderURL.path, Self.iCloudDriveRoot.path)
        let anchorPath = inICloud ? Self.iCloudDriveRoot.path : fileManager.homeDirectoryForCurrentUser.path
        let anchor = fileManager.componentsToDisplay(forPath: anchorPath) ?? []
        let readable = NotesFolderDisplay.readable(display: display + tail, anchor: anchor, showAnchor: inICloud)
        return readable.isEmpty ? folderURL.path : readable
    }

    /// The folder's icon as Finder draws it — Notable's mark included.
    var icon: NSImage {
        exists ? NSWorkspace.shared.icon(forFile: folderURL.path) : NSWorkspace.shared.icon(for: .folder)
    }

    // MARK: - Reaching it

    enum FolderError: LocalizedError {
        case iCloudDriveOff

        var errorDescription: String? {
            switch self {
            case .iCloudDriveOff: String(localized: "iCloud Drive ist aus — Notizen-Ordner nicht erreichbar.")
            }
        }
    }

    /// Creates the folder, puts Notable's mark on it, and says so when it
    /// cannot. All three callers used to `try?` this, so a folder that could not
    /// be created only ever surfaced as a note that failed to write.
    func ensureExists() throws {
        do {
            // Never recreate a folder whose iCloud Drive is gone: that would
            // rebuild `Mobile Documents/…` as a local folder that never syncs.
            if sync == .iCloudDriveOff { throw FolderError.iCloudDriveOff }
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        applyIcon()
    }

    /// At launch: report an unreachable folder and restore a lost icon, without
    /// creating anything — on a fresh install that is the onboarding's job, so a
    /// macOS access prompt appears there, in context.
    func refreshStatus() {
        if exists {
            lastError = nil
            applyIcon()
        } else if sync == .iCloudDriveOff {
            lastError = FolderError.iCloudDriveOff.errorDescription
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = exists ? folderURL : folderURL.deletingLastPathComponent()
        panel.prompt = String(localized: "Ordner wählen")
        panel.message = String(localized: "Ordner für Meeting-Notizen (Markdown)")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
    }

    private func setFolder(_ url: URL) {
        folderURL = url
        UserDefaults.standard.set(url.path, forKey: Self.defaultsKey)
        lastError = nil
        applyIcon() // also takes Notable's mark off the previous folder
    }

    // MARK: - Icon

    /// Sets, keeps or removes Notable's mark per `FolderIconRule` — and never
    /// touches an icon Notable did not set.
    func applyIcon() {
        let markerKey = DefaultsKey.notesFolderIconPath.key
        let marker = UserDefaults.standard.string(forKey: markerKey)
        let actions = FolderIconRule.actions(
            enabled: DefaultsKey.notesFolderIcon.value(),
            folder: folderURL.path,
            marker: marker,
            folderHasIcon: FolderIcon.hasCustomIcon(folderURL)
        )
        var done: [FolderIconRule.Action] = []
        for action in actions {
            switch action {
            case .set(let path):
                if FolderIcon.set(on: URL(fileURLWithPath: path, isDirectory: true)) { done.append(action) }
            case .remove(let path):
                FolderIcon.remove(from: URL(fileURLWithPath: path, isDirectory: true))
                done.append(action)
            }
        }
        UserDefaults.standard.set(FolderIconRule.marker(after: done, previous: marker) ?? "", forKey: markerKey)
    }

    // MARK: - Moving into iCloud Drive (Stufe 2)

    struct RelocationPlan: Equatable {
        let noteCount: Int
        let folderCount: Int
        let target: URL
    }

    /// Offered for a folder that exists, stays on this Mac, while iCloud Drive
    /// is there to take it.
    var canMoveToICloudDrive: Bool {
        exists && sync == .local && fileManager.isWritableFile(atPath: Self.iCloudDriveRoot.path)
    }

    /// What a move would do — shown before it happens, like the cleanup plan.
    func relocationPlan() -> RelocationPlan? {
        guard canMoveToICloudDrive else { return nil }
        let root = Self.iCloudDriveRoot
        let existing = Set((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [])
        let target = root.appendingPathComponent(NotesRelocation.targetName(existing: existing), isDirectory: true)
        var notes = 0
        var folders = 0
        let entries = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles])
        while let url = entries?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                folders += 1
            } else if url.pathExtension == "md" {
                notes += 1
            }
        }
        return RelocationPlan(noteCount: notes, folderCount: folders, target: target)
    }

    /// Moves the whole folder — one rename, iCloud Drive lives on the same
    /// volume — and rewrites every stored `markdown_path` under it in one
    /// transaction. Without the second half every note's "Im Finder zeigen"
    /// and every later rename would point at nothing. A failing database write
    /// moves the folder back.
    func relocate(_ plan: RelocationPlan, store: RecordingStore = .shared) async throws {
        let source = folderURL
        try fileManager.moveItem(at: source, to: plan.target)
        do {
            try await store.relocateMarkdownPaths(from: source.path, to: plan.target.path)
        } catch {
            try? fileManager.moveItem(at: plan.target, to: source)
            throw error
        }
        // The icon travelled inside the folder; its marker has to follow it.
        let markerKey = DefaultsKey.notesFolderIconPath.key
        if UserDefaults.standard.string(forKey: markerKey) == source.path {
            UserDefaults.standard.set(plan.target.path, forKey: markerKey)
        }
        setFolder(plan.target)
    }
}

extension NotesFolderSync {
    var label: String {
        switch self {
        case .iCloud: String(localized: "Wird über iCloud synchronisiert")
        case .local: String(localized: "Nur auf diesem Mac")
        case .iCloudDriveOff: String(localized: "iCloud Drive ist aus — Notizen-Ordner nicht erreichbar.")
        }
    }
}
