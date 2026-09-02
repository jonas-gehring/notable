# Integration — Note-management UI

This branch adds note management **without touching `NotableApp.swift`,
`MeetingController.swift`, or `SettingsView.swift`**. Below are the exact
snippets the parent must add to wire it in. Everything else (the `Notes/` views,
`NoteManager`, `IconPickerView`, `MarkdownProjector.uniqueFileName`) is already
in place and auto-compiled.

## What this branch already contains

- `Sources/Notable/Notes/NoteManager.swift` — `@MainActor final class NoteManager: ObservableObject`.
- `Sources/Notable/Notes/NoteListView.swift` — the window UI (`@EnvironmentObject var noteManager: NoteManager`).
- `Sources/Notable/Settings/IconPickerView.swift` — `IconPickerView` + `MenuBarIcon` (curated set, `storageKey`, `idleSymbol()`).
- `MarkdownProjector.uniqueFileName(title:date:in:excluding:)` + a test.

`NoteManager` needs the notes root, so construct it from `NotesFolderManager`:
`NoteManager(notesFolder: notesFolder)`.

## 1. `NotableApp.swift`

### 1a. Add `NoteManager` to `AppContainer` (after `meeting`, line ~16)

```swift
lazy var meeting = MeetingController(notesFolder: notesFolder, calendar: calendar)
lazy var notes = NoteManager(notesFolder: notesFolder)   // ← add
```

### 1b. Make `menuSymbol` read the user's idle icon (replace the `.idle` case, lines ~52-58)

```swift
private var menuSymbol: String {
    switch meeting.state {
    case .recording: "record.circle"
    case .processing: "hourglass.circle"
    case .idle:
        appState.captureState == .idle
            ? MenuBarIcon.idleSymbol()                 // ← user choice for the truly-idle base
            : appState.captureState.symbolName          // dictation activity still shows through
    }
}
```

If you want the menu-bar icon to update **live** when the setting changes (not
just on next menu open), add `@AppStorage(MenuBarIcon.storageKey) private var menuIconSymbol = MenuBarIcon.defaultSymbol`
to the `NotableApp` struct so SwiftUI re-renders `body`; `menuSymbol` can keep
calling `MenuBarIcon.idleSymbol()`.

### 1c. Add the Notes window scene (mirror the existing search `Window`, lines ~70-74)

```swift
Window("Notizen", id: "notes") {
    NoteListView()
        .environmentObject(AppContainer.shared.notes)
}
.windowResizability(.contentSize)
.defaultSize(width: 520, height: 480)
```

### 1d. Add a menu item to open it (in `MenuContentView`, near "Notizen-Ordner öffnen")

`MenuContentView` already has `@Environment(\.openWindow) private var openWindow`.

```swift
Button("Notizen verwalten…") { openWindow(id: "notes") }
```

## 2. `SettingsView.swift` — icon picker

Add a tab to the `TabView` in `SettingsView` (any position):

```swift
IconSettingsView()
    .tabItem { Label("Menüleiste", systemImage: "menubar.rectangle") }
```

And a small host view (put it anywhere in `SettingsView.swift`, e.g. below
`GeneralSettingsView`):

```swift
struct IconSettingsView: View {
    var body: some View {
        Form {
            Section {
                IconPickerView()
            } header: {
                Text("Menüleisten-Symbol")
            } footer: {
                Text("Gilt nur für den Ruhezustand. Aufnahme, Verarbeitung und aktives Diktat behalten ihre festen Symbole.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}
```

(Alternatively, drop `IconPickerView()` straight into an existing
`GeneralSettingsView` section — it is self-contained and `@AppStorage`-backed.)

## 3. Optional: write new notes into `Inbox/` (MeetingController)

Out of scope for this branch (it must not edit `MeetingController.swift`), but to
finish the Inbox story the parent can, in `produceNote`, write into
`folderURL.appendingPathComponent("Inbox")` and set `folder: "Inbox"` on the
inserted `Recording`. `NoteManager` already treats `"Inbox"` as the default and
moves notes between `Inbox` and project subfolders regardless.

## Notes on behavior

- `NoteManager.reload()` is called by `NoteListView.task`; no timer, no warm
  state — idle CPU/RSS unchanged.
- Rename/move re-project the `.md` **purely from SQLite** (see below), so a
  hand-edited or deleted file is rebuilt faithfully. The one caveat: the store
  keeps the calendar event *id*, not its title, so a re-projected note omits the
  front-matter `event:` line.
