# Integration: auto-update from GitHub Releases

Lightweight update check for the single-user Notable menu-bar app. It **notifies
only** — it never downloads or installs. When a newer release exists, a menu item
opens the release/download URL in the browser; the user then re-runs the install
step (drag the app into `/Applications`, replacing the old bundle so the TCC grants
stick — see CLAUDE.md).

New files (already added, no edits to existing files):

- `Sources/Notable/Update/UpdateChecker.swift` — `SemanticVersion`, `GitHubRelease`,
  `UpdateInfo`, `UpdateResolver` (pure) + `@MainActor final class UpdateChecker: ObservableObject`.
- `Tests/NotableTests/UpdateCheckerTests.swift` — pure tests (no network).

Repo constant lives in `UpdateChecker.repo = "jonas-gehring/notable"` (derived from
`git remote -v` → `origin https://github.com/jonas-gehring/notable.git`). Update it
if the remote changes.

The three edits below are intentionally left to you (the task forbids touching
`NotableApp.swift` / `SettingsView.swift`). Apply them by hand.

---

## 1. `AppContainer` — add the instance (NotableApp.swift)

Inside `final class AppContainer`, next to the other lets:

```swift
let updateChecker = UpdateChecker()
```

## 2. `AppDelegate` — on-launch check (NotableApp.swift)

At the end of `applicationDidFinishLaunching(_:)`:

```swift
// Throttled (once per 24h via UserDefaults); silent on network/rate-limit errors.
Task { await container.updateChecker.checkOnLaunch() }
```

## 3. Menu — the "Update verfügbar" item (NotableApp.swift)

Inject the checker into the menu scene alongside the other `environmentObject`s in
`NotableApp.body` → `MenuBarExtra { MenuContentView() … }`:

```swift
.environmentObject(AppContainer.shared.updateChecker)
```

Add the observed object to `MenuContentView`:

```swift
@EnvironmentObject private var updateChecker: UpdateChecker
```

Then, in `MenuContentView.body` — a good spot is just above the final
`Divider()` that precedes "Einstellungen…":

```swift
if let update = updateChecker.available {
    Divider()
    Button("Update verfügbar: \(update.versionString) — herunterladen") {
        NSWorkspace.shared.open(update.downloadURL)
    }
}
```

## 4. (Optional) Settings — a manual "Nach Updates suchen" row

Inject the checker into the Settings scene in `NotableApp.body` → `Settings { SettingsView() … }`:

```swift
.environmentObject(AppContainer.shared.updateChecker)
```

Then in `GeneralSettingsView` (SettingsView.swift) add the env object and a Section:

```swift
@EnvironmentObject private var updateChecker: UpdateChecker
```

```swift
Section {
    HStack {
        Button("Nach Updates suchen") {
            Task { await updateChecker.check() }
        }
        .disabled(updateChecker.isChecking)

        if updateChecker.isChecking {
            ProgressView().controlSize(.small)
        } else if let update = updateChecker.available {
            Button("\(update.versionString) laden") {
                NSWorkspace.shared.open(update.downloadURL)
            }
        } else if let last = updateChecker.lastChecked {
            Text("Aktuell — zuletzt geprüft \(last.formatted(date: .abbreviated, time: .shortened))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
    if let error = updateChecker.lastError {
        Text(error).font(.callout).foregroundStyle(.red)
    }
} header: {
    Text("Updates")
} footer: {
    Text("Prüft die neueste Version auf GitHub. Zum Aktualisieren die geladene App nach /Applications ziehen und die alte ersetzen — so bleiben die Berechtigungen erhalten.")
}
```

`GeneralSettingsView` already receives `notesFolder` via `environmentObject`, so the
extra `updateChecker` object flows in the same way once injected at the `Settings`
scene (step 4, first snippet).

---

## Behaviour notes

- `UpdateChecker.check()` GETs `https://api.github.com/repos/jonas-gehring/notable/releases/latest`
  (public, no auth). 404 (no releases yet), 403 (rate limit) and network failures are
  handled without crashing; `lastError` carries a German message for the Settings row.
- Version comparison is real semver (`0.9.0 < 0.10.0`, pre-releases rank below finals).
  The running version comes from `CFBundleShortVersionString`; make sure
  `MARKETING_VERSION` is set in `project.yml` and bumped per release.
- Publishing a release: tag it `vX.Y.Z`, attach a `Notable.zip` asset (the checker
  selects the first `.zip`; falls back to the release page if none is attached).
