import XCTest

/// Pure tests — no network. Exercises version parsing/comparison, tag stripping,
/// and asset selection from a sample GitHub `releases/latest` payload.
final class UpdateCheckerTests: XCTestCase {

    // MARK: - Tag parsing / stripping

    func testStripsLeadingV() {
        XCTAssertEqual(SemanticVersion("v1.2.3"), SemanticVersion("1.2.3"))
        XCTAssertEqual(SemanticVersion("V0.9.0")?.description, "0.9.0")
    }

    func testMissingComponentsDefaultToZero() {
        XCTAssertEqual(SemanticVersion("1"), SemanticVersion("1.0.0"))
        XCTAssertEqual(SemanticVersion("2.5"), SemanticVersion("2.5.0"))
    }

    func testRejectsGarbage() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("v"))
        XCTAssertNil(SemanticVersion("abc"))
        XCTAssertNil(SemanticVersion("1.x.0"))
    }

    func testBuildMetadataIgnored() {
        XCTAssertEqual(SemanticVersion("1.2.3+build.99"), SemanticVersion("1.2.3"))
    }

    // MARK: - Comparison

    func testNumericOrdering() {
        XCTAssertLessThan(SemanticVersion("0.9.0")!, SemanticVersion("0.10.0")!)
        XCTAssertLessThan(SemanticVersion("1.0.0")!, SemanticVersion("1.0.1")!)
        XCTAssertLessThan(SemanticVersion("1.9.9")!, SemanticVersion("2.0.0")!)
        XCTAssertGreaterThan(SemanticVersion("2.0.0")!, SemanticVersion("1.99.99")!)
    }

    func testEquality() {
        XCTAssertEqual(SemanticVersion("1.2.3")!, SemanticVersion("1.2.3")!)
        XCTAssertFalse(SemanticVersion("1.2.3")! < SemanticVersion("1.2.3")!)
    }

    func testPrereleaseRanksBelowRelease() {
        XCTAssertLessThan(SemanticVersion("1.0.0-beta")!, SemanticVersion("1.0.0")!)
        XCTAssertLessThan(SemanticVersion("1.0.0-alpha")!, SemanticVersion("1.0.0-beta")!)
        XCTAssertLessThan(SemanticVersion("1.0.0-1")!, SemanticVersion("1.0.0-2")!)
    }

    // MARK: - Asset selection + update decision

    private func sampleJSON(tag: String, withZip: Bool = true) -> Data {
        let assets: String = withZip
            ? """
              [
                { "name": "notes.txt", "browser_download_url": "https://example.com/notes.txt" },
                { "name": "Notable.zip", "browser_download_url": "https://example.com/Notable.zip" }
              ]
              """
            : """
              [ { "name": "notes.txt", "browser_download_url": "https://example.com/notes.txt" } ]
              """
        return """
        {
          "tag_name": "\(tag)",
          "name": "Release \(tag)",
          "body": "What's new in \(tag).",
          "html_url": "https://github.com/jonas-gehring/notable/releases/tag/\(tag)",
          "assets": \(assets)
        }
        """.data(using: .utf8)!
    }

    func testSelectsFirstZipAsset() throws {
        let info = try UpdateResolver.updateInfo(fromJSON: sampleJSON(tag: "v1.0.0"), current: SemanticVersion("0.9.0")!)
        XCTAssertEqual(info?.downloadURL.absoluteString, "https://example.com/Notable.zip")
        XCTAssertEqual(info?.versionString, "v1.0.0")
        XCTAssertEqual(info?.notes, "What's new in v1.0.0.")
        XCTAssertEqual(info?.releaseURL.absoluteString, "https://github.com/jonas-gehring/notable/releases/tag/v1.0.0")
    }

    func testNoUpdateWhenNotNewer() throws {
        let same = try UpdateResolver.updateInfo(fromJSON: sampleJSON(tag: "v0.9.0"), current: SemanticVersion("0.9.0")!)
        XCTAssertNil(same)
        let older = try UpdateResolver.updateInfo(fromJSON: sampleJSON(tag: "v0.8.0"), current: SemanticVersion("0.9.0")!)
        XCTAssertNil(older)
    }

    func testUpdateWhenNewer() throws {
        let info = try UpdateResolver.updateInfo(fromJSON: sampleJSON(tag: "v1.2.0"), current: SemanticVersion("0.9.0")!)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.version, SemanticVersion("1.2.0"))
    }

    func testFallsBackToReleasePageWhenNoZip() throws {
        let info = try UpdateResolver.updateInfo(
            fromJSON: sampleJSON(tag: "v1.0.0", withZip: false),
            current: SemanticVersion("0.9.0")!
        )
        XCTAssertEqual(info?.downloadURL.absoluteString, "https://github.com/jonas-gehring/notable/releases/tag/v1.0.0")
    }
}
