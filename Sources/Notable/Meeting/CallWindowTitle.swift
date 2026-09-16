import Foundation

/// The call window's own title as a title for the note (Spec 36 §3.1).
///
/// 13 of 18 meetings found no calendar event (Spec 35 §1), and the fallback then
/// says "Microsoft Teams · 10:03" — true, and nothing about what the meeting
/// was. The title bar of the call app usually carries the name the organiser
/// chose. It is ranked **before** the model (decided 2026-09-16): the model
/// invents a title from the transcript, the window quotes the one that was
/// actually set.
///
/// What comes back is a title or nothing. Everything below errs towards
/// nothing — a wrong note title is a file name, a search term and a line in a
/// list, all of them wrong at once.
enum CallWindowTitle {
    /// Fewer words than this and it is a label, not a title: "Besprechung",
    /// "Meeting", "Zoom".
    static let minimumWords = 3

    /// What the window title says about the app rather than about the meeting.
    /// Matched against a whole separated part, never as a substring — a meeting
    /// genuinely called "Teams-Migration" keeps its name.
    static let appNames: Set<String> = [
        "microsoft teams", "teams", "zoom", "zoom workplace", "zoom meeting",
        "google meet", "meet", "webex", "cisco webex", "slack", "facetime",
        "google chrome", "chrome", "safari", "firefox", "microsoft edge", "arc",
    ]

    /// Status words a call app appends: "| Meeting", "– Besprechung läuft".
    static let statusWords: Set<String> = [
        "meeting", "besprechung", "call", "anruf", "video call", "videoanruf",
        "in a meeting", "im meeting", "laufend", "live",
    ]

    private static let separators: CharacterSet = CharacterSet(charactersIn: "|—–·•")

    /// The title, or `nil` when nothing recognisable is left.
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw
            .components(separatedBy: separators)
            .flatMap { $0.components(separatedBy: " - ") }
            .map(trimmed)
            .filter { !$0.isEmpty }
        for part in parts {
            let name = withoutBadge(part)
            let key = name.lowercased()
            guard !appNames.contains(key), !statusWords.contains(key) else { continue }
            guard words(in: name) >= minimumWords else { continue }
            return name
        }
        return nil
    }

    /// The best title the observations of one meeting offer: the one seen most
    /// often, so a window that briefly said something else does not win.
    static func fromObservations(_ observations: [ScreenObservation]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for observation in observations {
            guard let title = clean(observation.windowTitle) else { continue }
            if counts[title] == nil { order.append(title) }
            counts[title, default: 0] += 1
        }
        // `max(by:)` keeps the first of equal elements, and `order` is
        // first-seen order — so a tie goes to the title that stood there first.
        return order.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
    }

    /// Strips an unread badge ("(3) Anna Weber …") and a trailing window number
    /// ("… (1)"), both of which are about the app's state, not the meeting.
    private static func withoutBadge(_ text: String) -> String {
        var result = text
        if result.hasPrefix("("), let close = result.firstIndex(of: ")"),
           result[result.index(after: result.startIndex) ..< close].allSatisfy(\.isNumber) {
            result = trimmed(String(result[result.index(after: close)...]))
        }
        if result.hasSuffix(")"), let open = result.lastIndex(of: "("),
           result[result.index(after: open) ..< result.index(before: result.endIndex)].allSatisfy(\.isNumber) {
            result = trimmed(String(result[result.startIndex ..< open]))
        }
        return result
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func words(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
