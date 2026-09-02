# Integration: name-based speaker recognition (Phase 1)

Phase 1 is implemented as three new/changed pieces that do **not** touch
`MeetingController`:

- `Sources/Notable/Meeting/SpeakerNameResolver.swift` — pure `applyMapping` +
  async `resolve`.
- `Sources/Notable/Calendar/CalendarMonitor.swift` — `EventMatch.attendeeNames`
  populated from EventKit.
- `SummarizationProvider.complete(system:user:)` + `SummarizationService.complete(…)`
  — the text round-trip the resolver uses (implemented by both providers).

This file is the one wiring step left: a ~4-line insert into
`MeetingController.produceNote`.

## Where to call it

`produceNote` already computes `segments` from `MeetingPipeline.process`, then
uses `segment.speaker` in three downstream places: the Markdown note, the
`RecordingStore.Segment` rows, and the summary transcript. Relabel **once**,
right after `segments` is produced, and feed the relabeled array to all three.

```swift
private static func produceNote(
    micSamples: [Float],
    systemSamples: [Float],
    startedAt: Date,
    providerID: String,
    folderURL: URL,
    event: CalendarMonitor.EventMatch?
) async throws -> NoteOutcome {
    let segments = try await Task.detached(priority: .userInitiated) {
        let transcriber = try await ParakeetModelCache.shared.transcriber()
        return try await MeetingPipeline.process(
            micSamples: micSamples,
            systemSamples: systemSamples,
            transcriber: transcriber
        )
    }.value

    // ── Phase 1: attendee-anchored speaker naming (default on) ───────────────
    // Best-effort: on any failure `resolve` returns [:], `applyMapping` is a
    // no-op, and every remote speaker stays "Sprecher n". Naming never breaks
    // the note. Only transcript text + attendee names leave the device.
    let named: [MeetingTranscriptSegment]
    if UserDefaults.standard.object(forKey: "speakerNamingEnabled") as? Bool ?? true {
        let mapping = await SpeakerNameResolver.resolve(
            segments: segments,
            attendees: event?.attendeeNames ?? [],
            providerID: providerID
        )
        named = SpeakerNameResolver.applyMapping(segments, mapping: mapping)
    } else {
        named = segments
    }
    // ─────────────────────────────────────────────────────────────────────────

    let duration = Double(max(micSamples.count, systemSamples.count))
        / Double(PCMDownsampler.targetSampleRate)
    let title = event?.title ?? "Meeting"

    var note = MarkdownProjector.Note(
        title: title,
        date: startedAt,
        calendarEventTitle: event?.title,
        segments: named.map { ($0.speaker, $0.text) },   // ← named
        summary: nil
    )

    // …file write unchanged…

    let recording = RecordingStore.Recording(/* …unchanged… */)
    try await RecordingStore.shared.insertMeeting(
        recording,
        segments: named.map {                            // ← named
            RecordingStore.Segment(speaker: $0.speaker, start: $0.start, end: $0.end, text: $0.text)
        }
    )

    // …summary block unchanged except the transcript source…
    let transcriptText = named                            // ← named
        .map { "\($0.speaker ?? "Unbekannt"): \($0.text)" }
        .joined(separator: "\n")
    // …rest of produceNote unchanged (context, summarize, RetryPayload)…
}
```

The only diff is: insert the `named` block, then replace the three `segments.map`
/ transcript uses (`note.segments`, `RecordingStore.Segment`, `transcriptText`)
with `named`. Everything downstream keys off `segment.speaker` as a free string,
so Markdown, SQLite, search, and the summary input all get the real names with
no further change. The retry path keeps working: `RetryPayload.transcript`
already carries the resolved-name transcript, so a summary re-run reuses the
same names.

## How attendees flow

`CalendarMonitor.currentEvent` now fills `EventMatch.attendeeNames` from
`EKEvent.attendees` (self, rooms/resources, and bare email addresses filtered;
deduplicated). That `EventMatch` is already carried through `stop()` into
`produceNote(… event:)`, so `event?.attendeeNames` needs no plumbing changes.

Crash-recovery reconstructs `EventMatch` from `SpoolStore.Meta` (title + id
only), so recovered meetings run with an **empty** attendee pool
(`attendeeNames` defaults to `[]`). That is acceptable: the resolver still works
from in-transcript self-introductions and direct address, just without spelling
correction from the candidate list. (Persisting attendees into `SpoolStore.Meta`
is a later, optional refinement — not required for Phase 1.)

## Gating & guarantees

- **Flag:** `speakerNamingEnabled` in `UserDefaults`, **default on** (absent key
  ⇒ `true`). Add a Settings toggle bound to the same key when desired.
- **Conservatism (a wrong name is worse than `Sprecher n`):**
  - `"Ich"` is never renamed — enforced in the system prompt *and* by
    `validated` (rejects any mapping with an `"Ich"` key or an `"Ich"` target).
  - Attendee-only guesses are rejected: strict verbatim mode (on by default)
    drops any name not attested in the transcript text.
  - Name collisions (two labels → one name) reject the **whole** mapping.
  - Unknown labels in the reply are ignored.
  - Any provider/parse/validation failure ⇒ `[:]` ⇒ untouched `"Sprecher n"`.
- **Privacy:** only transcript text and attendee first names leave the device —
  the same boundary summarization already crosses. No audio, no embeddings.
