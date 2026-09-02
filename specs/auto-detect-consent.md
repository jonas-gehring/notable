# Spec: Consent step before auto-recording a detected meeting

Status: proposal (not yet implemented)
Scope: personal tool, single user (see `CLAUDE.md` → "Scope"). No multi-user plumbing.

## 1. Problem & goal

Today, when a call app plus mic activity is detected, Notable starts recording the
meeting **silently and automatically**. What is wanted instead is an explicit, low-friction
consent gate: on detection, show a non-intrusive prompt asking
**"Diesen Call transkribieren?"** with **Ja / Nein** (and ideally
**"Immer für diese App"**). Recording starts **only on Ja**.

Hard constraint (from `CLAUDE.md` and `DictationOverlay.swift`): the app is a menu-bar
`LSUIElement`; the consent surface **must never become key/main**. If any Notable
window becomes key, the dictation paste-into-focused-field mechanic breaks (the
overlay is deliberately a `.nonactivatingPanel` that is only ever
`orderFrontRegardless()`, never `makeKey`).

## 2. Current detection flow (precise, cited)

All line numbers are as of this spec against the files below.

- **Poll loop.** `MeetingDetector.start(pollInterval:)` schedules a repeating 5 s timer
  (`MeetingDetector.swift:84-91`) that calls `poll()` (`:98-118`).
- **Signals per tick.** `poll()` computes `candidate = detectCandidate()` (`:99`) and
  `micActive = !isOwnCaptureActive() && isDefaultInputRunningSomewhere()` (`:100`).
  - `detectCandidate()` (`:122-132`) returns a `Candidate` by priority: a running
    *dedicated* app (`us.zoom.xos`, `com.microsoft.teams2`/`teams`, FaceTime, Webex),
    then a *browser* Meet/Zoom/Teams window title (`detectBrowserMeeting()` `:138-160`,
    needs Screen Recording TCC to read titles), then the *ambient* app Slack.
  - `Candidate` today carries only `sourceName: String` (`:53-55`) — a display string
    like `"Zoom"` or `"Google Meet (Google Chrome)"`.
  - `isOwnCaptureActive` is injected in `NotableApp.swift:28-30` as
    `appState.captureState != .idle || meeting.state != .idle` — this is why the mic
    signal is ignored once *we* record.
- **Fusion / debounce.** `poll()` calls
  `stateMachine.tick(candidatePresent: candidate != nil, micActive:)`
  (`:108`). `DetectionStateMachine` (`MeetingDetector.swift:7-46`, a pure
  `struct`, unit-tested) needs `startThreshold = 2` consecutive candidate+mic ticks
  to fire `.started`, and `endThreshold = 3` consecutive candidate-absent ticks to fire
  `.ended` (end ignores mic on purpose — our own recording keeps it busy).
- **Actions.** On `.started`, `onMeetingStart?(candidate)` fires (`:109-111`); on
  `.ended`, `onMeetingEnd?()` fires (`:112-114`).
- **Wiring → recording.** In `AppDelegate.applicationDidFinishLaunching`
  (`NotableApp.swift:31-37`):
  - `onMeetingStart` checks the `autoRecordMeetings` default (default `true`) and calls
    `meeting.startAutomatically(source: candidate.sourceName)`.
  - `onMeetingEnd` calls `meeting.stopAutomatically()`.
- **Controller entry points.** `MeetingController.startAutomatically(source:)`
  (`MeetingController.swift:78-86`) guards `state == .idle`, calls `start(auto: true)`,
  sets a status message. `stopAutomatically()` (`:88-91`) stops only if the recording
  was `startedAutomatically`. Manual start/stop via the menu
  (`MeetingController.toggle()` `:69-75`) is independent and unaffected.
- **Settings.** `MeetingsSettingsView` (`SettingsView.swift:209-228`) exposes one
  `@AppStorage("autoRecordMeetings")` toggle (default `true`).

**Key observation for reuse:** `DetectionStateMachine.isActive` already means "a
confirmed call is present and I have acted on it," and it stays `true` for the whole
call until the candidate disappears. That is exactly the property we need for
"don't re-ask for the same call": we keep the state machine, and only change what
`.started` *does* — prompt instead of record.

## 3. Proposed consent UX

### 3.1 Surface choice — non-activating NSPanel (recommended)

Use an `NSPanel` modeled directly on `DictationOverlayController`
(`DictationOverlay.swift:73-100`), with **one deliberate difference**: the consent
panel must accept mouse clicks, so `ignoresMouseEvents = false` (the dictation overlay
sets it `true` at `:86`). A `.nonactivatingPanel` **can receive mouse clicks on its
SwiftUI buttons without becoming key or main**, so Ja/Nein work while focus stays in
the user's call app. Same recipe otherwise:

- `styleMask: [.borderless, .nonactivatingPanel]`, `level = .statusBar`,
  `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = true` (a real
  shadow is fine here — it reads as a card), `hidesOnDeactivate = false`,
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`.
- Shown with `panel.orderFrontRegardless()` — **never** `makeKeyAndOrderFront`,
  **never** `makeKey`, **never** `NSApp.activate`.
- Positioned top-right under the menu bar (near the Notable status item), so it reads
  as coming from the menu-bar app rather than a modal. Reuse the
  `NSScreen.main.visibleFrame` math from `DictationOverlay.position` (`:94-100`).

Content: title "Diesen Call transkribieren?", subtitle = candidate source name
(e.g. "Zoom" / "Google Meet (Google Chrome)"), buttons **Ja**, **Nein**, and a
checkbox or third button **"Immer für diese App"**. All in German to match the app.

**Why not the alternatives:**
- `UNUserNotification` (Notification Center): cannot host a persistent inline
  Ja/Nein/"immer" tri-choice cleanly (notification actions are limited and hidden
  behind hover/expand), requires notification authorization for an `LSUIElement`, and
  routing the tap back into an in-process action needs a `UNUserNotificationCenterDelegate`.
  More moving parts, worse affordance. Keep as a fallback option (open decision Q6).
- Menu-bar `NSPopover`: a popover is anchored to the status item and typically wants
  the app active/the menu open; showing it unsolicited is awkward and can transiently
  activate. The free-floating non-activating panel is the closest match to an existing,
  proven pattern in this codebase.

### 3.2 No focus stealing — mechanics

- The panel is `.nonactivatingPanel` and only ever `orderFrontRegardless()`.
- Never call `NSApp.activate(ignoringOtherApps:)` for it (note the menu's search action
  *does* call that at `NotableApp.swift:161` — the consent flow must not).
- Buttons are plain SwiftUI `Button`s inside the panel's `NSHostingView`; clicking them
  delivers a mouse event to a non-key window, which AppKit allows for
  `.nonactivatingPanel`. No text fields (which would want key focus).
- Guard: add a debug assertion / manual test that the panel's window returns
  `canBecomeKey == false` (subclass `NSPanel` and override `canBecomeKey`/`canBecomeMain`
  to `false` for belt-and-suspenders, mirroring the overlay's intent).

### 3.3 Timeout / auto-dismiss

- Auto-dismiss after **N seconds** (proposed default **25 s**; open decision Q3) with no
  click → treated as **implicit Nein** (do not record), but the state machine stays
  `isActive`, so the same call is **not** re-prompted.
- The panel is also dismissed immediately if `onCallEnded` fires (candidate gone) before
  a choice — the call is over.
- Reuse the cancellable-`Task` auto-hide pattern from
  `DictationOverlayController.flashError` (`:64-71`): any new `show` cancels the pending
  hide.

### 3.4 "Ja" → recording

On **Ja**: `ConsentCoordinator` calls
`AppContainer.shared.meeting.startAutomatically(source: candidate.sourceName)` — the
exact call the `onMeetingStart` handler makes today (`NotableApp.swift:33`). Because
`startAutomatically` guards `state == .idle` and sets `startedAutomatically = true`,
the existing auto-stop path (`onCallEnded → stopAutomatically()`) keeps working
unchanged. The consent layer is inserted purely *before* this call; `MeetingController`
needs **no changes**.

## 4. State-machine changes

`DetectionStateMachine` (the pure struct) needs **no structural change** — its
`.started`/`.ended` events and `isActive` latch are reused as-is. What changes is the
**meaning** of the callback and a new coordinator that sits between the detector and the
controller:

```
call detected+mic (2 ticks)                     candidate gone (3 ticks)
        │  DetectionStateMachine.tick → .started        │ → .ended
        ▼                                                ▼
  onCallDetected(candidate)                        onCallEnded()
        │                                                │
        ▼                                                ▼
  ConsentCoordinator.requestConsent(candidate)     ConsentCoordinator.callEnded()
        │                                                ├─ dismiss pending panel
   remembered pref?                                      └─ meeting.stopAutomatically()
    ├─ .always → meeting.startAutomatically()
    ├─ .never  → do nothing (declined)
    └─ none    → show panel (awaiting user)
                    ├─ Ja  → meeting.startAutomatically()  [+ remember if "immer"]
                    ├─ Nein→ declined                       [+ remember if "immer nicht"]
                    └─ timeout → declined (implicit)
```

Conceptual per-call status tracked by the coordinator (the detector's `isActive`
already prevents re-entry, so this is a light enum, not a second debounce):

`idle → awaitingConsent → (recording | declined) → idle` (on `callEnded`).

**Don't-re-ask rule:** guaranteed by `DetectionStateMachine.isActive` staying `true`
for the whole call — `onCallDetected` fires **once** per call (`.started` fires once,
`:38-42`). No extra bookkeeping needed. When the call ends and re-starts (new
`.started`), it is legitimately a new call and re-prompting is correct.

**Rename for clarity (optional but recommended):** rename the detector's callbacks
`onMeetingStart`/`onMeetingEnd` → `onCallDetected`/`onCallEnded` to reflect that
"detected" no longer implies "recording." Pure text change in `MeetingDetector.swift`
and `NotableApp.swift`.

### 4.1 Stable identity for the "per app" preference

`Candidate.sourceName` is a display string (`"Google Meet (Google Chrome)"`) and is a
poor storage key. Add a stable `identityKey` to `Candidate`:

- Dedicated/ambient apps → the bundle ID (`us.zoom.xos`, `com.tinyspeck.slackmacgap`, …).
- Browser calls → the service, not the browser: `"web:google-meet"`, `"web:zoom"`,
  `"web:teams"` (so "always Zoom" holds whether Zoom is native or in a tab — open
  decision Q4 on whether to unify native+web under one key).

This requires threading the bundle ID / service tag through `detectCandidate()`,
`detectBrowserMeeting()`, and the `meetingApps` table (which already has the bundle ID).

## 5. Files to add / change, with signatures

### 5.1 New: `Sources/Notable/Meeting/MeetingConsent.swift`

Preference store (thin wrapper over `UserDefaults.standard`, key
`"meetingConsentByApp"`, a `[String: String]` map of `identityKey → "always" | "never"`):

```swift
enum MeetingConsentDecision: String { case always, never }

enum MeetingConsentStore {
    static let defaultsKey = "meetingConsentByApp"
    static func decision(for identityKey: String) -> MeetingConsentDecision?
    static func remember(_ decision: MeetingConsentDecision, for identityKey: String)
    static func forget(_ identityKey: String)
    static func all() -> [String: MeetingConsentDecision]   // for Settings list
}
```

### 5.2 New: `Sources/Notable/Meeting/ConsentPromptController.swift`

Non-activating panel controller (mirrors `DictationOverlayController`):

```swift
@MainActor
final class ConsentPromptController {
    struct Choice { enum Kind { case yes, no }; var kind: Kind; var remember: Bool }
    // Presents the panel; `onChoice` is called exactly once (button or timeout=.no,false).
    func present(sourceName: String,
                 timeout: TimeInterval,
                 onChoice: @escaping (Choice) -> Void)
    func dismiss()   // call when the call ends before a choice
}
// Backing NSPanel subclass overrides canBecomeKey/canBecomeMain → false.
// + private struct ConsentPromptView: View  (title, source, Ja/Nein, "Immer für diese App" toggle)
```

### 5.3 New: `Sources/Notable/Meeting/ConsentCoordinator.swift`

Glue between detector, preference store, panel, and controller (holds the per-call
status; MainActor):

```swift
@MainActor
final class ConsentCoordinator {
    init(meeting: MeetingController,
         prompt: ConsentPromptController = ConsentPromptController(),
         timeout: TimeInterval = 25)
    func callDetected(_ candidate: MeetingDetector.Candidate)  // ← onCallDetected
    func callEnded()                                           // ← onCallEnded
}
```
Logic: if `autoRecordMeetings` is off → do nothing (parity with today's guard at
`NotableApp.swift:32`). Else consult `MeetingConsentStore.decision(for: candidate.identityKey)`:
`.always` → `meeting.startAutomatically(source:)`; `.never` → nothing; `nil` → present
the panel; on `.yes` start recording, on `.no` decline, and if `remember` was checked
persist `.always`/`.never`. `callEnded()` dismisses the panel and calls
`meeting.stopAutomatically()`.

### 5.4 Change: `Sources/Notable/Meeting/MeetingDetector.swift`

- `struct Candidate`: add `var identityKey: String`.
- `meetingApps` rows already carry `bundleID` → set `identityKey` from it.
- `detectBrowserMeeting()`: set `identityKey` to `"web:google-meet"` / `"web:zoom"` /
  `"web:teams"`.
- Rename `onMeetingStart`/`onMeetingEnd` → `onCallDetected`/`onCallEnded` (semantic
  clarity; optional).

### 5.5 Change: `Sources/Notable/NotableApp.swift`

- Add `lazy var consent = ConsentCoordinator(meeting: meeting)` to `AppContainer`
  (so the panel is retained for the app's lifetime).
- Rewire `AppDelegate.applicationDidFinishLaunching` (`:31-37`):
  ```swift
  container.detector.onCallDetected = { candidate in container.consent.callDetected(candidate) }
  container.detector.onCallEnded    = {           container.consent.callEnded() }
  ```
  (The `autoRecordMeetings` check moves into the coordinator.)

### 5.6 Change: `Sources/Notable/Settings/SettingsView.swift`

In `MeetingsSettingsView` (`:209-228`): keep the master toggle; add a
sub-section listing remembered per-app decisions from `MeetingConsentStore.all()` with a
"Zurücksetzen"/remove button per row (so an "Immer für diese App" can be revoked),
and update the footer copy to explain the consent prompt. Optionally add a
"Bei Erkennung immer fragen (nicht automatisch aufnehmen)" framing.

### 5.7 Change: `project.yml`

The `NotableTests` target compiles unit files by explicit path (`project.yml:26-51`).
If `MeetingConsentStore` gets unit tests (recommended — pure, no UI), add
`- path: Sources/Notable/Meeting/MeetingConsent.swift` to the `NotableTests.sources`
list, then run `xcodegen generate`. `MeetingDetector.swift` is already listed
(`project.yml:49`), so `DetectionStateMachine` stays covered. The panel/coordinator
(`@MainActor`, UI/AppKit) are **not** added to the test target.

## 6. Open decisions

- **Q1 — Surface.** Confirm the non-activating NSPanel (recommended) vs.
  `UNUserNotification`. Panel is the closer match to existing code and gives a clean
  tri-choice; notification is more "system-native" but weaker affordance.
- **Q2 — Third option shape.** "Immer für diese App" as a **checkbox next to Ja/Nein**
  (one click records *and* remembers) vs. a **separate third button**. Also: do we offer
  the negative "Immer nicht für diese App" (remember `.never`), or only remember on Ja?
- **Q3 — Timeout.** Default auto-dismiss duration (proposed 25 s) and its meaning
  (proposed: implicit Nein, no re-ask this call). Or: never auto-dismiss and rely on
  `callEnded` only?
- **Q4 — Identity granularity.** Should "always Zoom" unify native Zoom
  (`us.zoom.xos`) and web Zoom (`web:zoom`) under one key, or keep them separate?
  Same question for Teams.
- **Q5 — Default behavior of the master toggle.** Today `autoRecordMeetings` defaults to
  `true` and means "record automatically." With consent, does the existing toggle now
  mean "ask on detection" (recommended: repurpose, default on) — or do we add a
  *second* toggle "Vor Aufnahme fragen" so the old silent-auto behavior remains
  available? (Repurposing changes established behavior; flag it.)
- **Q6 — Placement.** Top-right under the menu bar (recommended, reads as menu-bar app)
  vs. bottom-center like the dictation overlay. They must not overlap the dictation
  overlay if both can show.
- **Q7 — Recover-from-launch interaction.** Consent applies only to *live* detection;
  crash-recovered spools (`recoverOrphanedRecordings`) are already-captured audio and
  are out of scope for consent. Confirm.

## 7. Acceptance criteria

1. With `autoRecordMeetings` on and no remembered preference, joining a Zoom/Teams/
   Webex/Slack call or a browser Meet/Zoom/Teams call shows the consent panel within
   ~2 poll ticks (≤ ~10 s), naming the source. No recording has started yet
   (`meeting.state == .idle`).
2. The panel **never** activates Notable or steals focus: while it is visible, the
   user's call app keeps keyboard focus, and dictation paste into a focused field still
   works. `panel.canBecomeKey == false`.
3. Clicking **Ja** starts the meeting recording (`meeting.state.isRecording == true`),
   identical to today's auto path. Clicking **Nein** or letting it time out starts
   nothing.
4. The prompt appears **at most once per call**: after Nein/timeout, no re-prompt while
   the same call continues; a genuinely new call (candidate disappeared then reappeared)
   prompts again.
5. Checking **"Immer für diese App"** + Ja persists `.always` for that `identityKey`;
   the next call from the same app records **without** a prompt. A reset control in
   Settings clears it.
6. When the call ends (candidate gone for `endThreshold` ticks), any pending panel is
   dismissed and `stopAutomatically()` runs (unchanged auto-stop behavior).
7. Turning `autoRecordMeetings` off suppresses both prompt and recording; manual
   "Meeting aufzeichnen" from the menu still works.
8. Existing `MeetingConversationTests` / detector tests still pass; new
   `MeetingConsentStore` unit tests cover remember/decision/forget.

## 8. Effort estimate (rough)

- `MeetingConsent.swift` (store) + tests: ~0.5 day.
- `ConsentPromptController.swift` (panel + SwiftUI view, non-key guards): ~1 day
  (fiddly part is verifying no focus theft and button clicks on a non-key panel).
- `ConsentCoordinator.swift` + detector `identityKey` threading + `NotableApp` rewiring:
  ~0.5 day.
- `SettingsView` per-app list + copy: ~0.5 day.
- Manual verification against real Zoom/Meet/Teams and the dictation-focus regression:
  ~0.5 day.

**Total: ~3 developer-days**, assuming Q1–Q6 are answered up front. Risk concentrated in
the non-activating-panel-with-clickable-buttons behavior (acceptance criteria 2 & 3) —
prototype that first.
