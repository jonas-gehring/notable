import Foundation
import os

/// Moves the models out of `Application Support/FluidAudio` and into
/// `Application Support/Notable`, once.
///
/// The old location was never a decision. FluidAudio's
/// `MLModelConfigurationUtils.defaultModelsDirectory()` picks it, and Notable
/// simply never passed a destination — although all four load calls take one.
/// So the largest thing the app writes to disk, more than a gigabyte, sat in a
/// folder named after a library the user has never heard of, and since Whisper
/// moved to `Notable/Models` it sat in *two* folders. That is the worst of the
/// three possible arrangements.
///
/// **Move, never re-download.** A rename inside the same volume is instant, and
/// Application Support is one volume; asking someone to fetch 461 MB again
/// because a folder was renamed would be an insult dressed up as a migration.
///
/// **Nothing is deleted, ever.** Whatever cannot be moved stays exactly where
/// it is, and `ModelInventory` keeps scanning the old root, so a leftover shows
/// up in the storage pane as orphaned and removable rather than becoming an
/// invisible gigabyte — the precise failure mode this whole area exists to fix.
enum ModelStorageMigration {
    private static let log = Logger(subsystem: "de.jonasgehring.notable", category: "model-migration")

    struct Outcome: Sendable, Equatable {
        var moved: [String] = []
        /// Something of that name was already at the destination. Left alone:
        /// two directories with one name are not provably the same bytes, and
        /// guessing wrong here costs a working model.
        var skipped: [String] = []
        var failures: [String] = []

        var didAnything: Bool { !moved.isEmpty || !skipped.isEmpty || !failures.isEmpty }
    }

    /// Runs the move if the old root still exists. Cheap enough for launch:
    /// with nothing to do it is a single `fileExists`.
    @discardableResult
    static func run(
        from legacy: URL = ModelInventory.legacyRoot,
        to root: URL = ModelInventory.modelsRoot,
        fileManager: FileManager = .default
    ) -> Outcome {
        var outcome = Outcome()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: legacy, includingPropertiesForKeys: nil
        ) else { return outcome }

        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        for entry in entries {
            let name = entry.lastPathComponent
            let destination = root.appendingPathComponent(name)
            guard !fileManager.fileExists(atPath: destination.path) else {
                outcome.skipped.append(name)
                continue
            }
            do {
                try fileManager.moveItem(at: entry, to: destination)
                outcome.moved.append(name)
            } catch {
                outcome.failures.append("\(name): \(error.localizedDescription)")
            }
        }

        removeIfEmpty(legacy, fileManager: fileManager)
        // `FluidAudio/` itself, once `Models/` inside it is gone. An empty
        // directory is not harmful, but leaving one named after a library the
        // user never chose would keep the original confusion alive.
        removeIfEmpty(legacy.deletingLastPathComponent(), fileManager: fileManager)

        if outcome.didAnything {
            log.info("""
            Modelle verschoben: \(outcome.moved.count, privacy: .public) bewegt, \
            \(outcome.skipped.count, privacy: .public) übersprungen, \
            \(outcome.failures.count, privacy: .public) fehlgeschlagen
            """)
        }
        return outcome
    }

    private static func removeIfEmpty(_ url: URL, fileManager: FileManager) {
        guard let remaining = try? fileManager.contentsOfDirectory(atPath: url.path),
              remaining.isEmpty else { return }
        try? fileManager.removeItem(at: url)
    }
}
