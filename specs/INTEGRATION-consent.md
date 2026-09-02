# Integration: wiring the consent gate (apply-in-parent)

This branch adds the consent gate as **new files only**. Three files are intentionally
left untouched so the parent applies them deliberately:

- `Sources/Notable/NotableApp.swift` — wire the coordinator (below).
- `Sources/Notable/Meeting/MeetingController.swift` — **no change needed** (the consent
  layer sits entirely in front of `startAutomatically`).
- `Sources/Notable/Settings/SettingsView.swift` — add the reset UI (below).

New files added by this branch:

- `Sources/Notable/Meeting/MeetingConsent.swift` — `MeetingConsentStore` (UserDefaults
  `"meetingConsentByApp"`), `MeetingConsentDecision`, and the pure `MeetingIdentity`
  web-service mapping. In the test target.
- `Sources/Notable/Meeting/ConsentPromptController.swift` — non-activating NSPanel.
- `Sources/Notable/Meeting/ConsentCoordinator.swift` — detector → store → prompt → controller.
- `Tests/NotableTests/MeetingConsentTests.swift` — pure tests (17, all passing).

Also already applied on this branch (not in the "do not edit" set):

- `Sources/Notable/Meeting/MeetingDetector.swift` — `Candidate` gained
  `var identityKey: String = "unknown"`, populated with the bundle id for native apps
  and `web:google-meet` / `web:zoom` / `web:teams` for browser calls. The browser
  matcher now routes through `MeetingIdentity.webService(forWindowTitle:)`, so display
  name and consent key share one source of truth. The `onMeetingStart`/`onMeetingEnd`
  callback **names are kept** (the spec's rename to `onCallDetected`/`onCallEnded` was
  skipped to avoid editing `NotableApp.swift`; rename later if desired).
- `project.yml` — `MeetingConsent.swift` added to the `NotableTests` sources (run
  `xcodegen generate` after pulling).

---

## 1. `NotableApp.swift` — wire the coordinator

### 1a. Retain the coordinator on the container

In `AppContainer` (alongside `lazy var meeting = …`), add:

```swift
    lazy var consent = ConsentCoordinator(meeting: meeting)
```

Retaining it here keeps the panel alive for the app's lifetime (same reasoning as the
other `lazy var`s).

### 1b. Replace the detection handlers

In `AppDelegate.applicationDidFinishLaunching`, replace the current block:

```swift
        container.detector.onMeetingStart = { candidate in
            guard UserDefaults.standard.object(forKey: "autoRecordMeetings") as? Bool ?? true else { return }
            container.meeting.startAutomatically(source: candidate.sourceName)
        }
        container.detector.onMeetingEnd = {
            container.meeting.stopAutomatically()
        }
```

with:

```swift
        // Detection no longer records directly — it asks. The coordinator honours a
        // remembered choice or shows the non-activating consent prompt; only "Ja"
        // (or a remembered "immer") calls startAutomatically. The autoRecordMeetings
        // guard now lives inside the coordinator.
        container.detector.onMeetingStart = { candidate in
            container.consent.callDetected(candidate)
        }
        container.detector.onMeetingEnd = {
            container.consent.callEnded()
        }
```

Nothing else in `NotableApp.swift` changes. `MenuContentView` still reads
`candidate.sourceName` (unchanged) and the manual "Meeting aufzeichnen" button still
calls `meeting.toggle()` (independent of consent).

---

## 2. `SettingsView.swift` — master toggle semantics + reset UI

### 2a. Master-toggle semantics — recommendation (do not change silently)

Today `@AppStorage("autoRecordMeetings")` (default `true`) means **"detect and record
automatically."** With the consent gate it now effectively means **"detect and *ask*."**
Recording is never silent anymore — it always requires Ja (or a remembered "immer").

**Recommended (repurpose, keep the key and its `true` default):** reword the existing
toggle so its meaning matches the new behaviour; do **not** add a second toggle. The old
silent-auto behaviour is deliberately gone (that was the point of the feature), and
reusing the key preserves the user's current on-state. This is a behaviour change to an
established toggle, so it is called out here rather than made silently — confirm before
merging.

Suggested reworded label + footer:

```swift
Toggle("Erkannte Calls automatisch erkennen und nachfragen", isOn: $autoRecord)
```

Footer copy (append to the existing footer): "Bei einem erkannten Call fragt Notable per
kleinem Hinweis oben rechts: *Diesen Call transkribieren?* Erst mit **Ja** startet die
Aufnahme. Mit **Immer für diese App** merkt sich Notable die Entscheidung pro Quelle."

If instead you want to preserve silent-auto as an option, add a *second*
`@AppStorage("askBeforeAutoRecord")` toggle and branch in `ConsentCoordinator.callDetected`
(off → `meeting.startAutomatically` directly). Not recommended; flagged for completeness.

### 2b. Remembered per-app decisions — reset list

Add this sub-view to `SettingsView.swift` and drop `RememberedConsentSection()` into the
`MeetingsSettingsView` `Form` (below the existing `Section`). It reads/writes the same
`MeetingConsentStore` the coordinator uses, so a reset here immediately re-enables the
prompt for that source.

```swift
private struct RememberedConsentSection: View {
    // Local mirror so the list refreshes after a reset.
    @State private var decisions: [(key: String, decision: MeetingConsentDecision)] = []

    var body: some View {
        Section("Gemerkte Entscheidungen pro App") {
            if decisions.isEmpty {
                Text("Noch keine „Immer"-Entscheidungen gemerkt.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(decisions, id: \.key) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(displayName(for: entry.key))
                            Text(entry.decision == .always ? "Immer aufnehmen" : "Nie aufnehmen")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Zurücksetzen") {
                            MeetingConsentStore.forget(entry.key)
                            reload()
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        decisions = MeetingConsentStore.all()
            .map { (key: $0.key, decision: $0.value) }
            .sorted { $0.key < $1.key }
    }

    // Bundle ids and web:* tags → something readable.
    private func displayName(for key: String) -> String {
        switch key {
        case "us.zoom.xos": return "Zoom"
        case "com.microsoft.teams2", "com.microsoft.teams": return "Microsoft Teams"
        case "com.apple.FaceTime": return "FaceTime"
        case "Cisco-Systems.Spark", "com.webex.meetingmanager": return "Webex"
        case "com.tinyspeck.slackmacgap": return "Slack"
        case "web:google-meet": return "Google Meet (Browser)"
        case "web:zoom": return "Zoom (Browser)"
        case "web:teams": return "Microsoft Teams (Browser)"
        default: return key
        }
    }
}
```

Then, inside `MeetingsSettingsView.body`'s `Form`, after the existing `Section { … }`:

```swift
            RememberedConsentSection()
```

---

## 3. Behaviour summary (matches spec §7 acceptance criteria)

- Master toggle on, no remembered choice → detected call shows the panel top-right within
  ~2 poll ticks; nothing records yet (`meeting.state == .idle`).
- Panel is `.nonactivatingPanel`, `canBecomeKey == false`, only `orderFrontRegardless()`
  — never `makeKey`/`NSApp.activate`. Focus stays in the call app; dictation paste keeps
  working. Buttons still click because a non-activating panel receives mouse events
  (`ignoresMouseEvents = false`) without becoming key.
- **Ja** → `meeting.startAutomatically(source:)` (identical to the old auto path).
  **Nein**/25 s timeout → nothing starts.
- At most one prompt per call: `DetectionStateMachine.isActive` latches `.started` once;
  the coordinator's `status` guard is belt-and-suspenders. A genuinely new call
  (candidate gone then back) prompts again.
- **Immer für diese App** + Ja/Nein persists `.always`/`.never` for the `identityKey`; the
  next call from that source skips the prompt. The Settings reset clears it.
- Call ends → `callEnded()` dismisses any pending panel and calls `stopAutomatically()`.
- Master toggle off → neither prompt nor recording; manual "Meeting aufzeichnen" still works.
```
