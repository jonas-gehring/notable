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
}
