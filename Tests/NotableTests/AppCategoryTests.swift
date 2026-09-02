import XCTest

final class AppCategoryTests: XCTestCase {
    func testKnownIDsMapToRightCategory() {
        XCTAssertEqual(AppCategory.of(bundleID: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(AppCategory.of(bundleID: "com.apple.mail"), .mail)
        XCTAssertEqual(AppCategory.of(bundleID: "com.apple.dt.Xcode"), .code)
        XCTAssertEqual(AppCategory.of(bundleID: "md.obsidian"), .prose)
    }

    func testBundleIDMatchIsCaseInsensitive() {
        XCTAssertEqual(AppCategory.of(bundleID: "COM.APPLE.DT.XCODE"), .code)
    }

    func testNilBundleIDIsUnknown() {
        XCTAssertEqual(AppCategory.of(bundleID: nil), .unknown)
    }

    func testUnlistedBundleIDIsUnknown() {
        XCTAssertEqual(AppCategory.of(bundleID: "com.example.SomeRandomApp"), .unknown)
    }

    func testOverrideWinsOverBuiltInTable() {
        // Xcode is built-in `.code`; the user reclassifies it as prose.
        let category = AppCategory.of(
            bundleID: "com.apple.dt.Xcode",
            overrides: ["com.apple.dt.Xcode": .prose]
        )
        XCTAssertEqual(category, .prose)
    }

    func testOverrideResolvesIDAbsentFromBuiltInTable() {
        let category = AppCategory.of(
            bundleID: "com.example.MyChatApp",
            overrides: ["com.example.MyChatApp": .chat]
        )
        XCTAssertEqual(category, .chat)
    }

    func testLabelsAreGerman() {
        XCTAssertEqual(AppCategory.chat.label, "Chat")
        XCTAssertEqual(AppCategory.mail.label, "E-Mail")
        XCTAssertEqual(AppCategory.code.label, "Code")
        XCTAssertEqual(AppCategory.prose.label, "Text/Prosa")
        XCTAssertEqual(AppCategory.unknown.label, "Unbekannt")
    }
}
