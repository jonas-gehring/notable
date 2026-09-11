import XCTest

/// Spec 27: where the notes folder goes, and the rules that keep it where the
/// notes already are.
final class NotesFolderRulesTests: XCTestCase {
    private let documents = URL(fileURLWithPath: "/Users/u/Documents", isDirectory: true)
    private let iCloud = URL(fileURLWithPath: "/Users/u/Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)

    // MARK: - Default and migration: nothing that exists moves

    func testANewSetupGoesToICloudDriveWhenItIsThere() {
        XCTAssertEqual(NotesFolderDefault.resolve(iCloudDriveRoot: iCloud, documents: documents).path,
                       iCloud.path + "/Notable")
        XCTAssertEqual(NotesFolderDefault.resolve(iCloudDriveRoot: nil, documents: documents).path,
                       "/Users/u/Documents/Notable")
    }

    func testAChosenFolderStays() {
        let resolution = NotesFolderDefault.initialFolder(
            storedPath: iCloud.path + "/Codus/Meetings",
            legacy: documents.appendingPathComponent("Notable"), legacyExists: true,
            fresh: iCloud.appendingPathComponent("Notable"))
        XCTAssertEqual(resolution, .stored(URL(fileURLWithPath: iCloud.path + "/Codus/Meetings", isDirectory: true)))
    }

    /// Never chosen, but notes lie in the old default: new ones land next to them.
    func testExistingNotesInTheOldDefaultArePinned() {
        let legacy = documents.appendingPathComponent("Notable")
        let resolution = NotesFolderDefault.initialFolder(storedPath: nil, legacy: legacy, legacyExists: true,
                                                          fresh: iCloud.appendingPathComponent("Notable"))
        XCTAssertEqual(resolution, .pinLegacy(legacy))
    }

    func testWithNothingThereTheNewDefaultApplies() {
        let fresh = iCloud.appendingPathComponent("Notable")
        XCTAssertEqual(NotesFolderDefault.initialFolder(storedPath: "", legacy: documents.appendingPathComponent("Notable"),
                                                        legacyExists: false, fresh: fresh), .fresh(fresh))
    }

    // MARK: - Sync

    func testSyncClassification() {
        let root = iCloud.path
        XCTAssertEqual(NotesFolderSync.classify(folder: root + "/Notable", iCloudRoot: root, iCloudRootExists: true, isUbiquitous: true), .iCloud)
        XCTAssertEqual(NotesFolderSync.classify(folder: root + "/Notable", iCloudRoot: root, iCloudRootExists: false, isUbiquitous: false), .iCloudDriveOff)
        // "Schreibtisch & Dokumente": synced without living under Mobile Documents.
        XCTAssertEqual(NotesFolderSync.classify(folder: "/Users/u/Documents/Notable", iCloudRoot: root, iCloudRootExists: true, isUbiquitous: true), .iCloud)
        XCTAssertEqual(NotesFolderSync.classify(folder: "/Users/u/Notes", iCloudRoot: root, iCloudRootExists: true, isUbiquitous: false), .local)
    }

    func testAPathThatOnlySharesAPrefixIsNotInside() {
        XCTAssertFalse(NotesFolderSync.isInside("/a/CloudDocs2/x", "/a/CloudDocs"))
        XCTAssertTrue(NotesFolderSync.isInside("/a/CloudDocs/x", "/a/CloudDocs/"))
    }

    // MARK: - Readable path

    /// The components as measured on this Mac on 2026-09-11.
    func testICloudPathReadsFromICloudDrive() {
        let display = ["Macintosh HD", "Users", "jonas", "Library", "Mobile Documents", "iCloud Drive", "Codus", "Meetings"]
        let anchor = ["Macintosh HD", "Users", "jonas", "Library", "Mobile Documents", "iCloud Drive"]
        XCTAssertEqual(NotesFolderDisplay.readable(display: display, anchor: anchor, showAnchor: true), "iCloud Drive › Codus › Meetings")
    }

    func testHomePathDropsTheHomeFolder() {
        let display = ["Macintosh HD", "Benutzer", "jonas", "Dokumente", "Notable"]
        let anchor = ["Macintosh HD", "Benutzer", "jonas"]
        XCTAssertEqual(NotesFolderDisplay.readable(display: display, anchor: anchor, showAnchor: false), "Dokumente › Notable")
    }

    func testAPathOutsideTheAnchorReadsInFull() {
        XCTAssertEqual(NotesFolderDisplay.readable(display: ["Extern", "Notizen"], anchor: ["Macintosh HD", "Users", "u"], showAnchor: false),
                       "Extern › Notizen")
    }

    // MARK: - Icon: never someone else's

    private func actions(enabled: Bool = true, folder: String = "/n", marker: String? = nil, hasIcon: Bool = false) -> [FolderIconRule.Action] {
        FolderIconRule.actions(enabled: enabled, folder: folder, marker: marker, folderHasIcon: hasIcon)
    }

    func testAPlainFolderGetsTheIcon() {
        XCTAssertEqual(actions(), [.set("/n")])
    }

    func testOurIconIsLeftAsItIs() {
        XCTAssertEqual(actions(marker: "/n", hasIcon: true), [])
    }

    /// The marker points elsewhere, so this icon was designed by someone else.
    func testAForeignIconIsNeverOverwritten() {
        XCTAssertEqual(actions(marker: nil, hasIcon: true), [])
    }

    func testSwitchingOffRemovesOnlyOurs() {
        XCTAssertEqual(actions(enabled: false, marker: "/n", hasIcon: true), [.remove("/n")])
        XCTAssertEqual(actions(enabled: false, marker: nil, hasIcon: true), [])
    }

    func testAFolderChangeTakesTheMarkOffTheOldFolder() {
        XCTAssertEqual(actions(folder: "/new", marker: "/old"), [.remove("/old"), .set("/new")])
        XCTAssertEqual(actions(folder: "/new", marker: "/old", hasIcon: true), [.remove("/old")], "fremdes Symbol am neuen Ordner bleibt")
    }

    /// An icon lost to a sync is put back at the next launch.
    func testALostIconIsRestored() {
        XCTAssertEqual(actions(marker: "/n", hasIcon: false), [.set("/n")])
    }

    func testMarkerFollowsTheActions() {
        XCTAssertEqual(FolderIconRule.marker(after: [.remove("/old"), .set("/new")], previous: "/old"), "/new")
        XCTAssertNil(FolderIconRule.marker(after: [.remove("/n")], previous: "/n"))
        XCTAssertEqual(FolderIconRule.marker(after: [], previous: ""), nil)
    }

    // MARK: - Relocation

    func testStoredPathsFollowTheFolder() {
        XCTAssertEqual(NotesRelocation.rewrite("/Users/u/Documents/Notable/Inbox/a.md", from: "/Users/u/Documents/Notable",
                                               to: iCloud.path + "/Notable"), iCloud.path + "/Notable/Inbox/a.md")
        XCTAssertEqual(NotesRelocation.rewrite("/old/x.md", from: "/old/", to: "/new/"), "/new/x.md")
    }

    func testAPathOutsideTheFolderIsLeftAlone() {
        XCTAssertNil(NotesRelocation.rewrite("/Users/u/Documents/Notable2/a.md", from: "/Users/u/Documents/Notable", to: "/x"))
        XCTAssertNil(NotesRelocation.rewrite("/elsewhere/a.md", from: "/Users/u/Documents/Notable", to: "/x"))
    }

    func testTheTargetNeverMergesIntoAnExistingFolder() {
        XCTAssertEqual(NotesRelocation.targetName(existing: []), "Notable")
        XCTAssertEqual(NotesRelocation.targetName(existing: ["Notable"]), "Notable 2")
        XCTAssertEqual(NotesRelocation.targetName(existing: ["Notable", "Notable 2"]), "Notable 3")
    }
}
