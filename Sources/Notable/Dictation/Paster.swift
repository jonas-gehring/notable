import AppKit
import ApplicationServices
import CoreGraphics

/// Pastes text into the focused field of whatever app is frontmost:
/// save pasteboard → set transcript → synthesize ⌘V → restore pasteboard.
/// The synthesized keystroke requires the Accessibility permission.
@MainActor
enum Paster {
    enum PasteError: Error, LocalizedError {
        case accessibilityDenied

        var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                String(localized: "Bedienungshilfen fehlen — Text liegt in der Zwischenablage (⌘V).")
            }
        }
    }

    enum Method: String {
        case pasteboard
        case typing

        static let storageKey = "pasteMethod"

        static var current: Method {
            UserDefaults.standard.string(forKey: storageKey).flatMap(Method.init(rawValue:)) ?? .pasteboard
        }
    }

    /// Without Accessibility, CGEvent.post() is silently discarded by the
    /// window server: the paste would appear to succeed while the transcript
    /// went nowhere. Leave the text on the pasteboard and let the caller say
    /// so — a lost dictation is the one failure the user cannot recover from.
    static func insert(_ text: String) throws {
        guard AXIsProcessTrusted() else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            throw PasteError.accessibilityDenied
        }
        switch Method.current {
        case .pasteboard: paste(text)
        case .typing: type(text)
        }
    }

    /// Fallback for apps that swallow ⌘V: synthesize the text as keyboard
    /// events (≤ 20 UTF-16 units per event, per CGEvent contract) — chunked
    /// on Character boundaries so surrogate pairs and emoji stay intact.
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for chunk in utf16Chunks(of: text, limit: 20) {
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Splits on Character boundaries, never exceeding `limit` UTF-16 units.
    static func utf16Chunks(of text: String, limit: Int) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var current: [UInt16] = []
        for character in text {
            let units = Array(String(character).utf16)
            if current.count + units.count > limit, !current.isEmpty {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// How much of the previous pasteboard is worth carrying across a paste.
    ///
    /// Two megabytes: enough for text, a small image and the usual pile of
    /// private flavours, far below anything that costs visible time to copy.
    static let snapshotByteBudget = 2 * 1024 * 1024

    /// Flavours that are *promises*, not data. Asking for their bytes is what
    /// makes the promising app produce them — writing a temp file, rendering an
    /// export — which is both slow and a side effect Notable has no business
    /// triggering just because someone dictated.
    private static func isPromise(_ type: NSPasteboard.PasteboardType) -> Bool {
        let name = type.rawValue
        return name.hasPrefix("com.apple.pasteboard.promised")
            || name.hasPrefix("com.apple.NSFilePromise")
            || name == "com.apple.pasteboard.promised-file-url"
    }

    /// A copy of the current pasteboard, bounded.
    ///
    /// This runs synchronously on the main thread inside the release→paste
    /// budget, and it used to pull *every* representation of every item: one
    /// large image, or a file promise, cost hundreds of milliseconds right where
    /// the user is waiting. Over budget, the plain string is kept and the rest
    /// is let go — losing an image from the clipboard is a smaller harm than a
    /// dictation that visibly stalls, and the string is what almost every
    /// clipboard actually holds.
    static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        var remaining = snapshotByteBudget
        var overBudget = false
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types where !isPromise(type) {
                guard let data = item.data(forType: type) else { continue }
                guard data.count <= remaining else { overBudget = true; continue }
                remaining -= data.count
                contents[type] = data
            }
            items.append(contents)
        }
        guard overBudget else { return items }
        return items.map { $0.filter { $0.key == .string } }.filter { !$0.isEmpty }
    }

    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedItems = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let transcriptChangeCount = pasteboard.changeCount

        postCommandV()

        // Restore the previous pasteboard after the paste has been delivered —
        // but only if nothing else has written to it since (a user copy, or
        // an overlapping dictation's paste).
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard pasteboard.changeCount == transcriptChangeCount else { return }
            pasteboard.clearContents()
            let items = savedItems.map { contents -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in contents {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !items.isEmpty {
                pasteboard.writeObjects(items)
            }
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyV: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
