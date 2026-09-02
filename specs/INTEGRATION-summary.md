# Integration spec — wiring the auto title + subtitle into `produceNote`

Status: instructions for the integrator. This branch delivered the
summarization half (prompt, `SummaryParser`, `Summary.title`/`Summary.subtitle`,
both providers populate them). It deliberately did **not** touch
`MeetingController.swift`. This file says exactly how `produceNote` (and the
`retrySummary` path) should consume the new fields.

Privacy invariant is unchanged: only the transcript **text** is sent to a
provider. Title and subtitle come back *from* that same call — no new data class
leaves the device.

---

## What already changed (this branch)

- `SummarizationPrompt.system` now asks the model to emit two machine-readable
  header lines before the Markdown body:
  ```
  TITLE: <kurze Substantivphrase, ≤ 6 Wörter>
  TLDR: <ein Satz, ≤ 15 Wörter>

  ## Zusammenfassung
  …
  ```
- `SummaryParser.parse(_:)` splits those header lines off (tolerant: missing
  headers ⇒ `nil`, whole text stays as `markdown`).
- `Summary` gained `title: String?` and `subtitle: String?`.
  `Summary.markdown` is the **clean body** (header lines removed).
- `AnthropicAPIProvider` and `ClaudeCodeCLIProvider` build their result with
  `Summary(rawModelOutput:providerID:)`, so `title`/`subtitle` are always
  populated when the model supplied them.

So at the call site `SummarizationService.summarize(...)` now returns a `Summary`
whose `.title` / `.subtitle` may be non-nil. Nothing downstream reads them yet.

---

## Dependency: storage columns + methods

This integration assumes the note-management storage work
(`specs/note-management-ui.md` §3.1) has landed, i.e. `RecordingStore` has:

- columns `subtitle TEXT`, `title_is_auto INTEGER DEFAULT 0` on `recordings`
  (and `summary`, `folder` per that spec);
- `func setSummary(_ summary: String?, subtitle: String? = nil, for id: String) throws`;
- `func updateTitle(_ title: String, titleIsAuto: Bool, markdownPath: String?, for id: String) throws`.

If that work is not yet present in this tree, land it first — the snippets below
call those methods by name. (On the branch this spec was written against, that
storage layer is **not** yet present; it comes from the note-management branch.)

---

## `produceNote` changes

Current shape (`MeetingController.swift`, `produceNote`):

1. `let title = event?.title ?? "Meeting"` — provisional title.
2. Write the transcript Markdown first (survives a summary failure).
3. `insertMeeting(recording, segments:)` into SQLite.
4. If there is speech, `SummarizationService.summarize(...)` → `note.summary =
   summary.markdown`, re-render the file.

Keep steps 1–3 exactly as they are. Only the summarize branch (step 4) changes.

### Rule for the title

> **Only override the title when the meeting had no calendar event** — i.e. when
> the title is auto (`titleIsAuto`). A real calendar title always wins; the model
> title merely fills the gap the `"Meeting"` fallback used to.

```swift
let titleIsAuto = (event == nil)   // no calendar event ⇒ the title is ours to set
```

### The summarize branch

Replace the body of the `else` (speech present) branch with:

```swift
let transcriptText = segments
    .map { "\($0.speaker ?? "Unbekannt"): \($0.text)" }
    .joined(separator: "\n")
let context = MeetingContext(title: title, date: startedAt, durationSeconds: duration)
do {
    let summary = try await SummarizationService.summarize(
        transcript: transcriptText,
        context: context,
        providerID: providerID
    )

    // Body (header lines already stripped by SummaryParser inside the provider).
    note.summary = summary.markdown

    // Auto title: only when there is no calendar event AND the model gave one.
    var finalTitle = title
    var finalURL = fileURL
    if titleIsAuto, let modelTitle = summary.title, !modelTitle.isEmpty {
        finalTitle = modelTitle
        note.title = modelTitle
        // Rename the file to match the new title (collision-safe helper from
        // note-management §3.3; falls back to the original URL if unavailable).
        let dir = fileURL.deletingLastPathComponent()
        let newName = MarkdownProjector.uniqueFileName(
            in: dir, title: modelTitle, date: startedAt, excluding: fileURL
        )
        let target = dir.appendingPathComponent(newName)
        if target != fileURL {
            try? FileManager.default.moveItem(at: fileURL, to: target)
            finalURL = target
        }
    }

    // Re-render the (possibly retitled) note body + summary to disk.
    try MarkdownProjector.render(note).write(to: finalURL, atomically: true, encoding: .utf8)

    // Persist to the source of truth. Subtitle always; title only when auto.
    try await RecordingStore.shared.setSummary(
        summary.markdown, subtitle: summary.subtitle, for: recording.id
    )
    if titleIsAuto, finalTitle != title {
        try await RecordingStore.shared.updateTitle(
            finalTitle, titleIsAuto: true, markdownPath: finalURL.path, for: recording.id
        )
    }
} catch {
    summaryError = error.localizedDescription
    retry = RetryPayload(note: note, fileURL: fileURL, transcript: transcriptText, context: context)
}
```

Notes:

- **Failure path is unchanged.** On a summary error the note keeps the
  provisional `"Meeting"` title and stays retryable (existing `summaryRetry`
  flow). No rename, no subtitle — the model gave us nothing to use.
- `RetryPayload` should carry `recording.id` so the retry can persist the
  subtitle/title too (see below). If it currently only holds `note`/`fileURL`/
  `transcript`/`context`, add `recordingID: String`.
- If the note-management collision helper `uniqueFileName` is not present, keep
  the original `fileURL` and skip the rename — the DB `title` still updates; the
  filename simply keeps the timestamp-based name. Do **not** overwrite an
  existing file blind.

### `retrySummary`

Mirror the same block: after a successful retry, set `note.summary`, apply the
auto-title rename when `titleIsAuto` and `summary.title != nil`, and call
`setSummary(_:subtitle:for:)` (and `updateTitle` when the title changed) with the
retained `recordingID`. This keeps disk and SQLite in agreement on the retry path
exactly as on the first pass.

---

## Acceptance

- A meeting **with** a calendar event: title stays the calendar title;
  `subtitle` is stored; body is the new §7-style Markdown.
- A meeting **without** a calendar event: gets the model's concise title (not
  `"Meeting"`), the `.md` is renamed to match (collision-safe), `title_is_auto=1`,
  and the subtitle is stored.
- A summary failure: note keeps `"Meeting"`, no subtitle, retry still works.
- Only transcript text was sent to the provider.
