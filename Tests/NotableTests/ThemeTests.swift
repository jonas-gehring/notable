import Foundation
import XCTest

/// Spec 33 §3.3. The app looked as if two people had built it: half of it used
/// fixed point sizes and hand-picked radii, half used SwiftUI's semantic fonts —
/// 62 `.font(.system(size:))` calls and nine different corner radii against
/// three tokens. The migration is only worth something if it stays done, so
/// this reads the source, like `LocalizationTests`.
final class ThemeTests: XCTestCase {
    private static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Notable")
    }

    /// `Support/Theme.swift` defines the tokens and may use raw values.
    private static let exempt: Set<String> = ["Support/Theme.swift"]

    private func offending(_ matches: (String) -> Bool) throws -> [String] {
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var found: [String] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            let relative = file.path.replacingOccurrences(of: Self.sources.path + "/", with: "")
            guard !Self.exempt.contains(relative),
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (number, line) in text.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if matches(line) { found.append("  \(relative):\(number + 1): \(trimmed)") }
            }
        }
        return found
    }

    /// A fixed size ignores the system text size. Use a text style, or
    /// `Theme.Typography` for the two sizes no style covers.
    func testNoFixedFontSizes() throws {
        let found = try offending { $0.contains(".font(.system(size:") }
        XCTAssertTrue(found.isEmpty, "Feste Schriftgrößen:\n" + found.joined(separator: "\n"))
    }

    /// Three surface radii and one for chart marks, all in `Theme`.
    func testNoLiteralCornerRadii() throws {
        let pattern = try NSRegularExpression(pattern: #"cornerRadius:\s*\d"#)
        let found = try offending { line in
            pattern.firstMatch(in: line, range: NSRange(line.startIndex ..< line.endIndex, in: line)) != nil
        }
        XCTAssertTrue(found.isEmpty, "Radien ohne Token:\n" + found.joined(separator: "\n"))
    }

    /// A spacing that has a token uses it (Spec 33 §3.3). Values in between
    /// (6, 10, …) stay literal: rounding them onto the scale would move pixels
    /// nobody has looked at.
    ///
    /// `DictationOverlay.swift` stays exempt, but no longer for the reason that
    /// was written here: since Spec 37 it *does* see `Theme` (the HUD's
    /// animations come from `Motion`, so the file is in the test bundle). The
    /// capsule's measurements — 13 horizontal, 8 vertical, 9 between — are one
    /// set that was tuned together, and picking the one value that happens to
    /// sit on the scale out of it would make the set unreadable.
    func testSpacingOnTheScaleUsesTokens() throws {
        let pattern = try NSRegularExpression(
            pattern: #"(\.padding\((\.[a-zA-Z]+, )?|\bspacing: )(4|8|12|16|24)(?![\d.])"#
        )
        let found = try offending { line in
            pattern.firstMatch(in: line, range: NSRange(line.startIndex ..< line.endIndex, in: line)) != nil
        }.filter { !$0.contains("Dictation/DictationOverlay.swift") }
        XCTAssertTrue(found.isEmpty, "Abstände ohne Token:\n" + found.joined(separator: "\n"))
    }

    // MARK: - Motion (Spec 37 §3.1)

    /// `Motion.x` or nothing.
    ///
    /// Before Spec 37 there were five animations in the whole app and every one
    /// of them carried its duration where it stood — which is how a token set
    /// ends up defined and never referenced. A literal here is not a style
    /// question: it is a number nobody else can find.
    func testNoAnimationLiteralsOutsideTheme() throws {
        let patterns = try [
            #"\.(easeOut|easeIn|easeInOut|linear|spring|timingCurve)\(\s*(duration|response)"#,
            #"context\.duration\s*=\s*[\d.]"#,
        ].map { try NSRegularExpression(pattern: $0) }
        let found = try offending { line in
            patterns.contains { $0.firstMatch(in: line, range: NSRange(line.startIndex ..< line.endIndex, in: line)) != nil }
        }
        XCTAssertTrue(found.isEmpty, "Animationen ohne Token:\n" + found.joined(separator: "\n"))
    }

    /// A token set nobody uses is a promise nobody keeps (Spec 37 §3.1). The
    /// number is a floor, not a target — it exists so that deleting the last
    /// user of `Motion` fails here instead of silently.
    func testMotionIsActuallyUsed() throws {
        let uses = try occurrences(of: "Theme.Motion.")
        XCTAssertGreaterThanOrEqual(uses.count, 15, "Motion wird kaum benutzt: \(uses.count)")
        XCTAssertFalse(try occurrences(of: "Theme.hover").isEmpty, "Theme.hover: benutzen oder löschen")
        XCTAssertFalse(try occurrences(of: "Theme.Spacing.xl").isEmpty, "Spacing.xl: benutzen oder löschen")
    }

    /// Every file that animates asks whether it may.
    ///
    /// Deliberately coarse — it counts files, not call sites. What it catches is
    /// the one that actually happened: the statistics hover animated for years
    /// without ever reading `accessibilityReduceMotion`, because nothing forced
    /// the question to be asked in that file.
    func testEveryAnimatingFileReadsReduceMotion() throws {
        let animating = Set(try occurrences(of: "Theme.Motion.").map(Self.file))
        let asking = Set(try occurrences(of: "reduceMotion").map(Self.file))
        let silent = animating.subtracting(asking).sorted()
        XCTAssertTrue(silent.isEmpty, "animiert, ohne Reduce Motion zu lesen:\n" + silent.joined(separator: "\n"))
    }

    /// Lines containing `needle`, as "path:line: text".
    private func occurrences(of needle: String) throws -> [String] {
        try offending { $0.contains(needle) }
    }

    private static func file(_ occurrence: String) -> String {
        String(occurrence.trimmingCharacters(in: .whitespaces).prefix { $0 != ":" })
    }

    /// `textDefault` had the same value as `textEmphasis` and is gone.
    func testNoDuplicateTextToken() throws {
        let found = try offending { $0.contains("Theme.textDefault") }
        XCTAssertTrue(found.isEmpty, found.joined(separator: "\n"))
    }
}
