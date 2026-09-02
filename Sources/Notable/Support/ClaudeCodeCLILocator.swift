import Foundation

/// Where the Claude Code CLI lives. A thin name over the shared lookup — kept
/// because the provider, its tests and the settings screen all refer to it.
enum ClaudeCodeCLILocator {
    static func locate() -> String? {
        CLIToolLocator.locate(["claude"])
    }
}
