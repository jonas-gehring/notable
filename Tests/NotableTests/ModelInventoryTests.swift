import XCTest

/// All four states against a temporary directory — no real models, because a
/// test that needs a gigabyte of weights on disk is a test nobody runs.
final class ModelInventoryTests: XCTestCase {
    fileprivate var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    fileprivate func makeModel(_ directory: String, files: [String]) throws {
        let url = root.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files {
            try Data(repeating: 7, count: 128).write(to: url.appendingPathComponent(file))
        }
    }

    fileprivate let known = [
        ModelInventory.Known(directory: "asr", name: "ASR", requiredFiles: ["Encoder.mlmodelc", "Decoder.mlmodelc"]),
        ModelInventory.Known(directory: "vad", name: "VAD", requiredFiles: ["vad.mlmodelc"]),
    ]

    private func scan(inUse: Set<String> = ["asr"]) -> [ModelInventory.Entry] {
        ModelInventory.scan(root: root, known: known, inUse: inUse)
    }

    func testTheFourStates() throws {
        try makeModel("asr", files: ["Encoder.mlmodelc", "Decoder.mlmodelc"])
        try makeModel("vad", files: ["vad.mlmodelc"])
        try makeModel("asr-halb", files: ["Encoder.mlmodelc"])
        try makeModel("asr-coreml", files: ["Encoder.mlmodelc", "Decoder.mlmodelc"])

        let byName = Dictionary(uniqueKeysWithValues: scan().map { ($0.url.lastPathComponent, $0) })
        XCTAssertEqual(byName["asr"]?.state, .inUse)
        XCTAssertEqual(byName["vad"]?.state, .available, "Vollständig, aber gerade nicht gewählt")
        // A directory FluidAudio renamed between two versions: the new name is
        // in use, the old one is dead weight next to it.
        XCTAssertEqual(byName["asr-coreml"]?.state, .orphaned)
        XCTAssertEqual(byName["asr-halb"]?.state, .orphaned, "Unbekannter Name schlägt jede Dateiprüfung")
        XCTAssertGreaterThan(byName["asr"]?.bytes ?? 0, 0)
    }

    /// A known directory that lost a file is `incomplete`, and it says which —
    /// "es fehlt etwas" without saying what is a dead end.
    func testKnownModelMissingAFileIsIncompleteAndNamesIt() throws {
        try makeModel("asr", files: ["Encoder.mlmodelc"])
        let entry = try XCTUnwrap(scan().first)
        XCTAssertEqual(entry.state, .incomplete)
        XCTAssertEqual(entry.missing, ["Decoder.mlmodelc"])
        XCTAssertEqual(entry.name, "ASR", "Der Anzeigename bleibt der bekannte")
    }

    /// The whole point of the classification: what may be deleted, and what
    /// may never be.
    func testOnlyOrphanedAndIncompleteAreOfferedForRemoval() throws {
        try makeModel("asr", files: ["Encoder.mlmodelc"])          // incomplete
        try makeModel("vad", files: ["vad.mlmodelc"])              // available
        try makeModel("fremd", files: ["irgendwas"])               // orphaned
        let entries = scan()
        let plan = ModelInventory.removable(in: entries)

        XCTAssertEqual(Set(plan.entries.map(\.url.lastPathComponent)), ["asr", "fremd"])
        XCTAssertGreaterThan(plan.bytes, 0)
        XCTAssertFalse(plan.isEmpty)

        XCTAssertTrue(ModelInventory.remove(plan).isEmpty, "Löschen meldet keine Fehler")
        XCTAssertEqual(scan().map(\.url.lastPathComponent), ["vad"])
    }

    /// A model in use is never removable — not even when the list is stale and
    /// the directory looks unfamiliar for some other reason.
    func testAModelInUseIsNeverRemovable() throws {
        try makeModel("asr", files: ["Encoder.mlmodelc", "Decoder.mlmodelc"])
        try makeModel("vad", files: ["vad.mlmodelc"])
        let plan = ModelInventory.removable(in: scan(inUse: ["asr", "vad"]))
        XCTAssertTrue(plan.isEmpty)
    }

    func testMissingRootIsEmptyRatherThanAnError() {
        XCTAssertTrue(ModelInventory.scan(
            root: root.appendingPathComponent("gibtesnicht"), known: known, inUse: []
        ).isEmpty)
    }

    /// Parakeet v3 carries the meeting pipeline no matter what dictation runs
    /// on, so it is in use for every engine. Getting this wrong would offer the
    /// most important model on disk up for deletion.
    func testParakeetV3IsInUseForEveryEngine() {
        for engine in ASREngineID.allCases {
            let inUse = ModelInventory.inUseDirectories(engine: engine)
            XCTAssertTrue(inUse.contains("parakeet-tdt-0.6b-v3"), "\(engine.rawValue)")
            XCTAssertTrue(inUse.contains("speaker-diarization"))
            XCTAssertTrue(inUse.contains("silero-vad"))
        }
        XCTAssertTrue(ModelInventory.inUseDirectories(engine: .unifiedEnglish)
            .contains("parakeet-unified-en-0.6b"))
        XCTAssertFalse(ModelInventory.inUseDirectories(engine: .parakeetV3)
            .contains("parakeet-unified-en-0.6b"))
    }

    /// Whisper's weights must not land in the user's Documents folder, which is
    /// WhisperKit's own default.
    func testWhisperDownloadsIntoApplicationSupport() {
        let path = ModelInventory.whisperDownloadBase.path
        XCTAssertTrue(path.contains("Application Support/Notable/Models"), path)
        XCTAssertFalse(path.contains("/Documents/"), path)
        XCTAssertTrue(ModelInventory.whisperRoot.path.hasSuffix("models/argmaxinc/whisperkit-coreml"))
    }

    /// Whisper has no manifest, so it is never reported as incomplete — an
    /// unverifiable claim is worse than no claim.
    func testWhisperEntriesAreNeverIncomplete() throws {
        let whisper = root.appendingPathComponent("whisper", isDirectory: true)
        for directory in ["openai_whisper-base", "openai_whisper-erfunden"] {
            try FileManager.default.createDirectory(
                at: whisper.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let entries = ModelInventory.scanWhisper(root: whisper, inUse: ["openai_whisper-base"])
        let byDirectory = Dictionary(uniqueKeysWithValues: entries.map { ($0.url.lastPathComponent, $0) })
        XCTAssertEqual(byDirectory["openai_whisper-base"]?.state, .inUse)
        XCTAssertEqual(byDirectory["openai_whisper-base"]?.name, "Whisper base")
        XCTAssertEqual(byDirectory["openai_whisper-erfunden"]?.state, .orphaned)
        XCTAssertTrue(entries.allSatisfy { $0.state != .incomplete })
    }
}

// MARK: - Erneut laden

/// `retryLoad` deletes a broken model directory before reloading — otherwise
/// FluidAudio's presence check keeps answering "it's there" and the retry
/// button does nothing, forever.
extension ModelInventoryTests {
    /// Builds one of the real known models in the temporary root, optionally
    /// leaving a required file out.
    private func makeKnownModel(_ directory: String, complete: Bool) throws {
        let model = try XCTUnwrap(ModelInventory.knownModels.first { $0.directory == directory })
        let files = complete
            ? Array(model.requiredFiles)
            : Array(model.requiredFiles.sorted().dropLast())
        XCTAssertFalse(files.isEmpty || (!complete && files.count == model.requiredFiles.count))
        try makeModel(directory, files: files)
    }

    func testABrokenModelIsRemovedSoTheNextLoadFetchesItAgain() throws {
        try makeKnownModel("parakeet-tdt-0.6b-v3", complete: false)
        let removed = ModelInventory.discardIncomplete(for: .parakeetV3, root: root)
        XCTAssertEqual(removed.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("parakeet-tdt-0.6b-v3").path))
    }

    /// The important half: a working model must survive a retry untouched.
    func testACompleteModelSurvivesARetry() throws {
        try makeKnownModel("parakeet-tdt-0.6b-v3", complete: true)
        XCTAssertTrue(ModelInventory.discardIncomplete(for: .parakeetV3, root: root).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("parakeet-tdt-0.6b-v3").path))
    }

    /// Retrying one engine must not touch another engine's model.
    func testRetryingOneEngineLeavesTheOtherAlone() throws {
        try makeKnownModel("parakeet-unified-en-0.6b", complete: false)
        XCTAssertTrue(ModelInventory.discardIncomplete(for: .parakeetV3, root: root).isEmpty)
        XCTAssertEqual(ModelInventory.discardIncomplete(for: .unifiedEnglish, root: root).count, 1)
    }

    func testWhisperIsNeverDiscardedBecauseItCannotBeProvenBroken() {
        XCTAssertTrue(ModelInventory.discardIncomplete(for: .whisper, root: root).isEmpty)
    }
}

// MARK: - Was kein Modell ist

extension ModelInventoryTests {
    /// WhisperKit keeps a `.cache` folder next to its models. Listing it as a
    /// model — and then offering to delete it as orphaned — would be
    /// confidently wrong about something the library owns.
    func testHiddenDirectoriesAreNotModels() throws {
        try makeModel(".cache", files: ["irgendwas"])
        try makeModel("vad", files: ["vad.mlmodelc"])
        XCTAssertEqual(
            ModelInventory.scan(root: root, known: known, inUse: []).map(\.url.lastPathComponent),
            ["vad"]
        )
        XCTAssertTrue(ModelInventory.scanWhisper(root: root, inUse: [])
            .allSatisfy { $0.url.lastPathComponent != ".cache" })
    }
}
