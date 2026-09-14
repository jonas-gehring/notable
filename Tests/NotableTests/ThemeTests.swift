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
    /// nobody has looked at. `DictationOverlay.swift` is compiled into the test
    /// bundle without `Theme` and keeps its numbers.
    func testSpacingOnTheScaleUsesTokens() throws {
        let pattern = try NSRegularExpression(
            pattern: #"(\.padding\((\.[a-zA-Z]+, )?|\bspacing: )(4|8|12|16|24)(?![\d.])"#
        )
        let found = try offending { line in
            pattern.firstMatch(in: line, range: NSRange(line.startIndex ..< line.endIndex, in: line)) != nil
        }.filter { !$0.contains("Dictation/DictationOverlay.swift") }
        XCTAssertTrue(found.isEmpty, "Abstände ohne Token:\n" + found.joined(separator: "\n"))
    }

    /// `textDefault` had the same value as `textEmphasis` and is gone.
    func testNoDuplicateTextToken() throws {
        let found = try offending { $0.contains("Theme.textDefault") }
        XCTAssertTrue(found.isEmpty, found.joined(separator: "\n"))
    }
}
