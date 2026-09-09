import XCTest

/// The number the app never used to say out loud, and the rule for when it
/// does. Four items, one total, one threshold.
final class StorageFootprintTests: XCTestCase {
    func testTotalIsTheSumOfAllFourItems() {
        var footprint = StorageFootprint()
        footprint.meetingAudio = .init(bytes: 4_000, count: 16)
        footprint.failedRecordings = .init(bytes: 300, count: 6)
        footprint.models = .init(bytes: 1_100, count: 7)
        footprint.database = .init(bytes: 50, count: nil)
        XCTAssertEqual(footprint.total, 5_450)
    }

    /// The line in the menu appears above five gigabytes and not below it: a
    /// permanent size line is noise, and this is meant to be read once.
    func testMentionOnlyAboveTheThreshold() {
        var footprint = StorageFootprint()
        footprint.meetingAudio = .init(bytes: StorageFootprint.menuThreshold - 1, count: 1)
        XCTAssertFalse(footprint.deservesMention)

        footprint.database = .init(bytes: 1, count: nil)
        XCTAssertTrue(footprint.deservesMention, "Genau auf der Schwelle zählt als erreicht")
    }

    func testEmptyInstallationReportsNothing() {
        let footprint = StorageFootprint()
        XCTAssertEqual(footprint.total, 0)
        XCTAssertFalse(footprint.deservesMention)
    }

    /// The models are the largest item and the one that was missing. The byte
    /// figure is the *directory*, not the sum of the classified rows —
    /// WhisperKit keeps tokenizers and a cache beside its model folders, and a
    /// total that quietly omits them would be wrong against `du`.
    func testModelCountComesFromTheInventoryAndBytesFromTheDisk() {
        let entries = [
            ModelInventory.Entry(name: "A", url: URL(fileURLWithPath: "/tmp/a"), bytes: 461, state: .inUse, missing: []),
            ModelInventory.Entry(name: "B", url: URL(fileURLWithPath: "/tmp/b"), bytes: 581, state: .available, missing: []),
        ]
        let footprint = StorageFootprint.measure(modelEntries: entries)
        XCTAssertEqual(footprint.models.count, 2)
        XCTAssertNotEqual(footprint.models.bytes, 1_042,
                          "die Zeilen sind die Aufstellung, nicht die Messung")
    }
}
