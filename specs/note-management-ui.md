# Implementation Spec — Menu-bar Note Management

Status: proposed, awaiting sign-off on the open decisions in §8.
Scope: personal tool, single user (see CLAUDE.md). German UI throughout, matching the existing app.
Audio-privacy invariant is unchanged: only transcript **text** ever leaves the device.

This spec covers five requirements:

1. A menu-bar note list with in-place **title editing** (renames the `.md`, updates SQLite + `markdown_path`, handles collisions).
2. **Auto-generated title + one-line summary** for meetings that have no calendar event.
3. **Inbox → project folder** workflow (folder model, move operation, UI).
4. **Menu-bar icon picker**.
5. **Skimmable summary** — improved prompt + Markdown layout.

---

## 1. Current state (file:line)

### Composition & menu
- `NotableApp.swift:7` `AppContainer` is the composition root; it owns `notesFolder: NotesFolderManager` (`:12`) and `meeting: MeetingController` (`:16`).
- `NotableApp.swift:60-68` the only status-item surface is a **default-style `MenuBarExtra`** rendering `MenuContentView` — a flat list of `Text`/`Button`, i.e. an AppKit menu. Arbitrary interactive SwiftUI (editable rows, popovers) is **not** possible in this style.
- `NotableApp.swift:70-74` there is already a precedent for a secondary window opened from the menu: the `Window("Notizen durchsuchen", id: "search")` scene, opened via `openWindow(id:"search")` at `NotableApp.swift:159-162`.
- `NotableApp.swift:52-58` `menuSymbol` is computed: `record.circle` while recording, `hourglass.circle` while processing, else `appState.captureState.symbolName`. The idle base symbol is therefore **hard-coded** (indirectly, via `captureState`).
- `MenuContentView` (`NotableApp.swift:86-177`) already surfaces "Letzte Notiz öffnen" (`:141`), "Notizen-Ordner öffnen" (`:154`), "Zusammenfassung nachholen" (`:147`).

### Note production & format
- `MeetingController.produceNote` (`MeetingController.swift:313-398`) is the single place a note is created. Title is `event?.title ?? "Meeting"` (`:335`) — **this is the only place the "Meeting" fallback lives**. It renders Markdown (`:349`), inserts into SQLite (`:361`), then summarizes (`:378`) and re-renders (`:385`).
- Notes are written **flat** into `folderURL` (`:346`); there is no Inbox/subfolder concept.
- `MarkdownProjector.Note` (`MarkdownProjector.swift:6-12`) carries `title, date, calendarEventTitle, segments, summary`. There is **no** subtitle/one-liner and **no** folder field.
- `MarkdownProjector.render` (`:14-53`) emits YAML front-matter (`title`, `date`, `event`, `app`) + `# title` + `## Zusammenfassung` + `## Transkript`.
- `MarkdownProjector.fileName` (`:69-79`) → `yyyy-MM-dd HH.mm <safeTitle>.md`. Collisions are avoided **only** by the `HH.mm` minute prefix; there is **no counter suffix**, so a rename to an existing name would overwrite.

### Storage (source of truth)
- `RecordingStore` (`RecordingStore.swift:9`) is an actor; `recordings` table has `id, kind, started_at, ended_at, title, calendar_event_id, markdown_path` (`:236-245`). **No** `summary`, `subtitle`, or `folder` column.
- The summary text is **NOT persisted to SQLite** — it lives only inside the `.md` file. Consequence: a note cannot currently be fully re-rendered from the DB, which blocks clean rename/move (see §3).
- Read paths today: `recentDictations` (`:122`) and `search` (`:160`) only. **No** "list recent meetings", **no** "fetch one recording + its segments", **no** update/rename methods.
- Schema is created idempotently in `ensureOpen` (`:216-258`); there is no migration mechanism yet.

### Summarization
- `SummarizationPrompt` (`SummarizationProvider.swift:44-72`) is the single shared prompt: German, three fixed sections (`## Zusammenfassung`, `## Entscheidungen`, `## Action Items`). Providers return an opaque `Summary.markdown` string.
- `MeetingContext` (`:3-7`) carries `title, date, durationSeconds`.
- Both providers (`AnthropicAPIProvider`, `ClaudeCodeCLIProvider`) return the model's raw markdown verbatim; there is no post-parse step.

### Notes folder
- `NotesFolderManager` (`NotesFolder.swift:8-41`) holds a single `folderURL` (plain path in UserDefaults, key `notesFolderPath`). `ensureExists()` creates it; `chooseFolder()` picks a new root. **No** Inbox/subfolder awareness.

---

## 2. Proposed architecture (overview)

Guiding principle from CLAUDE.md: **SQLite is the source of truth, Markdown is a projection.** Today that invariant is violated for the summary (file-only). This spec **restores** it: the DB gains `summary`, `subtitle`, `folder`, `title_is_auto` columns, so every note becomes fully re-renderable from the store. Rename, move, and re-summarize then all reduce to "mutate the row → re-project the file", which is the safe way to keep DB and disk in agreement.

New surface:

```
Sources/Notable/Notes/
  NoteManager.swift        // @MainActor coordinator: rename / move / regenerate — DB + file together
  NotesListView.swift      // the note-management UI (window scene)
  NotesFolderModel.swift   // Inbox + project-folder helpers (or fold into NotesFolderManager)
  MenuBarIcon.swift        // curated SF Symbol set + @AppStorage-backed choice
```
Everything under `Sources/Notable` is compiled into the app target automatically (`project.yml:61-62`) — no `project.yml` edit needed for app code. **Test files still need explicit paths** in the `NotableTests` sources list (`project.yml:29-50`); §7 lists them.

UI delivery: a new `Window("Notizen", id:"notes")` scene, opened from the menu — mirrors the existing search window, keeps the low-risk default-style `MenuBarExtra`. (Alternative — switching the whole `MenuBarExtra` to `.menuBarExtraStyle(.window)` — is §8 Q1.)

---

## 3. Requirement 1 — Note list + title editing

### 3.1 Storage changes (`RecordingStore.swift`)

Add a lightweight migration and new columns. In `ensureOpen`, after the `CREATE TABLE`s, call a new `migrate()`:

```swift
private func migrate() throws {
    // Idempotent: read PRAGMA table_info(recordings), ADD COLUMN for any missing.
    // New columns: subtitle TEXT, folder TEXT, summary TEXT, title_is_auto INTEGER DEFAULT 0
}
```
Columns (all nullable so existing rows migrate cleanly):
- `subtitle TEXT` — the one-line TL;DR (§4).
- `folder TEXT` — folder key relative to the notes root; `"Inbox"` for new notes, `NULL`/`""` = root (legacy flat notes).
- `summary TEXT` — the full summary markdown, so the file is re-renderable.
- `title_is_auto INTEGER DEFAULT 0` — 1 when the title was model-generated (lets the UI mark it and lets "regenerate title" know it may overwrite).

Extend `Recording` (`:15-23`) with `var subtitle: String?`, `var folder: String?`, `var summary: String?`, `var titleIsAuto: Bool = false`. Update `insert` (`:75-89`) and `insertMeeting` (`:107`) to bind them.

New methods:
```swift
/// Meeting notes (those with a markdown_path), newest first, for the list UI.
func recentNotes(limit: Int = 100) throws -> [Recording]

/// One recording plus its ordered segments — enough to re-render the file.
func note(id: String) throws -> (recording: Recording, segments: [Segment])?

/// Rename: new title (+ recomputed subtitle stays) and the new file path after the move.
func updateTitle(id: String, title: String, titleIsAuto: Bool, markdownPath: String) throws

/// Move between folders: new folder key + new file path.
func updateLocation(id: String, folder: String, markdownPath: String) throws

/// Persist a (re)generated summary + subtitle + possibly auto title.
func updateSummary(id: String, summary: String, subtitle: String?, autoTitle: String?) throws
```
(`Segment` has no explicit order column; `note(id:)` should `ORDER BY start_seconds ASC, id ASC`.)

### 3.2 Rename coordinator (`Notes/NoteManager.swift`)

```swift
@MainActor
final class NoteManager: ObservableObject {
    @Published private(set) var notes: [NoteRow] = []   // view-model rows
    private let store = RecordingStore.shared
    private let notesFolder: NotesFolderManager

    func reload() async
    func rename(_ note: NoteRow, to newTitle: String) async throws
    func move(_ note: NoteRow, toFolder folder: String) async throws
    func regenerateTitleAndSummary(_ note: NoteRow) async throws   // §4/§5
}

struct NoteRow: Identifiable, Sendable {
    let id: String
    var title: String
    var subtitle: String?
    var date: Date
    var folder: String
    var markdownPath: String?
    var titleIsAuto: Bool
    var hasCalendarEvent: Bool
}
```

`rename` algorithm (order matters — file first would orphan the DB path on crash; do DB-safe sequencing):
1. Sanitize/trim `newTitle`; reject empty.
2. Compute the target URL: `dir = current file's directory` (rename keeps folder), `name = MarkdownProjector.uniqueFileName(in: dir, title: newTitle, date: note.date, excluding: currentURL)`.
3. `FileManager.moveItem(at: currentURL, to: targetURL)` (skip if same path).
4. Re-render the file body from the DB (`note(id:)` → `MarkdownProjector.Note`) with the new title so the front-matter `title:` and `# heading` update, and write to `targetURL`.
5. `store.updateTitle(id:, title: newTitle, titleIsAuto: false, markdownPath: targetURL.path)`.
6. On any file error, do **not** touch the DB; surface the error.

Manual title edits set `title_is_auto = 0` (the user has claimed it).

### 3.3 Collision handling (`MarkdownProjector.swift`)

Add, next to `fileName`:
```swift
/// Filesystem-safe, collision-free name in `directory`.
/// Appends " (2)", " (3)", … when a *different* file already owns the name.
static func uniqueFileName(in directory: URL, title: String, date: Date,
                           excluding: URL? = nil) -> String
```
Reuses the existing `fileName` sanitizer, then probes `directory` with `FileManager.fileExists`, skipping `excluding` (the file being renamed). `produceNote` (`MeetingController.swift:346`) switches to this helper too, closing the pre-existing "same title, same minute" overwrite gap.

### 3.4 UI (`Notes/NotesListView.swift`)

`List` of `NoteRow`, newest first, grouped by folder (Inbox pinned to top). Each row:
- Title (bold) — double-click or a pencil button swaps in a `TextField` bound to a draft; Return commits `NoteManager.rename`, Esc cancels.
- Subtitle (secondary, one line) + date.
- A ⋯ menu: **Öffnen** (`NSWorkspace.open`), **Verschieben nach ▸** (project folders + "Neuer Ordner…"), **Titel & Zusammenfassung neu erzeugen**, **Im Finder zeigen**.
- Badge when `titleIsAuto` (e.g. a small "auto" tag) so it is clear which titles the model wrote.

Opened via a new menu item in `MenuContentView` ("Notizen verwalten…", near `:159`) and a new `Window("Notizen", id:"notes")` scene in `NotableApp.body` (mirror `:70-74`). `NoteManager` joins `AppContainer` (`NotableApp.swift:16`) and is injected as an `environmentObject`.

---

## 4. Requirement 2 — Auto title + one-liner

Today `title = event?.title ?? "Meeting"` (`MeetingController.swift:335`) and there is no subtitle.

### Design
Fold title + one-liner generation into the **existing** summarization call (§5 prompt already sends the full transcript — a second model call would double the cost for no reason). The model returns a small machine-readable header ahead of the prose, which a parser splits off:

```
TITLE: Sprint-Planung Q3
TLDR: Backlog für Sprint 24 priorisiert; API-Migration auf August verschoben.
---
## Überblick
…
```

New type + parser (in `Summarization/`):
```swift
struct MeetingSummary: Sendable {
    var title: String?     // nil when a calendar title should win
    var oneLiner: String?  // subtitle
    var markdown: String   // body only (header stripped)
}
enum SummaryParser {
    static func parse(_ raw: String) -> MeetingSummary   // tolerant: missing header ⇒ all-markdown
}
```
`SummarizationService.summarize` returns `MeetingSummary` (or an overload does), leaving the provider protocol untouched — providers still return an opaque markdown string; parsing happens one layer up.

`produceNote` changes:
- Always request title+TLDR in the prompt.
- `finalTitle = event?.title ?? parsed.title ?? "Meeting"` — a real calendar title always wins; the model only fills the gap the "Meeting" fallback used to. Set `title_is_auto = (event == nil && parsed.title != nil)`.
- Persist `subtitle = parsed.oneLiner`, `summary = parsed.markdown` to the new columns.
- Because the title may now be known only **after** summarization, but the transcript file is written **before** (to survive a summary failure, `:345-349`): write the file first with the provisional title (`event?.title ?? "Meeting"`), and if summarization then yields an auto title, re-render + rename via the §3 path. On summary failure the note simply keeps "Meeting" and stays retryable (existing `summaryRetry` flow, `:369-389`).

Trigger scope: **meetings only, and only when `event == nil`** (§8 Q2 asks whether a manual "regenerate" for calendar-titled notes is also wanted — the UI affordance in §3.4 supports it regardless).

---

## 5. Requirement 3 — Inbox → project folder

### Folder model
Notes root (`NotesFolderManager.folderURL`) gains structure:
```
<root>/
  Inbox/                 ← every new note lands here
  <Project A>/           ← user-created project folders
  <Project B>/
```
- `folder` column stores the **key** (`"Inbox"`, `"Project A"`, or `""`/NULL for legacy root notes) — path-independent, so moving the root doesn't invalidate rows.
- Legacy flat notes stay at the root (`folder = NULL`); they are shown under an "Ohne Ordner" group. Migrating them into Inbox is §8 Q3 (recommend: leave them, only new notes use Inbox).

### `NotesFolderManager` additions (`NotesFolder.swift`)
```swift
var inboxURL: URL { folderURL.appendingPathComponent("Inbox", isDirectory: true) }
func url(forFolder key: String) -> URL          // "" / "Inbox" / "<Project>"
func ensureInboxExists() throws
func projectFolders() -> [String]               // subdirs of root except Inbox, sorted
func createProjectFolder(named: String) throws  // sanitized; rejects reserved "Inbox"
```
`ensureExists()` also creates `Inbox/`.

### Note production
`produceNote` (`MeetingController.swift:346`) writes into `notesFolder.inboxURL` instead of `folderURL`, and records `folder = "Inbox"` in the new column. `ensureInboxExists()` is called alongside the existing `ensureExists()` (`:179, :233`).

### Move operation (`NoteManager.move`)
1. `dest = notesFolder.url(forFolder: folder)`; `try FileManager.createDirectory(dest)`.
2. `target = dest / MarkdownProjector.uniqueFileName(in: dest, title:, date:)`.
3. `FileManager.moveItem(currentURL → target)`.
4. `store.updateLocation(id:, folder:, markdownPath: target.path)`.
File content is unchanged by a move (title/date identical); no re-render needed, but re-render is harmless and keeps one code path.

### UI
The row's **Verschieben nach ▸** submenu lists `projectFolders()` + `Inbox` (when not already there) + **Neuer Ordner…** (a small sheet with a `TextField`, calls `createProjectFolder`). The list groups notes by folder with Inbox pinned first.

---

## 6. Requirement 4 — Menu-bar icon picker

### Storage
`@AppStorage("menuBarIconSymbol")` (default e.g. `"waveform"`). One key, no Keychain, no per-state config.

### Model (`Notes/MenuBarIcon.swift`)
```swift
enum MenuBarIcon: String, CaseIterable, Identifiable {
    case waveform, mic, noteText = "note.text", bubble = "bubble.left.and.text.bubble.right",
         recordCircle = "record.circle", sparkles /* … curated set, §8 Q4 */
    static let storageKey = "menuBarIconSymbol"
    var symbolName: String { rawValue }
    var label: String { … }   // German
}
```

### Application (`NotableApp.swift:52-58`)
`menuSymbol` keeps state precedence but reads the chosen symbol for the idle base:
```swift
private var menuSymbol: String {
    switch meeting.state {
    case .recording:  "record.circle"
    case .processing: "hourglass.circle"
    case .idle:
        appState.captureState == .idle
            ? (UserDefaults.standard.string(forKey: MenuBarIcon.storageKey) ?? "waveform")
            : appState.captureState.symbolName   // dictation activity still shows through
    }
}
```
Recording/processing/active-dictation states **keep** their fixed status icons — those communicate state and must not be user-overridable. Only the truly-idle base symbol is the user's choice.

### UI
A `Picker` (or a small symbol grid) in `GeneralSettingsView` (`SettingsView.swift:24-73`), each option rendered with `Label(icon.label, systemImage: icon.symbolName)`. `MenuBarExtra`'s `systemImage` re-reads on the next menu open; if live update is wanted, back `menuSymbol` with an `@AppStorage` in the `App` struct so SwiftUI re-renders immediately.

---

## 7. Requirement 5 — a skimmable summary

> **What a good meeting note looks like.** The spine is **Summary → Decisions → Action items → Open questions → Next steps**. The qualities worth designing for: **skimmable**, **bullet-heavy (fragments, not prose)**, terse and editorialized ("reads like a careful human notetaker, not a transcript"), bold section headers with called-out key terms, and **empty sections omitted**. Action items follow a canonical shape — **a specific task, a single owner, a clear deadline** — e.g. `@Sarah — Share revised scope — Fri`. **No timestamps** in the note; they belong to the transcript. Titles, when no calendar event exists, are a short noun phrase (~3–7 words) from the transcript's dominant topic, falling back to "Meeting on {date}". The list view shows a **one-line ≤15-word TL;DR** per note for scanning.

### 7.1 New prompt (`SummarizationPrompt.system`, `SummarizationProvider.swift:45-59`)

Replace the three-section prompt with a skimmable, still-German, still-transcript-only prompt that also emits the TITLE/TLDR header (§4):

```
Du erstellst hochgradig überfliegbare Meeting-Notizen aus einem Transkript.
Antworte ausschließlich auf Deutsch. Beginne mit genau diesem Kopf:

TITLE: <kurze Substantivphrase, die das Meeting benennt, max. 6 Wörter>
TLDR: <ein einzelner Satz, der das Wichtigste zusammenfasst>
---

Danach ausschließlich Markdown. Nutze diese Abschnitte in dieser Reihenfolge und
LASSE LEERE ABSCHNITTE WEG (nur „Entscheidungen“ und „Action Items“ immer zeigen,
dort „Keine.“ falls leer):

## Überblick
(2–4 knappe Bullets, die den gesamten Verlauf abdecken — auch die Mitte; kein Fließtext)

## Themen
(pro Thema ein **fett** gesetztes Stichwort, darunter 1–3 Unterbullets — weglassen falls dünn)

## Entscheidungen
(Bullets; **fett** die eigentliche Entscheidung; „Keine.“ falls keine)

## Action Items
- [ ] @<Verantwortliche:r> — <konkrete Aufgabe> — **<Frist, falls genannt>**
(eine Aufgabe, ein:e Verantwortliche:r, eine Frist pro Zeile; „Keine.“ falls keine)

## Offene Fragen
(Bullets; weglassen, falls keine)

## Nächste Schritte
(Bullets; weglassen, falls keine)

Regeln: knappe Bullet-Fragmente statt Sätzen, zentrale Begriffe **fett**,
erfinde nichts, was nicht im Transkript steht, keine Zeitstempel,
kein Vorwort, kein Nachwort. Der/die Sprecher heißen „Ich“ und „Sprecher n“ —
verwende diese Namen als Verantwortliche.
```

### 7.2 Markdown layout (`MarkdownProjector.render`, `MarkdownProjector.swift:14-53`)
- Front-matter gains `subtitle:` (the TLDR) so file and DB agree.
- Body order: `# <title>` → participant line + one-line **TL;DR** in italics (the gist for the list view) → the model's block stored verbatim as `summary` (`## Überblick / ## Themen / ## Entscheidungen / ## Action Items / ## Offene Fragen / ## Nächste Schritte`, empty sections already omitted by the prompt) → `## Transkript` (unchanged, `:39-50`).
- `## Zusammenfassung` heading (`:33`) is retired in favor of the richer blocks. `MarkdownProjectorTests` updates accordingly.

Privacy: unchanged — the prompt receives only the transcript text; no audio, no calendar body, no attendee list beyond what was spoken. The speaker labels ("Ich", "Sprecher n") are already what the pipeline produced (`MeetingController.swift:374`), so no new identity leaves the device.

---

## 8. Open decisions

- **Q1 — UI surface.** Preferred: a dedicated `Window("Notizen", id:"notes")` opened from the menu (low risk, mirrors search). Alternative: convert the whole `MenuBarExtra` to `.menuBarExtraStyle(.window)` and put the list directly in the popover (richer, but rebuilds the entire existing menu). Which?
- **Q2 — Auto-title trigger.** Confirm: generate a title only when there is **no** calendar event. Should a manual "Titel neu erzeugen" also be offered for calendar-titled notes (the model title would then just populate the subtitle)?
- **Q3 — Folder structure & legacy notes.** Confirm the `Inbox/ + <project>/` layout under the existing notes root. Leave existing flat notes at the root ("Ohne Ordner"), or migrate them into `Inbox/` on first launch? Nested project folders (sub-subfolders), or one flat level only?
- **Q4 — Icon set.** Which SF Symbols in the curated picker? Proposed: `waveform, mic, note.text, bubble.left.and.text.bubble.right, record.circle, sparkles`. Also allow the recording/processing icons to be user-overridden, or keep them fixed (recommended: fixed)?
- **Q5 — Summary language/format.** Keep German output and the section names in §7.1? Any sections to add/drop (e.g. a "Nächstes Meeting"/"Risiken" block)?
- **Q6 — DB as full source of truth.** OK to add `summary`/`subtitle`/`folder`/`title_is_auto` columns so notes are fully re-renderable from SQLite (restores the stated invariant)? This is the clean foundation for rename/move/re-summarize.

---

## 9. Acceptance criteria

1. **Note list**: opening "Notizen verwalten…" shows every meeting note newest-first, grouped by folder, each with title, one-liner, date.
2. **Rename**: editing a title renames the `.md` on disk, rewrites its front-matter `title:` and `# heading`, updates `recordings.title` + `markdown_path`; a name clash yields `… (2).md`, never an overwrite; the DB is untouched if the file move fails.
3. **Auto title**: a meeting with no calendar event gets a concise model title (not "Meeting") and a one-line subtitle; a calendar-titled meeting keeps its calendar title; a summary failure leaves a retryable "Meeting" note (existing flow intact).
4. **Inbox/move**: new notes are written under `Inbox/` with `folder="Inbox"`; moving a note relocates the file into the chosen project folder and updates `markdown_path` + `folder`; "Neuer Ordner…" creates a folder under the root.
5. **Icon picker**: choosing a symbol in Settings changes the idle menu-bar icon; recording/processing/active-dictation icons are unaffected; the choice survives relaunch.
6. **Summary quality**: a real transcript produces the §7 structured, bulleted, skimmable Markdown with owned action items; only transcript text is sent to the provider.
7. **Tests**: `MarkdownProjectorTests` covers `uniqueFileName` collisions + new layout; a new `SummaryParserTests` covers header parsing (present/missing/partial); a `RecordingStore` migration test asserts the new columns exist and old rows load; existing 35 tests stay green.
8. Idle CPU/RSS unchanged (no new timers/warm state).

---

## 10. Files to add / change

**Add** (auto-compiled; no `project.yml` change for app code):
- `Sources/Notable/Notes/NoteManager.swift` — rename/move/regenerate coordinator + `NoteRow`.
- `Sources/Notable/Notes/NotesListView.swift` — the window UI.
- `Sources/Notable/Notes/MenuBarIcon.swift` — curated symbol set + storage key.
- `Sources/Notable/Summarization/SummaryParser.swift` — `MeetingSummary` + `SummaryParser`.
- `Tests/NotableTests/SummaryParserTests.swift`, `Tests/NotableTests/NoteManagerTests.swift` (or extend existing) — **need explicit paths added to `project.yml:29-50`**, then `xcodegen generate`.

**Change**:
- `RecordingStore.swift` — migration + new columns on `Recording`, `recentNotes`, `note(id:)`, `updateTitle`, `updateLocation`, `updateSummary`.
- `MarkdownProjector.swift` — `uniqueFileName`, `Note.subtitle`, new §7.2 layout.
- `MeetingController.swift` — write into Inbox, parse `MeetingSummary`, set auto title/subtitle/summary columns, rename-on-auto-title.
- `NotesFolder.swift` — Inbox + project-folder helpers.
- `SummarizationProvider.swift` — new prompt + TITLE/TLDR header; `MeetingContext` unchanged.
- `SummarizationService.swift` — return/parse `MeetingSummary`.
- `NotableApp.swift` — `NoteManager` in `AppContainer`, `notes` window scene, "Notizen verwalten…" menu item, icon-aware `menuSymbol`.
- `SettingsView.swift` — icon picker in `GeneralSettingsView`.
- `project.yml` — add the two new test-file paths only.

---

## 11. Effort estimate

| Area | Est. |
|---|---|
| Storage: migration + columns + read/update methods | 0.5 day |
| `NoteManager` (rename/move/regenerate) + collision helper | 0.5 day |
| `NotesListView` + window scene + menu wiring | 1 day |
| Auto title/one-liner: prompt header + `SummaryParser` + `produceNote` wiring | 0.5 day |
| Inbox/project folders: `NotesFolderManager` + move UI | 0.5 day |
| Icon picker (model + Settings + `menuSymbol`) | 0.25 day |
| Summary prompt + `MarkdownProjector` layout | 0.5 day |
| Tests (parser, migration, collisions, layout) | 0.5 day |
| **Total** | **≈ 4.25 dev-days** |

Sequencing: land §3.1 storage migration first (everything depends on it), then §4/§5 (produceNote path), then §3/§5 UI, then §6 (independent, can slot anywhere).
