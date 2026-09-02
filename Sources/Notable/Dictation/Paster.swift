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
                "Bedienungshilfen fehlen — Text liegt in der Zwischenablage (⌘V)."
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

    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general

        let savedItems: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    contents[type] = data
                }
            }
            return contents
        }

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
