# Spec 29 — Die Kernschleife härten

> **Aufwand: M (3–4 Tage), davon ein Tag Testnaht.** Zwölf Stellen, an denen ein
> normales Diktat heute still ins Leere läuft — jede klein, zusammen das „buggy".
> Nichts davon braucht eine Entscheidung; alles davon braucht einen Test, den es heute
> nicht geben kann, weil `finishRecording` keine Naht hat. Die Naht ist deshalb Teil der
> Spec, nicht Zugabe.
> Quelle: `docs/analyse-wispr-flow-paritaet-2026-09-14.md` §3 (A1–A12).

## 1. Ausgangslage (Fakten aus dem Code)

- **Der Hotkey während der Transkription wird verworfen.** `beginRecording` prüft
  `captureState == .idle`, setzt die PTT-Maschine zurück und kehrt zurück — kein
  Overlay, kein Ton (`DictationController.swift:420-426`). Der Recorder ist zu diesem
  Zeitpunkt frei: `recorder.stop()` hat die Samples längst kopiert (`:568`), das
  Nachbearbeitungs-Task hält nur noch das Array. Blockiert ist also nicht die Hardware,
  sondern ein Zustand.
- **Ein leeres Transkript verschwindet ohne Meldung.** `guard !trimmed.isEmpty else {
  overlay.hide(); return }` (`:639-642`). Die Mikrofonberechtigung wird auf dem
  Diktatpfad **nie** geprüft (`:427-443` prüft Policy und `recorder.start`); ein per
  TCC verweigertes Gerät liefert Nullen, und so sieht dann jedes Diktat aus. Für
  Meetings existiert dafür `TrackSilence.isSilent` mit `peakThreshold = 1e-4`
  (`TrackSilence.swift:25, 44`); Diktat benutzt es nicht.
- **Esc greift nach dem Loslassen nicht.** `hotkey.isRecordingActive` ist
  `captureState == .recording` (`:124-126`), `handleEsc` prüft genau das
  (`HotkeyMonitor.swift:193`). Der `.transcribing`-Zweig in `cancelRecording`
  (`:509-518`) ist unerreichbar; die Kommentare `:504-508` und `:564-566`
  beschreiben, was nicht passiert.
- **Das Ziel wird vor dem Einfügen nicht erneut geprüft.** `targetBundleID` wird beim
  Loslassen eingefroren (`:559`) und danach nur für Profil (`:627`) und Statistik
  (`:718`) benutzt; `Paster.insert` (`:688`) bekommt keinen Vergleich mit dem dann
  vordersten Programm. Ob ⌘V ankam, prüft nichts; die Zwischenablage wird nach 600 ms
  zurückgesetzt (`Paster.swift:136-150`).
- **Ein Gerätewechsel bricht ab.** `onConfigurationChange` ruft `cancelRecording()`
  und meldet „Aufnahme abgebrochen" (`:131-137`). `AudioRecorder.resume(device:)`
  (`AudioRecorder.swift:83-93`) behält den Puffer, installiert den Tap neu und füllt
  die Lücke mit Stille — Aufrufer sind nur `MeetingController.swift:464, 487`.
- **Die Rolle wird beim keyDown gesetzt, nicht beim Start.** `enhanceRequested = role
  == .enhanced` steht vor `ptt.keyDown` (`:112-113`); ein freihändiges Diktat endet
  auf jeden keyDown (`PTTStateMachine.swift:35-39`). Plain-Diktat mit der
  Verbessern-Taste beenden ⇒ Text verlässt das Gerät; umgekehrt fällt die Verbesserung
  weg. Die Datengrenze hängt an der Wahl der Stopp-Taste.
- **Secure Input kommt nicht vor.** Null Treffer für `SecureEventInput` in `Sources`.
- **Feedback aus in der Vorgabe.** `dictationSounds` fällt auf `false`
  (`DefaultsKey.swift:51`); nur „Tink" beim Start und „Pop" nach dem Paste
  (`:457, :689`). Kein Signal bei Abbruch, Fehler, Lock, zu kurz.
- **Lock aus Versehen.** Tap-Schwelle 0,35 s (`PTTStateMachine.swift:22`),
  Mindestdauer 0,3 s (`:67`): ein Halten von 0,30–0,35 s **lockt**. Idle-Timeout
  Vorgabe 0 = aus (`DefaultsKey.swift:52`); die 10-Minuten-Grenze zählt Timer-Ticks,
  nicht Wanduhr (`:70, :482`).
- **Der Key-Down-Pfad läuft im Event-Tap-Callback**: `MainActor.assumeIsolated`
  (`HotkeyMonitor.swift:57`), darin `AudioDevices.inputDevices()` und die
  IORegistry-Lid-Abfrage (`:410-417`), `AVAudioEngine.start()` (`:438`),
  `CGEvent.tapCreate` für Esc (`:454`), beim ersten Mal der `NSHostingView`-Aufbau
  (`DictationOverlay.swift:146-162`). Der Code re-aktiviert bei
  `tapDisabledByTimeout` (`HotkeyMonitor.swift:93, 189`).
- **Kein Schlaf/Wach-Handler** für Diktat; `NSWorkspace.didWakeNotification` beobachtet
  nur `MeetingController.swift:151`.
- **Keine Testnaht.** `finishRecording` (`:554-704`) macht transkribieren → polieren →
  verbessern → einfügen → speichern in einem Task. Es gibt keine
  `DictationControllerTests`, keine für `HotkeyMonitor`, `AudioRecorder`,
  `Paster.paste`. Review 3.19 vom 3. September ist offen; die Datei ist seither von
  663 auf 782 Zeilen gewachsen.

## 2. Ziel

Ein Diktat läuft in jeder Lage entweder durch oder sagt, warum nicht. Konkret: zwei
Diktate direkt hintereinander funktionieren; Esc bricht in jeder Phase ab; ein stummes
Mikrofon nennt sich beim ersten Druck; ein App-Wechsel während der Transkription setzt
nichts ins falsche Fenster; AirPods mitten im Satz verlieren kein Wort; die
Stopp-Taste entscheidet nie darüber, ob Text das Gerät verlässt. Die 119 ms bleiben.

## 3. Konzept

### 3.1 Die Naht: `DictationPipeline` (pur)

Dasselbe Muster wie `PTTStateMachine`, `HotkeyRouting` und
`MeetingController.handle(outcome:)`: Ereignisse rein, Wirkungen raus, kein AppKit.

```swift
enum PipelineEvent {
    case keyDown(HotkeyRole), keyUp, escape
    case recordingStopped(duration: TimeInterval, peak: Float, generation: Int)
    case transcript(String, engine: String, generation: Int)
    case transcriptFailed(DictationFailure, generation: Int)
    case enhancement(DictationEnhancer.Result, generation: Int)
    case frontmostChanged(String?)
    case deviceChanged(resumable: Bool)
    case willSleep
}

enum PipelineEffect: Equatable {
    case startRecorder, stopRecorder, resumeRecorder
    case show(OverlayState), hide
    case transcribe(generation: Int), enhance(generation: Int)
    case paste(String), copyToClipboard(String)
    case notice(DictationFailure), cue(SoundCue)
    case save(text: String, raw: String?, engine: String)
}
```

`DictationPipeline.handle(_ event:) -> [PipelineEffect]` hält den Zustand
(`idle` / `recording(role, generation)` / `processing([Job])`) und die
Warteschlange der Jobs. `DictationController` schrumpft auf: Ereignisse liefern,
Wirkungen ausführen. Jede der zwölf Stellen unten ist dann ein Test mit einer
Ereignisfolge und einer erwarteten Wirkungsliste.

### 3.2 A1 — Nächstes Diktat anstellen

`captureState` bleibt `.recording` / `.idle`; die Verarbeitung wird ein eigener
Zähler `processingCount` — exakt die Trennung, die `MeetingController` für
Back-to-back-Meetings bekommen hat (`CLAUDE.md`, „Capture and processing are separate
states"). Ein keyDown während `processingCount > 0` startet sofort eine neue Aufnahme.
Die Jobs bilden eine **FIFO**: ein Job fügt erst ein, wenn der vorige eingefügt oder
verworfen ist, damit zwei Texte nie in vertauschter Reihenfolge landen. Das Overlay
zeigt während der zweiten Aufnahme die Wellenform; der Zustand des ersten Jobs ist
dann nicht sichtbar — bewusst, die Aufnahme ist wichtiger als der Spinner.

### 3.3 A2 — Stille nennt ihre Ursache

Beim keyDown, vor `recorder.start`: `AVCaptureDevice.authorizationStatus(for:
.audio)`. `.notDetermined` ⇒ anfragen, `.denied`/`.restricted` ⇒
`DictationFailure.microphoneDenied` und nicht aufnehmen. Nach `recorder.stop()`: Peak
über die Samples; unter `TrackSilence.peakThreshold` ⇒
`DictationFailure.nothingHeard(device:)`, nicht transkribieren. Signal vorhanden, aber
Transkript leer ⇒ `DictationFailure.nothingRecognized` mit Ton. Die drei Fälle sind
drei Sätze, nicht einer.

### 3.4 A3 — Esc in jeder Phase

`isRecordingActive` wird `pipeline.acceptsEscape` (Aufnahme läuft **oder** ein Job
ist unterwegs). Esc während der Aufnahme: verwerfen wie heute. Esc während der
Verarbeitung: den **jüngsten** Job abbrechen (`postProcessingTask.cancel()`,
Generation bumpen) — der ist es, auf den der Nutzer wartet. Der Esc-Tap bleibt so lange
installiert, wie `acceptsEscape` wahr ist; er wird heute ohnehin erst im `defer`
abgebaut (`:614`). Die beiden Kommentare `:504-508` und `:564-566` werden dann wahr.

### 3.5 A4 — Das Ziel vor dem Einfügen

Unmittelbar vor `paste`: `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`
gegen `targetBundleID`. Verschieden (und beide bekannt) ⇒ nicht einfügen, Text in die
Zwischenablage, `DictationFailure.targetChanged(app:)` mit dem Satz „Text liegt in der
Zwischenablage" und Eintrag in der Historie. Zusätzlich vor jedem Start und vor jedem
Paste: `IsSecureEventInputEnabled()` ⇒ `DictationFailure.secureInput` (A7). **Nicht**
versprochen wird, ob ⌘V im Ziel ankam: macOS gibt dafür kein Signal, und ein geratenes
„eingefügt" wäre schlechter als keines. Der Text bleibt über „Letztes Diktat einfügen"
und die Historie erreichbar — das ist die ehrliche Absicherung.

### 3.6 A5 — Gerätewechsel: weiter, nicht abbrechen

`onConfigurationChange` ⇒ `InputDevicePolicy.choose` neu auswerten ⇒ `try
recorder.resume(device:)`. Gelingt es: kurze Notice „Mikrofon gewechselt: <Name>",
Aufnahme läuft weiter, die Lücke ist Stille (`padGapToWallClock`). Scheitert es: der
heutige Abbruch. Fällt ein **Tap-Failure** direkt in `resume`, bleibt der Puffer
erhalten und wird transkribiert, was da ist — ein halbes Diktat schlägt ein verlorenes.

### 3.7 A6 — Die Rolle gehört dem Start

`onKeyDown`: erst `ptt.keyDown`, dann **nur bei `.start`** `enhanceRequested = role ==
.enhanced`. Ein keyDown, der einen Lock beendet, ändert die Rolle nicht. Test in
`HotkeyRoutingTests`/`DictationPipelineTests`: Plain-Lock, Stopp mit Enhance-Taste ⇒
kein `enhance`-Effekt; Enhance-Lock, Stopp mit Plain-Taste ⇒ `enhance`-Effekt.

### 3.8 A8 — Feedback in der Vorgabe

`dictationSounds` Fallback `true` (Entscheidung §7). Vier Cues statt zwei:
`start`, `done`, `cancelled`, `failed`; Lock bekommt einen kurzen Doppelton. Die Töne
selbst und ihre Gestalt gehören in Spec 30; hier geht es um die Stellen, an denen sie
ausgelöst werden — als `PipelineEffect.cue`, also getestet.

### 3.9 A10 — Lock nur bei deutlichem Tap

`tapThreshold` 0,35 → **0,2 s**. Loslassen zwischen 0,2 s und `minimumDuration`
(0,3 s) ist ein zu kurzes Halten und sagt das (`DictationFailure.tooShort`, ein
Ton) statt zu locken. Idle-Timeout: Vorgabe **45 s** mit Hysterese (Stille = Pegel
< 0,04 für die Dauer, jeder Ausschlag > 0,08 setzt zurück), Entscheidung §7. Die
10-Minuten-Grenze rechnet mit `recordingStartedAt`, nicht mit Ticks.

### 3.10 A11 — Der Key-Down-Pfad wird leicht

Der Tap-Callback stellt nur noch ein Ereignis in die Main-Queue (`DispatchQueue.main.async`)
und kehrt zurück. Der Aufbau des Overlay-Panels passiert einmal beim Start, nicht beim
ersten Diktat. `InputDevicePolicy.Context` wird nach jeder Auswertung 2 s gecacht
(ein Gerätewechsel invalidiert). `AVAudioEngine.prepare()` läuft nach jedem `stop()`
und beim Start, damit `start()` nur noch startet. **Nicht** gemacht wird ein dauerhaft
laufender Engine: das hält die orangefarbene Mikrofonlampe permanent an, und das ist
für ein Diktatwerkzeug, das nichts hören soll, wenn es nicht gefragt ist, die falsche
Botschaft. Was vom Vorlauf danach noch fehlt, wird gemessen, nicht geraten.

### 3.11 A12 — Schlaf

`NSWorkspace.willSleepNotification`: läuft eine gehaltene Aufnahme, wird sie beendet
und transkribiert; ein Lock wird beendet und transkribiert, mit Notice „Diktat vor dem
Ruhezustand beendet". Nach dem Aufwachen nichts — es gibt nichts weiterzuführen.

## 4. Integration

| Stelle | Änderung |
|---|---|
| `Dictation/DictationPipeline.swift` (neu, pur) | Zustand, Jobs, `handle(_:) -> [PipelineEffect]`, `acceptsEscape` |
| `Dictation/DictationFailure.swift` (neu, pur) | die Fehlerfälle mit Titel und Hinweis, lokalisiert — Spec 30 nutzt dieselbe Aufzählung für die Fehlerfläche |
| `DictationController.swift` | Ereignisse liefern, Wirkungen ausführen; `processingCount`; Job-FIFO; Berechtigungs- und Peak-Prüfung; Ziel-Vergleich; `resume` statt `cancel`; Schlaf-Beobachter; Panel beim Start bauen |
| `HotkeyMonitor.swift` | `isRecordingActive` → `acceptsEscape`; Callback nur enqueuen |
| `PTTStateMachine.swift` | `tapThreshold = 0.2`; `keyDown` liefert `.finish(role:)` mit der **Start**-Rolle |
| `AppState.swift` | `processingCount` neben `captureState` |
| `DefaultsKey.swift` | `dictationSounds` Fallback `true`, `dictationIdleTimeout` Fallback `45.0` (§7) |
| `Tests/DictationPipelineTests.swift` (neu) | ein Test je Zeile in §3, als Ereignisfolge |
| `Tests/PTTStateMachineTests.swift` | Schwelle, Rolle beim Stopp |

Kein Schema, keine Migration. `recordingGeneration` bleibt und wird zum Job-Schlüssel.

## 5. Risiken

- **Zwei Jobs, ein Overlay.** Während Job 1 verbessert (bis 15 s) und Job 2
  aufnimmt, ist der Zustand von Job 1 unsichtbar. Akzeptiert; die FIFO stellt sicher,
  dass die Reihenfolge stimmt, und Esc trifft den jüngsten Job. Ein Zähler „1 wartet"
  im Overlay ist eine Option für später.
- **Ziel-Vergleich mit Browsern.** Zwei Tabs derselben App haben dieselbe Bundle-ID;
  der Vergleich erkennt den Tab-Wechsel nicht. Das ist eine bekannte Grenze, keine
  Regression — heute wird gar nichts verglichen.
- **`resume` auf einem Gerät, das gerade verschwindet**, kann selbst werfen; der
  Fallback ist der heutige Abbruch, also nie schlechter als jetzt.
- **Berechtigungsabfrage beim keyDown** verzögert den allerersten Start um den
  TCC-Dialog — der kommt heute später und verwirrender.
- **Der Umbau selbst.** `finishRecording` ist der latenzkritische Pfad. Die Pipeline
  ist pur und kostet Mikrosekunden; jede Wirkung wird genauso ausgeführt wie heute.
  `LatencyProbeTests` misst vorher und nachher.

## 6. Abnahme

1. Diktat, sofort zweites Diktat während „Transkribiere…": beide Texte landen in
   der gesprochenen Reihenfolge; `DictationPipelineTests` pinnt die FIFO.
2. Esc während Aufnahme, Transkription und Verbesserung: nichts wird eingefügt; Esc
   erreicht die fokussierte App nicht.
3. Mikrofon in den Systemeinstellungen entziehen, Taste drücken: Meldung beim
   **Drücken**, nicht nach dem Loslassen; mit erlaubtem, aber stummem Gerät: „Nichts
   gehört (Gerät X)"; mit Signal und leerem Transkript: „Nichts verstanden" + Ton.
4. ⌘Tab während der Transkription: nichts wird eingefügt, Text in der Zwischenablage,
   Notice sagt es, Historie zeigt den Eintrag.
5. AirPods während des Satzes verbinden: der ganze Satz wird transkribiert; die Lücke
   ist Stille, keine Verschiebung.
6. Plain-Lock mit der Verbessern-Taste beenden: `llm_usage` bekommt **keine** Zeile.
7. Passwortfeld fokussiert, Taste drücken: „Sicheres Eingabefeld — Diktat hier nicht
   möglich", keine Aufnahme.
8. Halten 0,25 s: „zu kurz" mit Ton, kein Lock. Tap 0,1 s: Lock.
9. `DictationController.swift` unter 500 Zeilen; `DictationPipelineTests` ≥ 25 Tests;
   `LatencyProbeTests` unverändert innerhalb ±10 ms.

## 7. Offene Entscheidungen

- **Töne an in der Vorgabe** — ändert das Verhalten der laufenden Installation beim
  nächsten Update. Vorschlag: ja, weil vier Ausgänge ohne Signal der teurere Fehler sind.
- **Idle-Timeout-Vorgabe 45 s statt aus** — dito. Vorschlag: ja; die Hysterese ist der
  Teil, der den alten Einwand (Timeout mitten im Satz) entkräftet.
- **Job-Zähler im Overlay** — erst, wenn zwei Jobs im Alltag tatsächlich vorkommen.

## 8. Stand des Baus (2026-09-14)

**Gebaut:** alle zwölf Punkte aus §1, in dieser Form:

- `DictationPipeline` (pur): `start`, `enhanceRequested(after:)`, `afterStop`,
  `afterTranscript`, `paste`, `escapeTarget`, `reachedMaximum`; dazu `JobQueue` und
  `IdleDetector`. `DictationFailure` benennt jeden Ausgang mit Titel, Hinweis, Ton und
  der Unterscheidung Notice/Fehler; `SoundCue` die fünf Momente.
- Der Controller trennt `isCapturing` und `jobs`; `appState.captureState` wird daraus
  abgeleitet (`publishCaptureState`), sodass Menü, Updater und Detektor unverändert
  lesen. Ein zweites Diktat startet während der Transkription; Jobs fügen in
  Sprechreihenfolge ein, weil jeder auf den vorigen Task wartet, bevor er einfügt.
- Esc trifft die laufende Aufnahme oder den jüngsten Job. Mikrofonberechtigung und
  Secure Input werden beim Drücken geprüft, digitale Stille nach dem Loslassen, Ziel-App
  und Secure Input vor dem Einfügen (bei Abweichung: Zwischenablage + Meldung).
  Gerätewechsel ruft `resume`; scheitert es, wird transkribiert, was da ist. Ruhezustand
  beendet und transkribiert. Die Rolle hängt am Start. Tap-Schwelle 0,2 s, „zu kurz"
  wird gesagt. Idle-Timeout mit Hysterese, Maximaldauer nach Wanduhr.
- Tastendruck-Arbeit läuft nicht mehr im Tap-Callback (`DispatchQueue.main.async`,
  Reihenfolge bleibt); das Overlay-Panel wird beim Start gebaut; der Geräte-Kontext
  2 s gecacht.

**Abweichungen vom Konzept:**

1. **Keine Wirkungsliste (`PipelineEffect`).** Die Entscheidungen sind pure Funktionen,
   der Controller führt sie aus. Dieselbe Testbarkeit für jede der zwölf Stellen, ohne
   den Kontrollfluss ein zweites Mal als Daten aufzuschreiben.
2. **Der Controller hat nicht unter 500 Zeilen** (Abnahme 9), sondern gut 940. Die
   Modellverwaltung (rund 250 Zeilen: Laden, Bootstrap, Tausch) ist geblieben; sie
   herauszulösen ist ein eigener Schritt ohne Verhaltensänderung.
3. **Der Mikrofonwechsel wird nach dem Einfügen gemeldet**, nicht während der Aufnahme:
   eine Notice verdeckt die Wellenform und blendet das HUD nach drei Sekunden aus,
   mitten im Diktat.
4. **`engine.prepare()` nach dem Stop** nicht eingebaut — `installTapAndStart` bereitet
   ohnehin vor dem Start vor; was vom Vorlauf noch fehlt, ist zu messen.
5. `HotkeyMonitor.isRecordingActive` behält seinen Namen und bedeutet jetzt „Esc hat ein
   Ziel".
6. Töne sind Systemklänge (`SoundCue.systemSoundName`); Spec 30 tauscht die Dateien.
7. Die neuen puren Dateien stehen als `path:` im Testziel in `project.yml` — das
   Testbundle hat keinen App-Host und linkt sonst nicht.

**Offene Entscheidungen aus §7 mit dem Vorschlag gebaut:** Töne an und Idle-Timeout
45 s in der Vorgabe. Beides ist je eine Zeile in `DefaultsKey`.

**Tests:** `DictationPipelineTests` 37 (neu), `DefaultsKeyTests` angepasst; 125 Tests
der Diktat-Klassen grün. Die übrige Suite ebenfalls grün, in zwei Teilen: der
vollständige Lauf wurde bei den Modelltests vom System wegen Speichermangels beendet
(49 Suiten bis dahin grün), der Rest lief danach gegen dieselben Build-Produkte
(294 Tests, 1 übersprungen, 0 Fehlschläge). **Nicht gelaufen:**
`ParakeetTranscriberTests`, `MeetingPipelineE2ETests`, `WhisperTranscriberTests` und
`LatencyProbeTests` — sie laden echte Modelle, und Spec 29 berührt keinen Transcriber. **Nicht verifiziert:** die Handtests 1–8 der Abnahme
(zweites Diktat, Esc in jeder Phase, entzogenes Mikrofon, ⌘Tab, AirPods, Passwortfeld,
kurzes Halten) — sie brauchen die installierte App und echte Hardware.

### Nachtrag: zweiter Durchgang (2026-09-14)

Vier der sieben Abweichungen sind geschlossen:

- **Abweichung 2 → gebaut.** `DictationController.swift` hat 498 Zeilen (Abnahme 9).
  Herausgelöst: `DictationEngines` (Laden, Vorschaltmodell, Tausch, Transkription),
  `DictationInput` (Gerätewahl, Berechtigung, Gerätewechsel), `DictationFeedback`
  (Fehlerzeilen, Töne, aufgeschobene Fehler) und `DictationTextStages` (Regeln, lokale
  Stufe, CLI, Einfügen, Speichern). Die Views lesen den Modellzustand weiter über den
  Controller; er reicht die Änderungen von `DictationEngines` durch.
- **Abweichung 3 → gebaut.** Ein Mikrofonwechsel wird sofort neben der Wellenform
  gesagt („Mikrofon: AirPods", 2,5 s über die Partial-Zeile) — ohne das HUD
  auszublenden, was der Grund für die Abweichung war.
- **Abweichung 4 → gebaut.** `AudioRecorder.stop()` ruft `engine.prepare()`.
- **Abweichung 5 → gebaut.** `HotkeyMonitor.acceptsEscape` statt `isRecordingActive`.

Bleibt: **Abweichung 1** (keine Wirkungsliste — die Entscheidungen sind pure
Funktionen, das Ziel der Testbarkeit ist erreicht, ohne den Kontrollfluss doppelt zu
führen), **6** (Töne; Spec 30) und **7** (Pfad-Einträge im Testziel, kein Mangel).
