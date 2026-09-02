# Integration: "Letzte Transkripte" overview

This wires the new `RecentTranscriptsView` into the app. It mirrors the existing
"Notizen durchsuchen" (`SearchWindowView`) window: a `Window` scene plus a menu
button that opens it with `openWindow(id:)`.

Everything here goes into `Sources/Notable/NotableApp.swift`. No other file needs
to change — `RecentTranscriptsView` reads `RecordingStore.shared` directly, so it
needs no environment objects.

## 1. Add the `Window` scene

In `struct NotableApp: App`, inside `body`, next to the existing search window:

```swift
Window("Letzte Transkripte", id: "recent") {
    RecentTranscriptsView()
}
.windowResizability(.contentSize)
.defaultSize(width: 560, height: 440)
```

## 2. Add the menu button

In `struct MenuContentView`, near the existing "Notizen durchsuchen…" button
(which already has `@Environment(\.openWindow) private var openWindow`):

```swift
Button("Letzte Transkripte…") {
    openWindow(id: "recent")
    NSApp.activate(ignoringOtherApps: true)
}
.keyboardShortcut("r")
```

`NSApp.activate` is required for the same reason the search window needs it: a
menu-bar (`LSUIElement`) app does not foreground its own windows automatically.

## 3. Regenerate the project

`RecentTranscriptsView.swift` lives under `Sources/Notable/`, which the app target
globs, so it is picked up automatically — but the Xcode project must be
regenerated after adding the file:

```sh
xcodegen generate
```

No `project.yml` edit is needed: the app target references the whole
`Sources/Notable` directory, and `RecordingStore.swift` (which now carries
`recentActivity`) is already in the `NotableTests` sources list, so the new tests
compile without further changes.

## Notes

- The view is read-only. Meetings link out to their Markdown note via
  `NSWorkspace.open`; dictations (which have no file) expose their transcribed
  text inline with a "Kopieren" affordance.
- The window's time filter defaults to the last 24 hours, with a segmented
  control to widen to 7 days or all recordings.
