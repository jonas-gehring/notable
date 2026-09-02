# Integration: quick access to recent dictations

`DictationHistory` (`Sources/Notable/Dictation/DictationHistory.swift`) is a
`@MainActor ObservableObject` that reads the already-persisted dictation history
from `RecordingStore.shared.recentDictations` and replays it. It owns no new
state — the only side effects are the clipboard and `Paster`.

Wiring it in is three small edits to `NotableApp.swift` (not applied here — this
file is the snippet).

## 1. Add an instance to `AppContainer`

```swift
@MainActor
final class AppContainer {
    static let shared = AppContainer()

    let appState = AppState()
    // …existing members…
    lazy var dictation = DictationController(appState: appState)
    lazy var meeting = MeetingController(notesFolder: notesFolder, calendar: calendar)
    lazy var dictationHistory = DictationHistory()   // ← add

    private init() {}
}
```

## 2. Inject it into `MenuContentView`

In `NotableApp.body`, on the `MenuBarExtra`'s `MenuContentView()`:

```swift
MenuContentView()
    .environmentObject(appState)
    .environmentObject(AppContainer.shared.dictation)
    .environmentObject(AppContainer.shared.meeting)
    .environmentObject(AppContainer.shared.detector)
    .environmentObject(AppContainer.shared.notesFolder)
    .environmentObject(AppContainer.shared.dictationHistory)   // ← add
```

## 3. Menu items + recent submenu in `MenuContentView`

Add the environment object next to the others:

```swift
@EnvironmentObject private var history: DictationHistory
```

Load the list when the menu opens. Add to the existing `.onAppear` on the
header `Text`, or attach a fresh one:

```swift
.onAppear { Task { await history.refresh() } }
```

Then insert this block where it reads best — e.g. just after the
`Text("Diktat: … halten")` line, followed by a `Divider()`:

```swift
Divider()

// Letztes Diktat: kopieren / erneut einfügen.
Button("Letztes Diktat einfügen") {
    Task { try? await history.pasteLast() }
}
.keyboardShortcut("v", modifiers: [.command, .shift])   // ⌘⇧V — not taken by ⌘, ⌘F ⌘Q ⌘R
.disabled(history.last == nil)

Button("Letztes Diktat kopieren") {
    Task { await history.copyLast() }
}
.keyboardShortcut("c", modifiers: [.command, .shift])   // ⌘⇧C
.disabled(history.last == nil)

// Letzte N Diktate — je zum Einfügen (Klick) oder Kopieren (Untermenü).
if !history.recent.isEmpty {
    Menu("Letzte Diktate") {
        ForEach(history.recent) { item in
            Menu(item.menuTitle) {
                Button("Einfügen") {
                    Task { try? await history.paste(item.text) }
                }
                Button("Kopieren") {
                    history.copy(item.text)
                }
            }
        }
    }
}
```

### Notes

- **Shortcuts** `⌘⇧V` (paste-last) and `⌘⇧C` (copy-last) deliberately avoid the
  taken `⌘,` `⌘F` `⌘Q` `⌘R`.
- **`pasteLast` / `paste`** go through `Paster.insert`, so they honour the
  accessibility check and the pasteboard-vs-typing method from Settings. When
  Accessibility is denied, `Paster` leaves the text on the clipboard and throws;
  the `try?` swallows it (same tradeoff the dictation path makes — the text is
  recoverable from the clipboard). If you want the failure surfaced, route it
  through `DictationController`'s overlay instead of `try?`.
- **Refresh timing** — `copyLast`/`pasteLast` call `refresh()` themselves before
  acting, so the keyboard shortcuts are correct even if the menu was never
  opened. The submenu list uses the `.onAppear` refresh.
- **Out of scope:** true "undo" of a paste that already landed in another app.
  macOS offers no reliable retraction, so `DictationHistory` never attempts it —
  re-paste and copy are the honest actions over the same persisted data.
