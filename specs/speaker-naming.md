# Spec: Name-based speaker recognition for meeting transcripts

Status: proposal / research. No production code yet.
Author: research pass, 2026-07-18.
Scope reminder: personal tool, single user, on-device audio (see `CLAUDE.md`). Audio must never leave the device. Only transcript **text** may go to a summarization provider — that boundary is load-bearing and this spec preserves it.

## Goal

Today remote speakers are labeled `Sprecher 1 / Sprecher 2 / …` (the local user is always `Ich`). What is wanted are **real names** in the transcript and summary when names are recoverable from context — self-introductions ("Hi, ich bin Anna"), addressing ("Danke, Anna", "Was meinst du, Tom?"), or the calendar attendee list. The label→name mapping is per-meeting; the *same* physical person may be `Sprecher 2` in one meeting and `Sprecher 1` in the next, so any naming must be re-derived per meeting (unless we go to persistent voice-prints, option C).

---

## 1. Current diarization + labeling flow (precise)

The label is minted in exactly one place and flows outward unchanged.

- **Diarization → raw speaker IDs.** `MeetingPipeline.process` (`Sources/Notable/Meeting/MeetingPipeline.swift:103`) VAD-compacts the system track, diarizes the compacted signal with FluidAudio `DiarizerManager.performCompleteDiarization` (`:155`), and maps segments back to the original timeline (`:156-162`). Each system segment carries `segment.speakerId` — an opaque cluster id like `"1"`, `"2"` assigned by pyannote.
- **Label minting.** `orderedSpecs` (`:27`) turns those into display labels:
  - mic segments → `speaker: "Ich"` (`:33`)
  - system segments → `speaker: "Sprecher \($0.speakerID)"` (`:36`)
  This is the *only* line where `"Sprecher n"` is created.
- **Grouping / transcription.** `groupedSpecs` (`:54`) merges consecutive same-speaker turns; `process` then slices audio per spec, runs Parakeet, polishes, and emits `MeetingTranscriptSegment { speaker, start, end, text }` (`:4`, appended `:183`).
- **Note + persistence.** `MeetingController.produceNote` (`Sources/Notable/Meeting/MeetingController.swift:313`):
  - builds the Markdown note segments `segments.map { ($0.speaker, $0.text) }` (`:341`),
  - writes Markdown via `MarkdownProjector.render` which prints `**\(speaker):** text` (`Sources/Notable/Storage/MarkdownProjector.swift:43-47`),
  - persists to SQLite as `RecordingStore.Segment(speaker:…)` (`:363`), column `segments.speaker TEXT` (`Sources/Notable/Storage/RecordingStore.swift:247-255`),
  - builds the summarization input as `"\($0.speaker ?? "Unbekannt"): \($0.text)"` joined by newlines (`:374-376`), and calls `SummarizationService.summarize` (`:379`).
- **Summarization.** `SummarizationPrompt` (`Sources/Notable/Summarization/SummarizationProvider.swift:44-72`) sends transcript text only. The prompt does not currently mention speakers or names.

**Calendar context available today:** `CalendarMonitor.EventMatch` carries only `title` + `eventIdentifier` (`Sources/Notable/Calendar/CalendarMonitor.swift:8-11`). Attendees are **not** currently read — `EKEvent.attendees` (`[EKParticipant]`, each with `.name`) is available under the already-granted full-access EventKit permission but is discarded in `currentEvent` (`:38-45`). No code in `Sources/` touches `attendee`/`EKParticipant` today (verified by grep).

**FluidAudio capability (for option C):** `Speaker` is a `Codable` class with a 256-dim L2-normalized `currentEmbedding`, `name`, and `rawEmbeddings`; `SpeakerManager.initializeKnownSpeakers([...])` pre-loads known profiles for recognition; `SpeakerUtilities.cosineDistance` compares embeddings. So persistent voice-prints are supported by the library we already ship (`build/SourcePackages/checkouts/FluidAudio/Documentation/Diarization/SpeakerManager.md`).

---

## 2. Approaches, ranked by on-device feasibility

### A. Calendar attendees as a name pool + heuristic assignment

Read `EKEvent.attendees` → candidate names, then try to bind clusters to names by rule (e.g. count clusters, if #clusters == #remote attendees and only one plausible ordering…). 

- **Pros:** cheap, fully local, no extra model, gives the LLM a candidate list.
- **Cons:** heuristics alone cannot decide *which* cluster is *which* attendee. Attendee lists are frequently wrong for the purpose: optional/absent invitees, room resources, mailing lists, "Anna Schmidt (Guest)", or just email addresses with no `.name`. Heuristic cluster→name binding with no acoustic or textual evidence is a coin flip for ≥2 remote speakers.
- **Verdict:** valuable **as an input to B**, not as a standalone assigner. Use attendees as the *candidate pool*, never as a direct positional map.

### B. LLM name attribution as a post-processing pass (RECOMMENDED FIRST)

The diarized transcript already reads `Sprecher 1: …` / `Sprecher 2: …`. The summarization LLM (Sonnet 5 via API, or Claude Max via CLI — both already wired) is very good at reading conversational cues ("Ich bin Anna", "Danke, Tom") and resolving `Sprecher n → name`. Do this as an explicit, **conservative** relabeling step whose output is a strict mapping, not free-form rewriting.

- **Pros:** no new model, no audio leaves device (only text, which already leaves for summarization), reuses existing provider plumbing, handles the actual signal humans use (what was *said*). Calendar attendees feed in as a candidate list to anchor spellings ("tom" → "Tom Berger").
- **Cons:** costs one extra LLM call (or fold into the summary call), can hallucinate a mapping. Mitigated by: require evidence, allow "unknown", return structured JSON we validate before applying.
- **Verdict:** best effort/reward ratio. **Phase 1.**

Two sub-options for *where* it runs:

- **B1 — separate mapping call (preferred).** One deterministic call: input = the `Sprecher n` transcript + attendee candidate pool; output = strict JSON `{"Sprecher 1":"Anna","Sprecher 2":null}`. We validate and apply the mapping ourselves (relabel segments in `MeetingTranscriptSegment` before Markdown/SQLite/summary). Keeps the summary prompt untouched, keeps naming auditable and testable, and lets us persist the mapping. `Ich` is never remapped.
- **B2 — fold into summary prompt.** Tell the summarizer "if you can identify a speaker's real name from context, use it." Cheaper (no extra call) but uncontrolled: the transcript stored in SQLite/Markdown still says `Sprecher n`, only the summary uses names → inconsistent, and we can't validate. Rejected as the primary path; acceptable only as a fallback if the extra call is deemed too costly.

### C. Voice-print enrollment (persistent named embeddings)

Enroll known people once (record a sample, or confirm a name in a past meeting), store their 256-dim `Speaker` embedding, and on each meeting call `SpeakerManager.initializeKnownSpeakers([...])` so the diarizer emits the *name* as the cluster id directly; unknown voices stay `Sprecher n`.

- **Pros:** works even when no name is spoken, stable identity across meetings, purely local, library already supports it (`Speaker: Codable`, `initializeKnownSpeakers`, `cosineDistance`).
- **Cons:** real enrollment UX (record/confirm/manage/delete people, a privacy-sensitive biometric store), and our pipeline deliberately diarizes the **VAD-compacted** track, so embeddings are computed on compacted audio — enrollment must use the same path to be comparable. Threshold tuning is finicky; a wrong match is a confident wrong name. Meaningful effort.
- **Verdict:** highest quality ceiling, highest cost. **Phase 3, only if B proves insufficient.** Note synergy: once B has confirmed "Sprecher 2 = Anna" in a meeting and the user accepts it, we already hold Anna's embedding from that meeting — that's a zero-extra-UX enrollment path into C later.

**Ranking:** B (attendee-anchored LLM relabel) > A (as B's input only) > C (persistent voice-prints).

---

## 3. Recommended phased approach

- **Phase 1 — Attendee-anchored LLM relabel (B1 + A pool).** Read attendees, run one strict-JSON mapping call, validate, apply to segments before persistence. Feature-flag it (default on). This is the whole ask for most meetings.
- **Phase 2 — Persist + let the user correct.** Store the per-meeting `speaker_id → name` mapping in SQLite; expose a tiny correction affordance (edit a name, re-project Markdown + re-summarize from stored segments). User corrections are the ground truth that a wrong LLM guess needs.
- **Phase 3 — Voice-prints (C), optional.** Only if Phase 1/2 leave too many `Sprecher n`. Seed enrollment from Phase 2 confirmations to avoid a cold-start enrollment UI.

---

## 4. Files to change, data model, prompt/algorithm design

### 4.1 New: name-resolution step (pure + provider call)

New file `Sources/Notable/Meeting/SpeakerNameResolver.swift`:

- Pure part (unit-testable, no I/O): `applyMapping(_ segments:[MeetingTranscriptSegment], mapping:[String:String]) -> [MeetingTranscriptSegment]` — replaces `speaker` where a validated name exists, never touches `Ich`, never touches a label absent from the mapping.
- Provider part: `resolveNames(transcript:[MeetingTranscriptSegment], candidates:[String], provider:) async -> [String:String]` — builds the prompt, calls the chosen `SummarizationProvider` (new protocol method, see 4.4), parses/validates JSON, returns only high-confidence entries. Best-effort: any failure returns `[:]` and the pipeline proceeds with `Sprecher n` (naming must never break a note — mirror the existing summary-failure philosophy in `produceNote`).

### 4.2 Calendar: expose attendees

`Sources/Notable/Calendar/CalendarMonitor.swift`:

- Add `var attendeeNames: [String]` to `EventMatch` (`:8`).
- In `currentEvent` (`:30`), map `candidate.attendees?.compactMap { $0.name }`, drop the current user, drop entries that are bare email addresses / look like room resources, dedupe. Keep it defensive: attendees may be `nil`.
- `SpoolStore.Meta` (referenced `MeetingController.swift:104-109`) and crash-recovery reconstruction (`:237-239`) should carry attendee names too, so recovered meetings still get the candidate pool. (If deferring, recovery simply runs with an empty pool — acceptable.)

### 4.3 Wire into the pipeline

`Sources/Notable/Meeting/MeetingController.swift` `produceNote` (`:313`), **after** `MeetingPipeline.process` returns `segments` and **before** Markdown/SQLite/summary:

```
let candidates = event?.attendeeNames ?? []
let mapping = await SpeakerNameResolver.resolveNames(
    transcript: segments, candidates: candidates, provider: providerID)  // best-effort, [:] on failure
let named = SpeakerNameResolver.applyMapping(segments, mapping: mapping)
// use `named` for note.segments (:341), RecordingStore.Segment (:363), and the summary transcript (:374)
```

Everything downstream already keys off `segment.speaker` as a free string, so once relabeled, Markdown, SQLite, search, and the summary input all get names with no further change. The summary transcript builder (`:374-376`) stays as-is (it just sees names instead of `Sprecher n`).

### 4.4 Provider protocol

`Sources/Notable/Summarization/SummarizationProvider.swift`: add a second method to `SummarizationProvider` (or a sibling protocol) for a raw structured call, e.g. `func complete(system:String, user:String) async throws -> String`, implemented by both `AnthropicAPIProvider` and `ClaudeCodeCLIProvider` (they already do exactly this internally). The name resolver uses it; `summarize` stays untouched. Keep the CLI tool-lockdown (`ClaudeCodeCLIProvider.swift:18`) and API retry logic — reuse, don't fork.

### 4.5 Data model (persist the mapping — Phase 2)

- Keep `segments.speaker` holding the **resolved** name (so search/Markdown already benefit). 
- Add a `speaker_names` table to persist provenance and enable correction/re-projection:
  ```sql
  CREATE TABLE IF NOT EXISTS speaker_names (
      recording_id TEXT NOT NULL REFERENCES recordings(id),
      cluster_label TEXT NOT NULL,   -- "Sprecher 1"
      name TEXT,                     -- "Anna", NULL if unresolved
      source TEXT NOT NULL,          -- 'llm' | 'attendee' | 'user' | 'voiceprint'
      confidence REAL,
      PRIMARY KEY (recording_id, cluster_label)
  );
  ```
  Add schema in `RecordingStore.ensureOpen` (`:235`) as a `CREATE TABLE IF NOT EXISTS` (no migration needed — additive). Insert inside the existing `insertMeeting` transaction (`:107`). `source` lets a later `'user'` correction always win over `'llm'`.
- Storing `cluster_label` (not just the resolved name) is what makes Phase 3 voice-print seeding and user re-correction possible.

### 4.6 Prompt design (B1 mapping call)

System:
```
Du ordnest anonyme Sprecher-Labels echten Namen zu. Du bekommst ein Meeting-Transkript,
in dem Sprecher als "Sprecher 1", "Sprecher 2" … erscheinen (der Aufnehmende ist "Ich"),
und optional eine Liste eingeladener Teilnehmer.
Ordne einem Label NUR dann einen Namen zu, wenn das Transkript dafür klare Evidenz liefert:
- Selbstvorstellung ("ich bin/heiße X", "hier spricht X"),
- direkte Anrede ("Danke, X", "Was meinst du, X?"),
- eindeutige Nennung, die genau einem Sprecher zugeordnet werden kann.
Rate NICHT. Ordne einem Label NIE einen Namen nur deshalb zu, weil er in der Teilnehmerliste steht.
"Ich" bleibt immer "Ich" und wird nie umbenannt.
Nutze die Teilnehmerliste nur, um die Schreibweise eines im Transkript belegten Namens zu korrigieren.
Antworte AUSSCHLIESSLICH mit JSON: { "Sprecher 1": "Anna", "Sprecher 2": null }.
Jedes Label aus dem Transkript muss als Schlüssel vorkommen; ohne Evidenz ist der Wert null.
```
User: the attendee candidate list (or "keine") + the `Sprecher n` transcript (same builder as the summary, `:374-376`).

**Validation before applying** (in `SpeakerNameResolver`, reject the whole mapping if any check fails → fall back to `Sprecher n`):
1. Parses as JSON object of `string → string|null`.
2. Every key is a label that actually appears in this transcript; ignore unknown keys.
3. No two labels map to the same non-null name (a collision means the model guessed).
4. Never maps `Ich`.
5. Optional strict mode: require the resolved name to appear verbatim in the transcript text (defends against pure invention).

Algorithm is deterministic given the model output; the pure `applyMapping` + validation are unit-testable without a live model (mirror `MeetingConversationTests` / `MeetingPipelineTests` style).

---

## 5. Failure modes & staying conservative

Core principle: **a wrong name is worse than `Sprecher n`.** `Sprecher 2` is honestly anonymous; "Anna" attached to Tom's words is a confidently wrong record the user may quote back. Every design choice biases toward leaving a label anonymous.

- **Hallucinated name / wrong binding.** → require in-transcript evidence, forbid attendee-only assignment, reject on name collisions, prefer `null`. Strict mode requires the name to appear verbatim.
- **Diarization already wrong (two people merged into one cluster, or one person split).** Naming cannot fix upstream clustering; a merged cluster given one name is *more* misleading. Keep clusters the diarizer is unsure about anonymous — consider only naming clusters with sufficient total speech duration.
- **`Ich` contamination.** Never remap `Ich`; the model is told and validation enforces it.
- **Attendee list noise** (rooms, absentees, email-only). → attendees are candidates only, never a positional map; filter obvious non-persons.
- **Provider/network failure.** → best-effort: return `[:]`, keep `Sprecher n`, never block or fail the note (same stance as summary failure in `produceNote`).
- **Privacy.** Only transcript text + attendee first names leave the device — no new data class crosses the boundary. Voice-prints (C) never leave the device and need explicit enrollment consent.
- **Non-determinism across re-summarize/retry.** Persist the mapping (4.5) and reuse it on retry so a note doesn't rename people between runs; `'user'` source always wins.

---

## 6. Open decisions, acceptance criteria, effort

### Open decisions
1. **Extra call vs. folded?** B1 (separate validated mapping call, one extra LLM round-trip per meeting) vs. B2 (fold into summary, transcript stays `Sprecher n`). Recommendation: B1.
2. **Strict verbatim mode on by default?** Safer, but drops names the model inferred via pronoun/context. Recommendation: on.
3. **Attendee reading scope** — read attendees at all in Phase 1, or ship LLM-only first and add the candidate pool second? (Attendees add EventKit surface + PII handling.)
4. **Correction UX (Phase 2)** — is a name-edit affordance wanted, or is auto-naming + manual Markdown edit enough for a personal tool?
5. **Voice-prints (Phase 3)** — pursue at all? It introduces a biometric store and enrollment UX into a deliberately minimal app.
6. **Label language** — keep German `Sprecher n` as the anonymous fallback (yes, matches the German-only summaries).

### Acceptance criteria
- With a scripted 2-remote-speaker clip containing one self-intro and one direct address, both are correctly named in Markdown, SQLite, and summary; no `Sprecher n` remains for those two.
- A clip with **no** name cues leaves every remote speaker `Sprecher n` (zero invented names) — this is the most important test.
- `Ich` is never renamed.
- Provider failure yields the exact current behavior (note with `Sprecher n`, no crash).
- Mapping persisted; a summary retry reuses it (no rename between runs).
- Pure `applyMapping` + validation covered by unit tests without a live model; one E2E test with a real provider (guarded/skippable like `ClaudeCodeCLIProviderTests`).

### Effort estimate
- **Phase 1 (B1 + attendee pool):** ~1–1.5 days. New resolver file + prompt + validation (~0.5 d), provider protocol method on both providers (~0.25 d), attendee reading in `CalendarMonitor`/`EventMatch`/spool meta (~0.25 d), wire into `produceNote` (~0.1 d), tests (~0.4 d).
- **Phase 2 (persist + correct):** ~1 day (schema + insert in transaction ~0.25 d; correction/re-projection UI + re-summarize ~0.75 d).
- **Phase 3 (voice-prints):** ~3–5 days (enrollment UX, embedding store, compacted-path enrollment parity, threshold tuning, delete/manage, privacy copy). Defer.
