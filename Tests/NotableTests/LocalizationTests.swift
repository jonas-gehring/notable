import Foundation
import XCTest
@testable import Notable

/// Guards the English translation table against the one failure mode it has.
///
/// A missing key does not crash and does not warn: `NSLocalizedString` returns the
/// key itself, and the key is the German text. So an untranslated string shows up
/// as a German sentence sitting in an otherwise English window — which nobody
/// notices until a user reports it, and which grows by one every time a literal is
/// added to the source. Xcode's own extraction cannot be relied on to catch it
/// either: it sees `Text("…")` but silently skips `Button("…")`, `Picker("…")` and
/// `LabeledContent("…")`, which is where most of the interface actually lives.
///
/// This test therefore scans the source itself and demands an entry for every
/// user-facing literal it finds.
final class LocalizationTests: XCTestCase {
    /// Files whose German literals are **data, not interface**, and must never be
    /// translated: spoken commands the recognizer matches against, filler-word
    /// lists, the Markdown structure of a note, and the prompts sent to a model.
    /// Translating any of these would change behaviour, not language.
    private static let excludedFiles: Set<String> = [
        "Dictation/ParagraphFormatter.swift",
        "Dictation/TextPolisher.swift",
        "Dictation/SmartReplace.swift",
        "Dictation/SpokenLanguages.swift",
        "Meeting/ChatPrompt.swift",
        "Storage/MarkdownProjector.swift",
        "Summarization/SummarizationPrompt.swift",
        "Summarization/SummaryParser.swift",
    ]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)      // Tests/NotableTests/LocalizationTests.swift
            .deletingLastPathComponent()     // Tests/NotableTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // repo root
    }

    private static func englishTable() throws -> [String: String] {
        let url = repoRoot.appendingPathComponent("Resources/en.lproj/Localizable.strings")
        guard let dict = NSDictionary(contentsOf: url) as? [String: String] else {
            throw XCTSkip("en.lproj/Localizable.strings not readable at \(url.path)")
        }
        return dict
    }

    /// Literals passed to the SwiftUI initializers that take a `LocalizedStringKey`.
    /// Interpolated ones are skipped: their runtime key carries format specifiers
    /// (`%@`, `%1$@`) that cannot be reconstructed from the source text, so they are
    /// covered by the export instead.
    private static func sourceKeys() -> [(key: String, location: String)] {
        let calls = "Text|Button|Toggle|LabeledContent|Picker|Label|Stepper|TextField|SecureField|Link|Section|Menu"
        let patterns = [
            "\\b(?:\(calls))\\(\\s*\"((?:[^\"\\\\]|\\\\.)+)\"",
            "\\.help\\(\\s*\"((?:[^\"\\\\]|\\\\.)+)\"",
            "\\.navigationTitle\\(\\s*\"((?:[^\"\\\\]|\\\\.)+)\"",
        ].compactMap { try? NSRegularExpression(pattern: $0) }

        let sources = repoRoot.appendingPathComponent("Sources/Notable")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            return []
        }

        var found: [(String, String)] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            let relative = file.path.replacingOccurrences(of: sources.path + "/", with: "")
            if excludedFiles.contains(relative) { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for (number, line) in text.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                for pattern in patterns {
                    for match in pattern.matches(in: line, range: range) {
                        guard let r = Range(match.range(at: 1), in: line) else { continue }
                        // The scanner reads source text, so a literal written with
                        // a `\u{201C}` escape has to be decoded first — otherwise the
                        // key it looks for is not the key the app asks for at runtime.
                        let key = Self.decodingUnicodeEscapes(String(line[r]))
                        // Interpolated, empty, or a bare SF Symbol name — none of
                        // those are translatable literals.
                        if key.contains("\\(") || key.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                        found.append((key, "\(relative):\(number + 1)"))
                    }
                }
            }
        }
        return found
    }

    /// Turns `\u{201C}` into the character it stands for. Swift string literals may
    /// spell any character that way, and several here do — the German quotation
    /// marks, which would otherwise close the literal early in the source.
    static func decodingUnicodeEscapes(_ source: String) -> String {
        guard source.contains("\\u{") else { return source }
        guard let pattern = try? NSRegularExpression(pattern: "\\\\u\\{([0-9A-Fa-f]{1,8})\\}") else { return source }
        var out = source
        while let match = pattern.firstMatch(in: out, range: NSRange(out.startIndex ..< out.endIndex, in: out)),
              let whole = Range(match.range, in: out),
              let digits = Range(match.range(at: 1), in: out),
              let value = UInt32(out[digits], radix: 16),
              let scalar = Unicode.Scalar(value) {
            out.replaceSubrange(whole, with: String(Character(scalar)))
        }
        return out
    }

    /// The whole point: every literal the interface shows has an English entry.
    func testEveryUserFacingLiteralHasAnEnglishTranslation() throws {
        let table = try Self.englishTable()
        let keys = Self.sourceKeys()
        XCTAssertGreaterThan(keys.count, 100, "The scan found almost nothing — the patterns have drifted from the source.")

        let untranslated = keys
            .filter { table[$0.key] == nil }
            .map { "  \($0.location): \"\($0.key)\"" }
            .sorted()

        XCTAssertTrue(untranslated.isEmpty, """
            \(untranslated.count) user-facing string(s) have no entry in \
            Resources/en.lproj/Localizable.strings and would show up in German \
            inside an English interface:
            \(untranslated.joined(separator: "\n"))
            """)
    }

    /// An empty translation is worse than a missing one: the key falls back to
    /// itself when it is absent, but renders as nothing at all when it is blank.
    func testNoTranslationIsEmpty() throws {
        for (key, value) in try Self.englishTable() where value.isEmpty {
            XCTFail("Empty translation for \"\(key)\"")
        }
    }

    /// Format specifiers have to survive translation. A `%@` dropped from the
    /// English side means an argument silently vanishes from the sentence; one
    /// added means a crash when the string is formatted.
    func testFormatSpecifiersMatch() throws {
        let specifier = try NSRegularExpression(pattern: "%(?:\\d+\\$)?[@dlfs]+|%%")
        func specifiers(_ s: String) -> [String] {
            let range = NSRange(s.startIndex ..< s.endIndex, in: s)
            return specifier.matches(in: s, range: range).compactMap {
                Range($0.range, in: s).map { r in String(s[r]) }
            }.sorted()
        }
        for (key, value) in try Self.englishTable() {
            XCTAssertEqual(specifiers(key), specifiers(value),
                           "Format specifiers differ between key and translation for \"\(key)\"")
        }
    }

    /// The German side is the key language, so `de.lproj` is deliberately almost
    /// empty — but it has to exist, or macOS does not offer German as a choice at
    /// all and `AppLanguage.german` silently does nothing.
    ///
    /// What this pins is the *precondition*, not the switch itself: whether a
    /// running app actually picks up `AppleLanguages` cannot be observed from a
    /// test bundle, because the strings live in the app bundle and `Bundle.main`
    /// here is the test runner. Measured on the built app,
    /// `preferredLocalizations(from:forPreferences: ["de"])` does resolve to `de`,
    /// so the bundle offers both languages correctly.
    func testGermanLocalizationExistsSoItCanBeChosen() {
        let url = Self.repoRoot.appendingPathComponent("Resources/de.lproj/Localizable.strings")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSystemLanguageRemovesTheOverrideRatherThanPinningOne() {
        let suite = "LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        AppLanguage.apply(.english, to: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: AppLanguage.appleLanguagesKey), ["en"])
        XCTAssertEqual(AppLanguage.current(defaults), .english)

        // `array(forKey:)` on a suite still falls through to NSGlobalDomain, where
        // the user's real language order lives — so "no override" is not "nil
        // there". Ask the suite's own domain instead, which is what actually gets
        // removed.
        AppLanguage.apply(.system, to: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?[AppLanguage.appleLanguagesKey])
        XCTAssertEqual(AppLanguage.current(defaults), .system)
    }

    /// An unreadable preference must leave the app in *a* language, not in none.
    func testUnknownStoredValueFallsBackToSystem() {
        let defaults = UserDefaults(suiteName: "LocalizationTests.\(UUID().uuidString)")!
        defaults.set("klingon", forKey: AppLanguage.storageKey)
        XCTAssertEqual(AppLanguage.current(defaults), .system)
    }
}
