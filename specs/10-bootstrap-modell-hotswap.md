# Spec 10 — Bootstrap-Modell & unterbrechungsfreier Modellwechsel

> **Aufwand: M.** Notable startet mit einem kleinen Modell, das in Sekunden benutzbar
> ist, lädt das eigentlich gewählte im Hintergrund und tauscht den Transcriber im
> laufenden Betrieb.
> **Gilt nur für kalte Modell-Caches** — bei warmem Cache unsichtbar. Relevant wird es
> durch die DMG-/Release-Verteilung: der erste Start beim Empfänger ist heute minutenlang
> tot.

## 1. Ausgangslage (Fakten aus dem Code)

- `DictationController` hält bereits **drei getrennte Engine-Slots** — `engineTask`,
  `streamTask`, `whisperTask` (`DictationController.swift:38-41`) — mit je eigenem
  Ladezustand (`v3State`/`streamState`/`whisperState`, `:57-60`), gespiegelt über
  `publishModelState()` nach `@Published modelState`. Das *ist* bereits das
  Zwei-Slot-Prinzip, nur ohne den Vorschalt-Gedanken: es gibt keinen Slot, der einspringt,
  während der gewählte noch lädt.
- Der Erststart lädt Parakeet v3 über `ParakeetModelCache.shared.transcriber()` →
  `ParakeetTranscriber.prepare()` → `AsrModels.downloadAndLoad()`
  (`ParakeetTranscriber.swift:17`) — **ohne `progressHandler`**, obwohl FluidAudio einen
  anbietet (`AsrModels.download(to:force:version:encoderPrecision:progressHandler:)`,
  `ProgressHandler = @Sendable (DownloadProgress) -> Void`).
- Diktiert man währenddessen, zeigt `finishRecording` das Overlay im Zustand
  `.loadingModel` (`DictationController.swift:340`) und `await`t dann `engineTask.value`:
  der Text erscheint erst, wenn der komplette Download fertig ist. Kein Abbruch, keine
  Alternative, nur Warten — bei mehreren GB sind das Minuten mit gedrückter Taste im Rücken.
- **Whisper Tiny ist ein fertiger Bootstrap-Kandidat**: mehrsprachig (nicht `.en`), ~75 MB,
  bereits als vollwertige Engine implementiert (`WhisperTranscriber`, `WhisperModelSize.tiny`,
  `WhisperTranscriber.swift:6-33`). Kein neuer Abhängigkeitspfad, kein neues Modellformat.
- `engineChanged()` (`:133`) verwirft eine laufende Aufnahme über `discardActiveRecording`.
  Für einen **Nutzer**-Wechsel ist das richtig; für einen **automatischen** Upgrade-Tausch
  wäre es falsch — er darf nie ein Diktat kosten.

## 2. Ziel

Ein Start mit kaltem Modell-Cache ist nach ~1 Minute diktierfähig statt nach dem
vollständigen v3-Download. Der Wechsel auf das gewählte Modell passiert im Hintergrund
und unterbricht kein Diktat.

Explizit **kein** Ziel ist bessere Qualität oder Geschwindigkeit im Normalbetrieb — bei
warmem Cache ändert diese Spec nichts.

## 3. Konzept: aktive vs. gewählte Engine

- `ASREngineID.current` (`EnglishStreamingTranscriber.swift:15`) bleibt, was es ist: der
  **Wunsch** des Nutzers aus `@AppStorage`.
- Neu: `activeEngine` — was gerade **tatsächlich** transkribiert. Im Normalfall identisch.
  Weicht nur ab, solange das gewählte Modell nicht bereit ist **und** ein Bootstrap-Slot
  bereitsteht.
- **Bootstrap-Regel beim Start:** Ist das gewählte Modell lokal vorhanden
  (`AsrModels.modelsExist(at:version:encoderPrecision:)` bzw. WhisperKit-Cache-Pfad)?
  - ja → alles wie heute, kein Bootstrap, kein Zusatzspeicher.
  - nein → Whisper Tiny laden **und parallel** das gewählte Modell holen;
    `activeEngine = .whisper(tiny)`, sobald Tiny bereit ist.
- **Tausch:** Sobald das gewählte Modell `.ready` meldet →
  `activeEngine = ASREngineID.current`, **aber nur wenn** `appState.captureState == .idle`.
  Sonst `pendingSwap = true`, und der Tausch passiert am Ende von `finishRecording`, nach
  dem Einfügen. Nie mitten in einer Aufnahme, nie zwischen
  Aufnahme und Paste.
- **Nach dem Tausch** wird der Bootstrap-Slot freigegeben (Task auf `nil`), damit die
  ~120 MB RSS-Baseline nicht dauerhaft um ein zweites Modell wächst.

## 4. Integration

- **`ParakeetTranscriber.prepare()`** — `progressHandler:` an `downloadAndLoad` durchreichen
  und nach oben melden. Das ist ein eigenständiger Gewinn (siehe Spec 11 §2) und die
  Voraussetzung dafür, dass „lädt noch" überhaupt eine Zahl bekommt.
  Der Handler muss über `ParakeetModelCache` laufen (der Cache teilt eine Ladung zwischen
  Diktat und Meeting — der Fortschritt darf nicht doppelt registriert werden).
- **`ModelState`** — heute `.loading | .ready | .failed(String)` (`:8-20`), `Equatable`, und
  in `NotableApp.swift:237` per `!= .ready` abgefragt. Fortschritt anzuhängen (`.loading(Double?)`)
  bricht diese Vergleiche; sauberer ist ein **separates** `@Published downloadProgress: Double?`
  neben `modelState`, dann bleibt jede bestehende Verzweigung gültig.
- **`DictationController`** — neu: `activeEngine`, `bootstrapTask`, `pendingSwap`.
  `rawTranscript` (`:398-421`) schaltet auf `activeEngine` statt `ASREngineID.current`;
  der `selectedTaskMissing`-Retry (`:341-349`) bleibt an `current` hängen, denn er soll das
  **gewählte** Modell nachladen.
- **Entscheidungslogik als pure Funktion**: `BootstrapPolicy.decide(...) -> Action`
  (`.useSelected`, `.useBootstrap`, `.swapNow`, `.deferSwap`) — testbar ohne Modelle, Muster
  `PTTStateMachine`.
- **Overlay** — `.loadingModel` erscheint künftig nur noch, wenn **auch** der Bootstrap nicht
  bereit ist.
- **`OnboardingView`** — der Modell-Schritt zeigt den Bootstrap-Zustand („du kannst schon
  diktieren, das große Modell lädt noch: 42 %") statt eines reinen Wartebalkens.

## 5. UI / Sichtbarkeit — kein stilles Versagen

- **Menü** statt „ASR-Modell wird geladen…": „Vorläufiges Modell aktiv (Whisper Tiny) —
  Parakeet v3 lädt: 42 %".
- **Overlay während eines Bootstrap-Diktats** muss den Zustand kennzeichnen. Ohne Hinweis
  wundert man sich über schlechte Ergebnisse und hält das für Notables Normalqualität —
  Tiny ist deutlich schwächer als v3, und der Text wird trotzdem eingefügt.
- **Nach dem Tausch** eine einmalige, unaufdringliche Meldung („Parakeet v3 aktiv").
- **Settings → Diktat**: Toggle „Beim ersten Start ein kleines Modell vorschalten"
  (Default: **an**). Aus = Verhalten von heute.

## 6. Edge Cases

- **Bootstrap-Download scheitert** → Verhalten wie heute (warten), Fehler sichtbar. Der
  Bootstrap darf nie zur zusätzlichen Fehlerquelle werden.
- **Gewählte Engine ist bereits Whisper Tiny** → kein Bootstrap.
- **Nutzer wechselt die Engine während des Bootstraps** → `pendingSwap` zurücksetzen,
  Bootstrap gilt weiter, Ziel ist die neue Auswahl.
- **Meetings nie im Bootstrap.** Die Meeting-Pipeline hängt an `ParakeetModelCache` und
  braucht v3 (Qualität + Zusammenspiel mit der Diarisierung). Ein Meeting mit Tiny zu
  transkribieren wäre schlechter, als es zu verschieben — der Meeting-Pfad wartet weiterhin
  auf v3 und meldet das.
- **`recordingGeneration`** in allen neuen Callbacks prüfen (Muster im ganzen Controller).
- **Speicher/ANE**: zwei Modelle gleichzeitig geladen, aber nur kurz und nur eines davon ist
  klein. Nach dem Tausch freigeben und RSS gegen die Baseline (~120 MB) messen.

## 7. Tests

- `BootstrapPolicy`-Unit-Tests: kein Bootstrap bei vorhandenem Modell; Bootstrap bei fehlendem;
  Tausch während `.recording` wird aufgeschoben und danach ausgeführt; Engine-Wechsel während
  Bootstrap setzt `pendingSwap` zurück.
- Controller-Test mit Fake-Transcribern: `rawTranscript` nutzt vor dem Tausch den Bootstrap-,
  danach den Ziel-Transcriber.
- Manuell (der eigentliche Beweis): FluidAudio-/WhisperKit-Cache löschen, Erststart, nach
  <1 Minute diktieren → Text kommt, gekennzeichnet als vorläufig; später Tausch-Meldung;
  danach Qualität wie gewohnt. Einmal mit laufender Aufnahme im Moment des Tauschs.

## 8. Umsetzungsschritte

1. `progressHandler` durchreichen + Fortschritt sichtbar machen — eigenständiger Gewinn,
   auch ohne Bootstrap (deckt Spec 11 §2 mit ab).
2. `BootstrapPolicy` + `activeEngine` + `pendingSwap`, ohne UI.
3. UI-Kennzeichnung (Overlay, Menü, Onboarding) + Tausch-Meldung.
4. Toggle in Settings, Default an.
5. Cache-Wipe-Test vor dem nächsten Release-Build.

## 9. Nicht-Ziele

- **Kein Bootstrap für Meetings.**
- Kein automatischer Qualitäts-Downgrade im Normalbetrieb — Bootstrap greift ausschließlich
  bei fehlendem Modell.
- Keine Änderung der Standard-Engine und keiner bestehenden Engine-Semantik.
- Kein eigener Downloader: FluidAudio und WhisperKit laden weiter selbst, wir hören nur zu.
