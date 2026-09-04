import AppKit
import Foundation

/// Quick access to the already-persisted dictation history: copy or re-paste
/// the last dictation, and a small "recent" list for the menu.
///
/// Every dictation is already saved by `DictationController.finishRecording`
/// via `RecordingStore.saveDictation`; this type only *reads* that history and
/// replays it. The only side effects are the clipboard and `Paster` — no new
/// state is owned here. Deliberately out of scope: true "undo" of a paste that
/// already landed in another app. macOS gives no reliable hook to retract a
/// synthesized ⌘V (the target app may have transformed, autocorrected, or
/// moved the text), so we never pretend to. Re-paste + copy are the honest,
/// achievable actions over the same data.
@MainActor
final class DictationHistory: ObservableObject {
    /// One row of history, shaped for a menu.
    struct Item: Identifiable, Equatable {
        /// Stable within a single loaded list (its position, newest = 0).
        let id: Int
        let date: Date
        let text: String
        /// The rule-polished text before an LLM enhancement replaced it. nil for
        /// every ordinary dictation.
        var rawText: String? = nil

        /// Single-line, length-capped label for a menu row.
        var menuTitle: String { DictationHistory.menuTitle(for: text) }
    }

    /// Most recent dictations, newest first. Refreshed on demand.
    @Published private(set) var recent: [Item] = []

    private let store: RecordingStore
    private let limit: Int

    init(store: RecordingStore = .shared, limit: Int = 8) {
        self.store = store
        self.limit = limit
    }

    /// The newest dictation, if any is loaded.
    var last: Item? { recent.first }

    /// Reloads `recent` from the store. Best-effort: a read failure leaves the
    /// previously loaded list untouched rather than blanking the menu.
    func refresh() async {
        guard let rows = try? await store.recentDictations(limit: limit) else { return }
        recent = rows.enumerated().map { index, row in
            Item(id: index, date: row.date, text: row.text, rawText: row.rawText)
        }
    }

    // MARK: - Actions (side effects: clipboard + Paster only)

    /// Copies the most recent dictation to the clipboard. Returns false when
    /// there is no history yet.
    @discardableResult
    func copyLast() async -> Bool {
        await refresh()
        guard let text = last?.text else { return false }
        Self.copyToClipboard(text)
        return true
    }

    /// Copies a specific dictation (e.g. a chosen row) to the clipboard.
    func copy(_ text: String) {
        Self.copyToClipboard(text)
    }

    /// Re-inserts the most recent dictation into the focused field, respecting
    /// the accessibility / paste-method logic in `Paster`. Returns false when
    /// there is no history, or throws whatever `Paster.insert` throws (e.g.
    /// accessibility denied — in which case the text is left on the clipboard).
    @discardableResult
    func pasteLast() async throws -> Bool {
        await refresh()
        guard let text = last?.text else { return false }
        try Paster.insert(text)
        return true
    }

    /// Re-inserts a specific dictation into the focused field.
    func paste(_ text: String) throws {
        try Paster.insert(text)
    }

    // MARK: - Enhancement on request (issue #1 Stufe 2)

    /// The last enhanced result, kept so the notification's "Einfügen" button has
    /// something to insert.
    private(set) var lastEnhanced: String?

    /// Sends the most recent dictation through the Claude Code CLI and puts the
    /// result **on the clipboard**.
    ///
    /// Deliberately not pasted over the original: that text landed in a foreign
    /// app seconds ago and there is no way to take it back (see the note at the
    /// top of this type). Overwriting it would require pretending we can, so the
    /// improved version is offered rather than imposed.
    ///
    /// Returns nil when there is no history or the feature is switched off.
    @discardableResult
    func enhanceLast(profile: EnhancementProfile) async -> DictationEnhancer.Result? {
        guard EnhancementSettings.isEnabled else { return nil }
        await refresh()
        guard let text = last?.text else { return nil }

        let result = await DictationEnhancer.forDictation().enhance(text, profile: profile)
        await UsageRecorder.record(
            result.usage,
            provider: DictationEnhancer.dictationProvider.id,
            purpose: .dictationEnhance,
            recordingID: nil,
            countEvenWhenUnknown: true
        )
        guard result.didEnhance else { return result }

        // Clipboard only. Posting the notification is the menu's job — this
        // type's contract (see the note at the top) is that its side effects are
        // the clipboard and `Paster`, nothing else.
        lastEnhanced = result.text
        Self.copyToClipboard(result.text)
        return result
    }

    /// Inserts the last enhanced text — what the notification's button does.
    ///
    /// Returns the failure rather than swallowing it: without Accessibility the
    /// synthesized ⌘V goes nowhere, and the user tapped a button that then did
    /// nothing at all. The text is on the clipboard either way; the caller says
    /// so.
    @discardableResult
    func pasteLastEnhanced() -> Error? {
        guard let lastEnhanced else { return nil }
        do {
            try Paster.insert(lastEnhanced)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Pure / near-pure helpers

    /// Replaces the clipboard contents with `text`.
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Collapses whitespace/newlines to single spaces, trims, and caps the
    /// length with an ellipsis — a transcript is one flat menu row, not prose.
    /// `nonisolated`: pure, so `Item.menuTitle` can call it off the main actor.
    nonisolated static func menuTitle(for text: String, limit: Int = 48) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        let clipped = collapsed.prefix(limit).trimmingCharacters(in: .whitespaces)
        return clipped + "…"
    }
}
