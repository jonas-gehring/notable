import XCTest

/// A migration that moves a gigabyte has exactly one job: lose nothing. These
/// tests are about the failure paths, not the happy one.
final class ModelStorageMigrationTests: XCTestCase {
    private var base: URL!
    private var legacy: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-migration-\(UUID().uuidString)", isDirectory: true)
        legacy = base.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        root = base.appendingPathComponent("Notable/Models", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeModel(in parent: URL, _ name: String, file: String = "Encoder.mlmodelc") throws {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 64).write(to: url.appendingPathComponent(file))
    }

    private func migrate() -> ModelStorageMigration.Outcome {
        ModelStorageMigration.run(from: legacy, to: root)
    }

    private func names(in url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    func testEverythingMovesIncludingTheOrphans() throws {
        try makeModel(in: legacy, "parakeet-tdt-0.6b-v3")
        try makeModel(in: legacy, "silero-vad")
        // The dead directories move too. Leaving them behind would hide them
        // from the storage pane, which is the problem, not the solution.
        try makeModel(in: legacy, "silero-vad-coreml")

        let outcome = migrate()
        XCTAssertEqual(outcome.moved.sorted(), ["parakeet-tdt-0.6b-v3", "silero-vad", "silero-vad-coreml"])
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(names(in: root), ["parakeet-tdt-0.6b-v3", "silero-vad", "silero-vad-coreml"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("silero-vad/Encoder.mlmodelc").path),
            "der Inhalt, nicht nur der Ordner")
    }

    /// The empty shell must go, or the folder named after a library the user
    /// never chose stays around and keeps the confusion alive.
    func testTheOldRootDisappearsWhenItIsEmpty() throws {
        try makeModel(in: legacy, "silero-vad")
        _ = migrate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: base.appendingPathComponent("FluidAudio").path))
    }

    /// Two directories with one name are not provably the same bytes. Guessing
    /// wrong costs a working model, so nothing is overwritten and nothing is
    /// deleted — and the leftover stays where `ModelInventory` can still see it.
    func testACollisionLeavesBothSidesAlone() throws {
        try makeModel(in: legacy, "silero-vad", file: "alt.mlmodelc")
        try makeModel(in: root, "silero-vad", file: "neu.mlmodelc")

        let outcome = migrate()
        XCTAssertEqual(outcome.skipped, ["silero-vad"])
        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertEqual(names(in: root.appendingPathComponent("silero-vad")), ["neu.mlmodelc"])
        XCTAssertEqual(names(in: legacy.appendingPathComponent("silero-vad")), ["alt.mlmodelc"],
                       "das Zurückgelassene wird nicht gelöscht")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path),
                      "und der alte Ordner bleibt, damit die Belegungs-Seite ihn zeigt")
    }

    func testNothingToDoIsNotAnError() {
        let outcome = migrate()
        XCTAssertFalse(outcome.didAnything)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                       "ohne Bestand wird auch kein Zielordner angelegt")
    }

    /// Whatever is left in the old root has to stay visible, or the migration
    /// turns a gigabyte into an invisible one — the exact failure Spec 20 is about.
    func testLeftoversAreReportedAsOrphaned() throws {
        try makeModel(in: legacy, "silero-vad", file: "alt.mlmodelc")
        try makeModel(in: root, "silero-vad", file: "neu.mlmodelc")
        _ = migrate()

        let leftovers = ModelInventory.scan(root: legacy, known: [], inUse: [])
        XCTAssertEqual(leftovers.map(\.state), [.orphaned])
        XCTAssertTrue(ModelInventory.removable(in: leftovers).entries.count == 1)
    }

    /// The three levels FluidAudio's four entry points want, pinned — getting
    /// one wrong puts a model one directory off and re-downloads it.
    func testTheThreeDirectoryLevels() {
        XCTAssertEqual(ModelInventory.modelsRoot.lastPathComponent, "Models")
        XCTAssertEqual(ModelInventory.modelsRoot.deletingLastPathComponent(), ModelInventory.applicationRoot)
        XCTAssertEqual(ModelInventory.applicationRoot.lastPathComponent, "Notable")
        XCTAssertEqual(
            ModelInventory.directory(.parakeetV3),
            ModelInventory.modelsRoot.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
        )
        XCTAssertFalse(ModelInventory.modelsRoot.path.contains("FluidAudio"))
    }
}
