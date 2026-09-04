import XCTest

/// Guards the one genuinely risky, side-effecting part of the auto-updater — the
/// detached swap script that replaces the running bundle — as a pure string, so a
/// regression (dropping the pid wait, the rollback, or the relaunch) is caught
/// without executing anything.
final class UpdateInstallerTests: XCTestCase {

    private var script: String { UpdateInstaller.swapScript }

    func testWaitsForTheAppToQuitBeforeSwapping() {
        // It must poll the pid ($1) and stop once the process is gone.
        XCTAssertTrue(script.contains(#"kill -0 "$pid""#),
                      "script must wait on the app's pid before touching the bundle")
        XCTAssertTrue(script.contains("break"))
    }

    func testMovesOldBundleAsideAndCopiesTheNewOne() {
        XCTAssertTrue(script.contains(#"mv "$dest" "$dest.old""#),
                      "the live bundle must be moved aside, not deleted outright")
        XCTAssertTrue(script.contains(#"ditto "$newapp" "$dest""#),
                      "the new app must be copied in with ditto (preserves the signature)")
    }

    func testRollsBackOnCopyFailure() {
        // On a failed ditto the previous bundle is restored from .old.
        XCTAssertTrue(script.contains(#"mv "$dest.old" "$dest""#),
                      "a failed copy must roll back to the previous bundle")
    }

    func testRelaunchesAtTheEnd() {
        XCTAssertTrue(script.contains(#"open "$dest""#),
                      "the updated app must be relaunched")
    }

    func testUsesPositionalArgsSoPathsWithSpacesAreSafe() {
        // Paths are passed as $2/$3, never interpolated, and always quoted.
        XCTAssertTrue(script.contains(#"newapp="$2""#))
        XCTAssertTrue(script.contains(#"dest="$3""#))
    }

    // MARK: - The guards, executed rather than grepped

    /// Runs the swap script for real in a temp directory. `pid` is what it waits
    /// on; the bundles are plain directories, which is all `mv`/`ditto` need.
    @discardableResult
    private func runScript(pid: Int32, stageApp: Bool = true) throws -> (dir: URL, script: URL, status: Int32) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swap-\(UUID().uuidString)", isDirectory: true)
        let dest = dir.appendingPathComponent("Notable.app", isDirectory: true)
        let staged = dir.appendingPathComponent("new/Notable.app", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try "alt".write(to: dest.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        if stageApp {
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try "neu".write(to: staged.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        }

        let script = dir.appendingPathComponent("swap.sh")
        try UpdateInstaller.swapScript.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(pid), staged.path, dest.path]
        // `open` at the end has nothing to open here; its noise is not the point.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return (dir, script, process.terminationStatus)
    }

    private func marker(_ dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent("Notable.app/marker"), encoding: .utf8)
    }

    /// The wait loop gives up after ~20 s. Falling through it used to swap a
    /// *running* bundle — the one case where doing nothing is obviously right.
    func testDoesNotSwapWhenTheAppIsStillRunningAfterTheWait() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        try sleeper.run()
        defer { sleeper.terminate() }

        // The loop is ~20 s of 0.2 s sleeps; this test pays that once.
        let result = try runScript(pid: sleeper.processIdentifier)
        defer { try? FileManager.default.removeItem(at: result.dir) }

        XCTAssertNotEqual(result.status, 0, "muss mit Fehler abbrechen statt zu tauschen")
        XCTAssertEqual(marker(result.dir), "alt", "das laufende Bundle bleibt unangetastet")
    }

    /// The happy path, end to end.
    func testSwapsTheBundleOnceTheAppIsGone() throws {
        let result = try runScript(pid: 999_999) // no such process
        defer { try? FileManager.default.removeItem(at: result.dir) }

        XCTAssertEqual(marker(result.dir), "neu")
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.dir.appendingPathComponent("Notable.app.old").path))
    }

    /// A failing copy must leave a working app behind. The unconditional
    /// `rm -rf "$dest"` in the error branch could delete it outright.
    func testRestoresThePreviousBundleWhenTheCopyFails() throws {
        let result = try runScript(pid: 999_999, stageApp: false) // ditto has nothing to copy
        defer { try? FileManager.default.removeItem(at: result.dir) }

        XCTAssertEqual(marker(result.dir), "alt", "nach fehlgeschlagenem Kopieren muss die alte App zurück sein")
    }

    /// The script wrote itself into the temp directory and never cleaned up.
    func testRemovesItselfAfterwards() throws {
        let result = try runScript(pid: 999_999)
        defer { try? FileManager.default.removeItem(at: result.dir) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: result.script.path))
    }

    // MARK: - Signature check

    func testParsesTheTeamIdentifierFromCodesignOutput() {
        let output = """
        Executable=/Applications/Notable.app/Contents/MacOS/Notable
        Identifier=de.jonasgehring.notable
        TeamIdentifier=ABCDE12345
        Sealed Resources version=2 rules=13 files=42
        """
        XCTAssertEqual(UpdateInstaller.parseTeamIdentifier(output), "ABCDE12345")
    }

    /// "not set" is what an ad-hoc signature reports. Treating it as a team name
    /// would make two unsigned bundles "match" and wave the update through.
    func testAdHocSignatureHasNoTeamIdentifier() {
        XCTAssertNil(UpdateInstaller.parseTeamIdentifier("Identifier=x\nTeamIdentifier=not set\n"))
        XCTAssertNil(UpdateInstaller.parseTeamIdentifier("Identifier=x\n"))
    }

    /// An unsigned staged bundle must be refused, not installed.
    func testRefusesAnUnsignedDownload() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify-\(UUID().uuidString)", isDirectory: true)
        let staged = dir.appendingPathComponent("Notable.app", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(
            try UpdateInstaller.verifySignature(staged: staged.path, matching: Bundle.main.bundlePath)
        )
    }

}
