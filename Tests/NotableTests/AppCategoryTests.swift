import XCTest

final class AppCategoryTests: XCTestCase {
    func testKnownIDsMapToRightCategory() {
        XCTAssertEqual(AppCategory.of(bundleID: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(AppCategory.of(bundleID: "com.apple.mail"), .mail)
        XCTAssertEqual(AppCategory.of(bundleID: "com.apple.dt.Xcode"), .code)
        XCTAssertEqual(AppCategory.of(bundleID: "md.obsidian"), .prose)
    }

    /// Spec 31 §3.4: the apps this installation actually dictates into, and a
    /// browser, used to be missing from the table entirely.
    func testAppsActuallyDictatedIntoAreKnown() {
        XCTAssertEqual(AppCategory.of(bundleID: "com.apple.Safari"), .prose)
        XCTAssertEqual(AppCategory.of(bundleID: "com.anthropic.claudefordesktop"), .prose)
        XCTAssertEqual(AppCategory.of(bundleID: "com.memberstack.shipstudio"), .prose)
        XCTAssertEqual(AppCategory.of(bundleID: "com.mitchellh.ghostty"), .code)
        XCTAssertEqual(AppCategory.of(bundleID: "com.microsoft.teams2"), .chat)
        XCTAssertEqual(AppCategory.of(bundleID: "dev.zed.Zed"), .code)
    }

    /// Keys are looked up lower-cased; an uppercase key could never match.
    func testEveryBuiltInKeyIsLowercase() {
        for key in AppCategory.defaultMapping.keys {
            XCTAssertEqual(key, key.lowercased(), key)
        }
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

    func testOverridesRoundTripThroughDefaults() throws {
        let suite = "AppCategoryTests-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }

        AppCategory.saveOverrides(["com.example.Chat": .chat, "com.example.Code": .code], store: store)
        let loaded = AppCategory.loadOverrides(store)
        XCTAssertEqual(loaded, ["com.example.chat": .chat, "com.example.code": .code], "Schlüssel kleingeschrieben")
        XCTAssertEqual(AppCategory.of(bundleID: "com.example.Chat", overrides: loaded), .chat)
    }

    func testUnreadableOverrideIsDroppedNotGuessed() throws {
        let suite = "AppCategoryTests-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }

        store.set(["com.example.a": "unsinn", "com.example.b": "mail", "com.example.c": "unknown"],
                  forKey: AppCategory.overridesKey)
        XCTAssertEqual(AppCategory.loadOverrides(store), ["com.example.b": .mail])
    }

    /// Reassigning an app back to its built-in category removes the override,
    /// so a later table change still reaches it.
    func testAssigningTheBuiltInCategoryRemovesTheOverride() {
        var overrides = AppCategory.assigning(.prose, to: "com.apple.dt.Xcode", in: [:])
        XCTAssertEqual(overrides["com.apple.dt.xcode"], .prose)
        overrides = AppCategory.assigning(.code, to: "com.apple.dt.Xcode", in: overrides)
        XCTAssertNil(overrides["com.apple.dt.xcode"])
    }

    func testUnknownIsNotAssignable() {
        XCTAssertFalse(AppCategory.assignable.contains(.unknown))
    }

    func testLabelsAreGerman() {
        XCTAssertEqual(AppCategory.chat.label, "Chat")
        XCTAssertEqual(AppCategory.mail.label, "E-Mail")
        XCTAssertEqual(AppCategory.code.label, "Code")
        XCTAssertEqual(AppCategory.prose.label, "Text/Prosa")
        XCTAssertEqual(AppCategory.unknown.label, "Unbekannt")
    }
}
