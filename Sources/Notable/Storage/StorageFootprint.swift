import Foundation

/// Everything Notable has put on the disk, in one place.
///
/// Measured on the productive installation on 2026-09-07: 3,9 GB meeting audio,
/// 80 MB failed recordings, 1,1 GB models — 5,1 GB, of which the storage pane
/// named two numbers and never mentioned the models at all. The app was the
/// last place you could find out what the app was using.
///
/// Nothing here deletes anything. Retention stays opt-in for the reason it
/// always did; this type only makes sure the decision is one you can actually
/// take, because you know the number.
struct StorageFootprint: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        var bytes: Int64 = 0
        /// Sessions, models — whatever the item counts. `nil` where counting
        /// makes no sense (the database is one file).
        var count: Int?
    }

    var meetingAudio = Item()
    var failedRecordings = Item()
    var models = Item()
    var database = Item()

    var total: Int64 {
        meetingAudio.bytes + failedRecordings.bytes + models.bytes + database.bytes
    }

    /// Above this the menu says so. A constant, not a setting: "ab wann darfst
    /// du mir sagen, dass du 5 GB belegst" is exactly the kind of question
    /// nobody wants to answer, and a permanent size line in the menu is noise.
    static let menuThreshold: Int64 = 5 * 1024 * 1024 * 1024

    var deservesMention: Bool { total >= Self.menuThreshold }

    /// Walks four directories. Belongs on a background task — the archive alone
    /// can be thousands of files.
    static func measure(
        modelEntries: [ModelInventory.Entry],
        fileManager: FileManager = .default
    ) -> StorageFootprint {
        let archive = SpoolInventory.sessions(in: SpoolStore.archiveURL, fileManager: fileManager)
        let failed = SpoolInventory.sessions(in: SpoolStore.failedURL, fileManager: fileManager)
        var footprint = StorageFootprint()
        footprint.meetingAudio = Item(bytes: archive.reduce(0) { $0 + $1.byteSize }, count: archive.count)
        footprint.failedRecordings = Item(bytes: failed.reduce(0) { $0 + $1.byteSize }, count: failed.count)
        // The *directories*, not the sum of the classified rows. WhisperKit
        // keeps tokenizers and a cache beside its model folders; adding up the
        // rows would quietly under-report by whatever the library keeps that
        // Notable does not classify. The number here has to match `du`.
        footprint.models = Item(
            bytes: [ModelInventory.modelsRoot, ModelInventory.legacyRoot]
                .reduce(0) { $0 + SpoolInventory.size(of: $1, fileManager: fileManager) },
            count: modelEntries.count
        )
        footprint.database = Item(bytes: databaseBytes(fileManager: fileManager), count: nil)
        return footprint
    }

    /// The database is three files: SQLite in WAL mode keeps a write-ahead log
    /// and a shared-memory index next to it, and the log is regularly the
    /// larger of the two.
    private static func databaseBytes(fileManager: FileManager) -> Int64 {
        let base = RecordingStore.sharedDatabaseURL
        return ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let url = URL(fileURLWithPath: base.path + suffix)
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            return total + Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
    }
}
