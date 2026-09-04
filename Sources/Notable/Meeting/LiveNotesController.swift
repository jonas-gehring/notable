import Foundation

/// Owns the live-notes buffer for the meeting that is currently being recorded.
///
/// Two things make this more than a `@Published String`:
///
/// 1. **Crash safety.** The buffer is mirrored into the meeting's spool
///    directory (`notes.md`) on every change, debounced. A crash mid-call, or a
///    pipeline failure that defers the meeting to next-launch recovery, both
///    still find the notes — the same guarantee the raw PCM tracks already have.
/// 2. **The elapsed-time base** for `⌘T` timestamps, so a stamp means "4:51 into
///    the call", not a wall-clock time.
///
/// The text itself is nothing new: it is the `userNotes` the note pipeline
/// already understands (verbatim `## Eigene Notizen` in the Inbox note, ground
/// truth for the summarizer, context for the meeting chat).
@MainActor
final class LiveNotesController: ObservableObject {
    /// The buffer the editor binds to. Every change re-arms the spool autosave.
    @Published var text: String = "" {
        didSet { scheduleSave() }
    }

    /// Start of the running meeting; `nil` when nothing is being recorded.
    /// Doubles as the "notes are live" flag.
    @Published private(set) var startedAt: Date?

    /// Window header — the calendar event's title once the (async) match lands,
    /// a neutral fallback until then.
    @Published private(set) var title: String = String(localized: "Meeting")

    private var spool: SpoolStore.Session?
    private var pendingSave: Task<Void, Never>?

    /// How long the autosave waits after the last keystroke. Small enough that a
    /// crash loses at most a word, large enough not to write on every character.
    private let saveDelay: TimeInterval = 0.8

    var isActive: Bool { startedAt != nil }

    /// Seconds into the meeting, for the header clock and `⌘T`. Zero when idle.
    func elapsed(at now: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    // MARK: - Lifecycle (driven by MeetingController)

    /// Starts a note-taking session for a recording that just began. Any text
    /// left over from a previous meeting is dropped — notes belong to exactly one
    /// meeting, and `finish()` has already consumed the previous one.
    func begin(startedAt: Date, title: String, spool: SpoolStore.Session?) {
        pendingSave?.cancel()
        pendingSave = nil
        self.spool = spool
        self.startedAt = startedAt
        self.title = title
        text = ""
    }

    /// The calendar match arrives after the recording starts — retitle then.
    func updateTitle(_ title: String) {
        guard isActive else { return }
        self.title = title
    }

    /// Ends the session and returns what should be stored (`nil` when nothing was
    /// typed). The spool copy is flushed *synchronously* first: if the caller's
    /// processing then throws, the meeting falls back to next-launch recovery,
    /// which reads the notes back out of the spool.
    @discardableResult
    func finish() -> String? {
        pendingSave?.cancel()
        pendingSave = nil
        let stored = LiveNotes.storable(text)
        if let spool { SpoolStore.writeNotes(stored, to: spool) }
        clear()
        return stored
    }

    /// Abandons the session without persisting — used when a recording fails to
    /// start at all, so a half-open session cannot linger.
    func cancel() {
        pendingSave?.cancel()
        pendingSave = nil
        clear()
    }

    private func clear() {
        spool = nil          // set first: the `text` didSet must not re-arm a save
        startedAt = nil
        title = String(localized: "Meeting")
        text = ""
    }

    // MARK: - Autosave

    /// Debounced mirror into the spool.
    ///
    /// This deliberately does **not** use `DispatchQueue.global().asyncAfter`: a
    /// closure formed inside a `@MainActor` type inherits that isolation, so
    /// running it on a background queue trips Swift 6's executor check and traps
    /// the process (`dispatch_assert_queue` → SIGTRAP) — it crashed on the first
    /// keystroke of every meeting. A `Task` suspends on the main actor without
    /// blocking it, and the write itself is `nonisolated`, which puts the file I/O
    /// on the global executor where it belongs.
    private func scheduleSave() {
        guard let spool else { return }
        pendingSave?.cancel()
        let snapshot = LiveNotes.storable(text)
        let delay = saveDelay
        pendingSave = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot, to: spool)
        }
    }

    /// `nonisolated async` — runs on the global executor, so the write never
    /// touches the main actor.
    private nonisolated static func write(_ text: String?, to spool: SpoolStore.Session) async {
        SpoolStore.writeNotes(text, to: spool)
    }
}
