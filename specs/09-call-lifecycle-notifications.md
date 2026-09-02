# Spec 09: Call-Lifecycle — Benachrichtigung beim Join, automatisches Ende, Fertig-Meldung

Status: **umgesetzt**. Tests grün;
Abnahmekriterium 1–6 verlangt noch einen echten Call (siehe §10).
Scope: persönliches Tool, ein Nutzer (siehe `CLAUDE.md` → "Scope").
Baut auf `Specs/auto-detect-consent.md` (umgesetzt) auf und ersetzt dessen §3.1
Oberflächen-Entscheidung.

## 1. Ausgangslage — was heute wirklich passiert

| Wunsch | Stand heute |
|---|---|
| Beim Join von Teams/Meet/Zoom fragen, ob transkribiert werden soll | **Existiert** — aber als nicht-aktivierendes `NSPanel` oben rechts (`ConsentPromptController`), verdrahtet über `ConsentCoordinator` in `NotableApp.swift:40-45`. Aufnahme startet nur auf „Aufnehmen". |
| Call-Ende → Meeting endet automatisch | **Existiert nominell, greift praktisch kaum** (siehe §1.1). |
| Automatische Zusammenfassung | **Existiert** — `MeetingController.stop()` → `produceNote()` → `SummarizationService`; Fehler sind über das Menü retrybar. |
| Rückmeldung, dass die Notiz fertig ist | Nur `statusMessage` im Menü, das man aktiv aufklappen muss. |

### 1.1 Der echte Defekt: „Call zu Ende" ist falsch definiert

`DetectionStateMachine.tick` (`MeetingDetector.swift:26-45`) definiert das Ende als
**„Kandidat drei Ticks lang weg"**, und `detectCandidate()` (`:128-138`) definiert
Kandidat als **„App läuft"** (`NSWorkspace.runningApplications`):

- **Microsoft Teams** läuft den ganzen Arbeitstag → Kandidat verschwindet nie →
  `onMeetingEnd` feuert nie → die Aufnahme läuft nach dem Call weiter, bis sie
  manuell gestoppt wird. Gleiches gilt für **Slack** (Tier `.ambient`).
- **Zoom** endet nur zufällig korrekt, weil sich Zoom nach dem Meeting beendet.
- Nur **Browser-Meet/Zoom/Teams** endet halbwegs sauber, weil der Fenstertitel
  wechselt — und auch nur mit erteilter Bildschirmaufnahme-Berechtigung.

Dieselbe Schwäche verzerrt den Start: das Startsignal ist „irgendeine bekannte App
läuft **und irgendwer** benutzt das Mikrofon" — deshalb existiert der Workaround
`isOwnCaptureActive` (`NotableApp.swift:33-35`), der das globale Mikrofonsignal
ausblendet, sobald *wir* aufnehmen. Genau dieser Workaround macht das Mikrofonsignal
fürs Ende unbrauchbar (Kommentar in `MeetingDetector.swift:28-29`).

## 2. Beschlossene Entscheidungen

- **D1 — Prompt-Oberfläche:** echte macOS-Benachrichtigung (`UNUserNotification`)
  statt des Panels. Das Panel bleibt als **Fallback**, wenn die
  Benachrichtigungsberechtigung fehlt oder verweigert wurde (sonst gäbe es bei
  einem `LSUIElement` gar keinen Prompt mehr).
- **D2 — Fertig-Signal:** Benachrichtigung „Zusammenfassung fertig", Klick öffnet
  die Markdown-Notiz. Auch Fehlerfälle melden (ohne Zusammenfassung / kein
  Sprachinhalt), weil die heute nur im Menü sichtbar sind.
- **D3 (aus dieser Analyse, hier festgelegt):** Erkennung wechselt auf
  **prozessgenaue** CoreAudio-Signale; das globale Mikrofonsignal wird nur noch
  Fallback.

## 3. Teil A — prozessgenaue Call-Erkennung (das Kernstück)

### 3.1 Signal

macOS 14.0+ liefert pro Prozess Audio-Objekte — dieselbe API-Familie, aus der
`SystemAudioTap` schon den Prozess-Tap baut. Deployment-Target ist 14.4, also
uneingeschränkt nutzbar:

- `kAudioHardwarePropertyProcessObjectList` (System-Objekt) → `[AudioObjectID]`
- pro Prozess: `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`,
  `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyIsRunningOutput`

Damit heißt „im Call" nicht mehr „App läuft", sondern **„diese App hat gerade das
Mikrofon offen"**. Der entscheidende Nebeneffekt: unsere eigene Aufnahme hat eine
eigene PID und wird schlicht herausgefiltert — das Signal bleibt **auch während
unserer Aufnahme gültig**, und damit ist das Call-Ende zum ersten Mal echt messbar.

### 3.2 Neue Datei: `Sources/Notable/Meeting/AudioProcessMonitor.swift`

```swift
/// Ein Snapshot der Audio-Prozesse: wer hat gerade Mikrofon bzw. Ausgabe offen.
struct AudioProcessSnapshot: Sendable {
    struct Entry: Sendable, Equatable {
        var pid: pid_t
        var bundleID: String?
        var isRunningInput: Bool
        var isRunningOutput: Bool
    }
    var entries: [Entry]
    /// false ⇒ CoreAudio lieferte nichts (API-Fehler) → Aufrufer nimmt den Fallback.
    var isAvailable: Bool

    func entry(bundleID: String) -> Entry?
    func anyInput(bundleIDs: Set<String>) -> Entry?
}

enum AudioProcessMonitor {
    /// Fragt die Prozessliste ab; filtert die eigene PID heraus.
    static func snapshot(excluding ownPID: pid_t = getpid()) -> AudioProcessSnapshot
}
```

Rein lesend, kein State, keine Berechtigung nötig (Tapping bräuchte TCC, das
bloße Auslesen der Flags nicht).

### 3.3 Änderung: `MeetingDetector`

`detectCandidate()` bekommt eine neue erste Stufe und behält die alte als Fallback:

1. **Snapshot holen.** Ist er nicht verfügbar → **alter Pfad** unverändert
   (App läuft + globales Mikro). Verhalten bleibt damit im schlimmsten Fall exakt
   das heutige.
2. **Dedizierte Apps** (Zoom, Teams, FaceTime, Webex): Kandidat, wenn der Prozess
   `isRunningInput` hat. Kein „läuft nur"-Kandidat mehr.
3. **Browser** (Chrome, Safari, Arc, Edge, Firefox, Brave): Kandidat, wenn der
   Browser-Prozess `isRunningInput` hat. Der Anzeigename/`identityKey` kommt weiter
   aus dem Fenstertitel via `MeetingIdentity.webService(forWindowTitle:)`; ist der
   Titel nicht lesbar (keine Bildschirmaufnahme-Berechtigung), bleibt es trotzdem
   ein Kandidat mit `identityKey = "web:unknown"` und Name „Browser-Call (Chrome)".
4. **Slack** (bisher `.ambient`, also Dauerkandidat): wird zu einem normalen
   Kandidaten mit Mikrofonsignal — eine Slack-Huddle hält das Mikro, das
   dauerlaufende Slack nicht. Der Tier-Vorrang (dediziert > Browser > ambient)
   bleibt für den Fall mehrerer gleichzeitiger Signale bestehen.

Neu am Detector:

```swift
var isCallActive: Bool { stateMachine.isActive }   // für Teil B/C und MeetingController
```

### 3.4 Änderung: `DetectionStateMachine` — Ende sauber definieren

Das Ende bekommt ein eigenes, tolerantes Signal statt „Kandidat weg":

- **Start:** unverändert `startThreshold = 2` Ticks (≈ 10 s) mit Kandidat + Mikro.
- **Ende:** `endThreshold` **3 → 4** Ticks (≈ 20 s), und „Kandidat weg" heißt jetzt
  „der Call-Prozess hat **weder Eingabe noch Ausgabe** offen" (bzw. ist beendet).
  Die Ausgabe wird bewusst mitgezählt: manche Apps geben das Mikrofon beim
  Stummschalten frei, spielen aber weiter die Gegenseite ab — ohne diese
  Oder-Bedingung würde Stummschalten die Aufnahme beenden.
- Die reine Struktur (`isActive`-Latch, ein `.started`/`.ended` pro Call) bleibt,
  damit die bestehenden Detector-Tests und die „nur einmal fragen"-Garantie des
  Consent-Layers weiter gelten. Der Detector füttert `candidatePresent` künftig
  aus dem neuen In-Call-Signal.

### 3.5 Änderung: `MeetingController` — auch manuell gestartete Aufnahmen beenden

`stopAutomatically()` stoppt heute nur, wenn `startedAutomatically == true`
(`MeetingController.swift:88-91`). Wer den Call erkannt bekommt, „Später" klickt
und dann doch über das Menü aufnimmt, hängt danach in einer Endlosaufnahme.

Neu: `MeetingController` bekommt `var isCallActive: () -> Bool = { false }`
(injiziert aus dem Container mit `detector.isCallActive`, gleiches Muster wie
`isOwnCaptureActive`). `start(auto:)` merkt sich
`startedDuringCall = auto || isCallActive()`, und `stopAutomatically()` stoppt,
wenn `startedAutomatically || startedDuringCall`. Eine Aufnahme, die ohne jeden
erkannten Call gestartet wurde (Sprachnotiz, Interview), bleibt unangetastet.

## 4. Teil B — Benachrichtigung statt Panel beim Join

### 4.1 Neue Datei: `Sources/Notable/Support/NotificationCenterService.swift`

Ein dünner Wrapper um `UNUserNotificationCenter` samt Delegate (der Delegate muss
gesetzt sein, *bevor* Benachrichtigungen zugestellt werden — also im
`AppDelegate`), mit `.banner`-Präsentation auch im Vordergrund:

```swift
@MainActor
final class NotificationCenterService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCenterService()

    enum Category: String { case meetingConsent, meetingReady }
    enum Action: String { case record, remember, later, openNote }

    func registerCategoriesAndDelegate()
    func requestAuthorizationIfNeeded() async -> Bool
    var isAuthorized: Bool { get }          // synchron gecacht, für den Fallback-Zweig

    func postConsentPrompt(id: String, sourceName: String, canRemember: Bool)
    func postMeetingReady(id: String, title: String, body: String, noteURL: URL?)
    func withdraw(id: String)

    /// Genau einmal pro Prompt aufgerufen; `nil` = Nutzer hat ignoriert/weggewischt.
    var onConsentAction: ((Action) -> Void)?
}
```

Kategorien:

- `meetingConsent` mit den Aktionen **„Aufnehmen"** (`record`),
  **„Immer für diese App"** (`remember`), **„Später"** (`later`). Die
  Standardaktion (Klick auf den Text) wird als `record` gewertet — eine
  Benachrichtigung „Meeting erkannt — aufzeichnen?" anzuklicken heißt ja.
  `remember` wird nur angeboten, wenn `identityKey != "web:unknown"` (siehe §4.3).
- `meetingReady` mit Standardaktion `openNote` → `NSWorkspace.open(noteURL)`.

Berechtigung: `requestAuthorizationIfNeeded()` beim Launch (`.alert`, `.sound` aus —
kein Ton für den Prompt, der Call läuft ja). Ad-hoc-Signierung ist unkritisch,
solange die App als Bundle unter `/Applications` läuft.

### 4.2 Änderung: `ConsentCoordinator` — Präsentation austauschbar

Der Koordinator kennt heute `ConsentPromptController` konkret. Er bekommt ein
Protokoll und wählt zur Laufzeit:

```swift
@MainActor protocol ConsentPresenting {
    func present(sourceName: String, identityKey: String, timeout: TimeInterval?,
                 onChoice: @escaping (ConsentChoice) -> Void)
    func dismiss()
}
```

- `NotificationConsentPresenter` (neu, in `NotificationCenterService.swift` oder
  daneben) — Default, wenn `isAuthorized`.
- `ConsentPromptController` (vorhandenes Panel) — Fallback, wenn nicht autorisiert.
  Bleibt damit lebender, benutzter Code, kein Leichenteil.

**Timeout:** beim Panel 25 s (implizites Nein). Für die Benachrichtigung
`timeout = nil` — sie bleibt im Mitteilungscenter liegen, und ein Klick zwei
Minuten später soll die Aufnahme noch starten dürfen, solange der Call läuft.
Aufgelöst wird sie stattdessen durch `callEnded()` → `withdraw(id:)`; eine Antwort
nach Call-Ende ist durch die bestehende `status == .awaitingConsent`-Prüfung in
`ConsentCoordinator.resolve` ohnehin ein No-op.

### 4.3 „Immer merken" bei unidentifizierten Browser-Calls

Für `identityKey == "web:unknown"` (Browser hält das Mikro, Titel nicht lesbar)
wird **kein** „Immer"-Angebot gemacht und ein trotzdem eintreffendes `remember`
ignoriert — sonst würde „immer aufnehmen" jede beliebige Mikrofonnutzung des
Browsers (Sprachsuche, WhatsApp Web, …) automatisch mitschneiden.

## 5. Teil C — Fertig-Benachrichtigung

In `MeetingController` an den drei Stellen, an denen heute nur `statusMessage`
gesetzt wird (`stop()`-Task und `recoverOrphanedRecordings()`):

| Fall | Titel | Text | Klick |
|---|---|---|---|
| Notiz + Zusammenfassung ok | „Zusammenfassung fertig" | Notiztitel | öffnet die Notiz |
| Notiz ohne Zusammenfassung | „Notiz gespeichert — ohne Zusammenfassung" | Fehlergrund + „im Menü erneut versuchen" | öffnet die Notiz |
| Kein Sprachinhalt | „Kein Sprachinhalt erkannt" | Hinweis auf Systemaudio-/Mikrofonprüfung | öffnet nichts |
| Verarbeitung fehlgeschlagen | „Meeting-Verarbeitung fehlgeschlagen" | Fehlertext | öffnet nichts |

`statusMessage` bleibt zusätzlich erhalten (Menü ist die Historie, die
Benachrichtigung nur das Signal).

## 6. Einstellungen & Berechtigungen

- `MeetingsSettingsView`: Fußnote unter dem Master-Toggle auf das neue Verhalten
  umformulieren (Benachrichtigung statt Popup, automatisches Ende). Ein neuer
  Toggle `@AppStorage("notifyOnMeetingReady")` (Default an) für Teil C.
- `PermissionsManager`: neuer Fall `.notifications` mit Status (`granted` /
  `denied` / `notDetermined`) und Deep-Link
  `x-apple.systempreferences:com.apple.Notifications-Settings.extension`, damit ein
  verweigerter Zugriff sichtbar ist statt still zu schlucken.

## 7. Tests

Neu (rein, ohne UI/CoreAudio-Hardware):

- `AudioProcessSnapshot` — `entry(bundleID:)` / `anyInput(bundleIDs:)` inkl.
  Vorrangregeln, gebaut aus handgeschriebenen `Entry`-Listen.
- `DetectionStateMachine` — neuer `endThreshold = 4`; Ende feuert **nicht**, wenn
  nur die Eingabe wegfällt, die Ausgabe aber weiterläuft (Stummschalten);
  Ende feuert, wenn beides weg ist.
- Consent-Auflösung mit `timeout = nil` (kein implizites Nein) und
  „`remember` bei `web:unknown` wird verworfen".

Bestehende Tests müssen grün bleiben, insbesondere `MeetingConsentTests` und die
Detector-Tests. Neue Dateien mit reiner Logik in die `NotableTests.sources` in
`project.yml` eintragen, danach `xcodegen generate`.

## 8. Abnahmekriterien

1. Teams-Call beitreten (Teams lief vorher schon stundenlang) → binnen ~10 s
   erscheint die Benachrichtigung „Meeting erkannt — Microsoft Teams".
   Vorher wird **nicht** aufgezeichnet (`meeting.state == .idle`).
2. „Aufnehmen" klicken → Aufnahme läuft; die App wird dabei **nicht** aktiviert
   und der Tastaturfokus bleibt im Call (Diktat-Paste funktioniert weiter).
3. Call verlassen, **Teams bleibt offen** → binnen ~20 s stoppt die Aufnahme
   automatisch, die Pipeline läuft, die Notiz wird inklusive Zusammenfassung
   geschrieben.
4. Danach erscheint „Zusammenfassung fertig"; Klick öffnet die Markdown-Notiz.
5. Stummschalten im laufenden Call beendet die Aufnahme **nicht**.
6. „Immer für diese App" → der nächste Call derselben Quelle startet ohne
   Nachfrage; die Einstellung ist in Settings zurücksetzbar.
7. Ohne Benachrichtigungsberechtigung erscheint stattdessen das bisherige Panel;
   der gesamte Ablauf bleibt funktionsfähig.
8. Ist die CoreAudio-Prozessliste nicht verfügbar, verhält sich die Erkennung exakt
   wie heute (Fallback), ohne Absturz.
9. Manuell (Menü) gestartete Aufnahme **während** eines erkannten Calls endet mit
   dem Call; eine Aufnahme ohne jeden erkannten Call läuft weiter bis zum manuellen
   Stopp.

## 9. Risiken

- **App gibt das Mikrofon während des Calls frei.** Abgefedert durch die
  Oder-Bedingung mit der Ausgabe und 20 s Toleranz. Falls eine App beides freigibt
  (denkbar bei „Video/Audio aus"), endet die Aufnahme zu früh — dann ist der
  Schwellwert zu erhöhen oder die App auszunehmen. Nach realem Praxistest bewerten.
- **CoreAudio-Prozessflags unter Sandbox-/TCC-Sonderfällen leer.** Deshalb der
  harte Fallback auf das heutige Verhalten statt eines Crashs.
- **Benachrichtigungsaktionen sind erst beim Aufklappen sichtbar** (bekannter
  Nachteil gegenüber dem Panel, bewusst in Kauf genommen — D1). Die Standardaktion
  „Klick = Aufnehmen" federt das ab.

## 10. Messungen und Abweichungen bei der Umsetzung

Am Zielrechner gegen die echte CoreAudio-Prozessliste geprüft (42 Prozesse):

- **Bestätigt:** ein Prozess mit offenem Mikrofon meldet
  `kAudioProcessPropertyIsRunningInput = true` (mit einem eigens gestarteten
  Testprozess verifiziert). Das laufende, aber untätige **Teams meldet gar kein
  Flag** — genau der Fall, den die alte Erkennung den ganzen Tag als Meeting-
  Kandidat gewertet hat.
- **Abweichung 1 — Helper-Prozesse:** Teams meldet sich als
  `com.microsoft.teams2` *und* `com.microsoft.teams2.helper`, Chrome als
  `com.google.Chrome.helper`. Exaktes Vergleichen der Bundle-ID hätte für die
  meisten Calls nichts gefunden → Abgleich per **Präfix**
  (`AudioProcessSnapshot.matches`).
- **Abweichung 2 — Safari:** dessen Audio läuft als `com.apple.WebKit.GPU`, was
  *kein* Präfix von `com.apple.Safari` ist. Browser tragen deshalb eine Liste von
  Prozess-Bundle-IDs statt einer einzelnen.
- **Bestätigt die Ende-Regel:** Safari zeigte bei normaler Audiowiedergabe
  `output = true, input = false`. Würde für Browser die Ausgabe als „Call läuft
  noch" zählen, endete ein Browser-Call nie. Für Browser und Slack zählt daher nur
  das Mikrofon, für dedizierte Apps zusätzlich die Ausgabe (stummgeschaltet, hört
  aber weiter zu).

Offen (nur im echten Call prüfbar): Abnahmekriterien 1–6, insbesondere ob Zoom/
Teams das Mikrofon beim Stummschalten offen halten (§9, erstes Risiko).
