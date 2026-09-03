# Code-Review Notable — 3. September 2026

Stand: `main` bei `83fc898` (Release v1.0.1). Rund 24 000 Zeilen Swift, 481 Tests.

Vorgehen: fünf unabhängige Reviews, je ein Bereich vollständig gelesen (Diktat, Meeting, Storage/Stats, Provider/Update/Berechtigungen, UI/Settings). Jeder Befund wurde am Code verifiziert; die mit **(bestätigt)** markierten habe ich zusätzlich selbst im Code oder auf dem System nachgeprüft. Zeilenangaben beziehen sich auf den genannten Stand.

Bewusste Entscheidungen aus `CLAUDE.md` (kein Sandbox, Whole-Clip statt Streaming als Default, Opt-in-Retention, CLI-only für Diktat-Verbesserung, …) sind nicht in Frage gestellt. Aufgeführt ist aber, wo der Code hinter dem zurückbleibt, was `CLAUDE.md` behauptet.

---

## 1. Gesamtbild

**Was gut ist.** Die Architektur trennt sauber zwischen puren, getesteten Entscheidungskernen (`PTTStateMachine`, `HotkeyRouting`, `BootstrapPolicy`, `EnhancementGuard`, `SmartReplace`, `UsageMetrics`, `RetentionPlanner`, `NotesMarkdown`) und dünnen AppKit/CoreAudio-Hüllen. Fehlerpfade schützen das Diktat (`enhance` wirft nie, `Paster` lässt den Text bei fehlender Bedienungshilfe in der Zwischenablage, `installTapAndStart` räumt den Tap bei Fehlschlag ab). Die Statistik ist ehrlich (nullable Messspalten, Median/p95, `billed` getrennt von Schattenkosten). Die Datenschutz-Texte stehen dort, wo die Entscheidung fällt. Crash-Sicherheit ist geschichtet (PCM-Spool, atomare Meta-Datei, `notes.md`-Spiegel, Recovery beim Start, `spool-failed` statt Löschen).

**Wo die Probleme liegen.** Weniger im Design als in drei Klassen:

1. **Randpfade ohne Testnaht.** `DictationController.finishRecording` (150 Zeilen) und `MeetingController.produceNote` (privat, MainActor) sind nicht testbar; genau dort sitzen die Logikfehler (Bootstrap-Swap, verlorene Warnungen bei Recovery, Doppel-Meetings).
2. **Doku verspricht mehr als der Code hält.** Inkrementelles Dekodieren, `recordingGeneration`-Prüfung, „Verbindung testen“ für alle CLI-Provider, Lokalisierungs-Scanner „fängt jedes Literal“, Capture-Warnung bei Recovery — alles in `CLAUDE.md` beschrieben, im Code nicht (mehr) vorhanden.
3. **Zwei Vertrauensgrenzen sind offen:** Transkripte liegen ungewollt außerhalb der App, und der Updater installiert ungeprüfte Bundles.

---

## 2. Die zehn wichtigsten Punkte

| # | Befund | Datei | Bereich |
|---|---|---|---|
| 1 | Jede CLI-Zusammenfassung landet als Transkript in `~/.claude/projects/` **(bestätigt)** | `ClaudeCodeCLIProvider.swift:58` | Datenschutz |
| 2 | Auto-Update installiert ein ungeprüftes Bundle; Swap-Skript kann die laufende App zerstören | `UpdateInstaller.swift:104-134, 193-207` | Sicherheit/Stabilität |
| 3 | Konvertierung, Lock und Datei-I/O im CoreAudio-Echtzeit-Thread **(bestätigt)** | `SystemAudioTap.swift:115`, `PCMDownsampler.swift:54-144` | Stabilität/Genauigkeit |
| 4 | Während `processing` keine neue Aufnahme möglich, Doppel-Meetings gehen verloren **(bestätigt)** | `MeetingController.swift:94, 113, 270` | Logik |
| 5 | Verzögerter Bootstrap-Swap kann nie ankommen | `DictationController.swift:626` | Logik |
| 6 | Füllwort-Entfernung löscht Satzzeichen **(bestätigt)** | `TextPolisher.swift:152` | Genauigkeit |
| 7 | Eigene Verbesserungsprofile wachsen bei jedem Speichern um die Grundregeln **(bestätigt)** | `EnhancementSettingsSection.swift:188` | Logik |
| 8 | Whisper-Tiny-Diktate werden als gewählte Engine verbucht | `DictationController.swift:608` | Statistik |
| 9 | Suche: Titel-Treffer fächern pro Segment auf; ASCII-only Case-Folding | `RecordingStore.swift:464-481` | Logik/Performance |
| 10 | Task-Abbruch erreicht den CLI-Prozess nie; Kinder erben Launchd-PATH | `CLIProcessRunner.swift:59-68` | Stabilität |

Details zu jedem Punkt in den Bereichs-Kapiteln.

---

## 3. Diktat-Pfad (`Sources/Notable/Dictation/`)

### 3.1 Verzögerter Bootstrap-Swap kann nie ankommen
`DictationController.swift:626` ruft `if pendingSwap { updateActiveEngine() }` **innerhalb** des Task-Bodys auf, bevor das `defer` (`:537-539`) `captureState = .idle` setzt. `updateActiveEngine` (`:190`) sieht `.transcribing`, entscheidet `.deferred` und setzt `pendingSwap` erneut. Danach ruft nichts mehr auf: `cancelRecording()` (`:457`), der Kurz-Clip-Return (`:507`), der Leer-Transkript-Return (`:547`) und der `catch` (`:627`) prüfen nicht. Wird Parakeet v3 während einer Aufnahme fertig, bleibt der Nutzer bis zum Engine-Wechsel oder Neustart auf Whisper Tiny („vorläufig“, zwei Modelle resident).
**Fix:** Prüfung ins `defer` nach `.idle` verschieben; zusätzlich am Ende von `cancelRecording()` aufrufen.

### 3.2 Füllwort-Entfernung löscht Satzzeichen (bestätigt)
`TextPolisher.swift:152`: Muster `(^|\s)filler[,.]?(?=\s|$)`. „Das ist gut äh. Dann weiter.“ → „Das ist gut  Dann weiter.“ Parakeet setzt Satzzeichen; damit verliert `ParagraphFormatter` seine Satzgrenzen und jede „Kommando nach Satzzeichen“-Regel greift nicht mehr.
**Fix:** `(^|\s)filler,?(?=[\s.!?;:]|$)` — `tidy` entfernt das Leerzeichen vor dem Satzzeichen bereits.

### 3.3 `tidy` kapitalisiert camelCase-Anfänge
`TextPolisher.swift:181-182`: „iPhone ist gut“ → „IPhone ist gut“ (ebenso macOS, eBay). `ParagraphFormatter.capitalizingFirstWord` (`:291-297`) hat den richtigen Guard (nur wenn das erste Wort komplett klein ist).
**Fix:** den Helper teilen.

### 3.4 Englische ITN schreibt Ordinal-Idiome um
`TextPolisher.swift:686-692`: `matchOrdinal` überspringt nur „a/an“ davor. „First of all“, „at first“, „second thoughts“, „third party“ werden zu „1st of all“, „at 1st“, „2nd thoughts“. ITN ist per Default an.
**Fix:** alleinstehende `first/second/third` nur in Kompositum („twenty first“), nach Monat oder nach „the“ + vor Nomen konvertieren; Blockliste „of all“, „thoughts“, vorangehendes „at“.

### 3.5 `EnhancementGuard.metaPrefixes` verwirft legitime deutsche Anfänge
`DictationEnhancer.swift:118-131`: „gerne“ und „natürlich,“ sind extrem häufige erste Wörter einer diktierten Mail („Gerne schicke ich dir …“). Jede solche Verbesserung wird still verworfen („Verbesserung verworfen“), obwohl die CLI aufgerufen wurde und der Text das Gerät verlassen hat.
**Fix:** ein Präfix nur als Meta werten, wenn die erste Zeile mit `:` endet („Hier ist die überarbeitete Version:“), oder `gerne`/`natürlich,`/`revised` streichen.

### 3.6 CLAUDE.md behauptet inkrementelles Dekodieren; der Code macht Whole-Clip (bestätigt)
`DictationController.swift:447-451` und `rawTranscript` (`:634-662`) berühren `DictationSession` nie. `ParakeetTranscriber.makeSession` (`:31`), `IncrementalDictation.swift`, `DictationOverlayController.updatePartial` (`:86`), `Model.partial` und `AudioRecorder.snapshot()` werden nur aus Tests erreicht. Auch `EnglishStreamingTranscriber` („echtes Streaming“) bekommt in Produktion den ganzen Clip nach dem Loslassen. Ein 60-s-Diktat zahlt ~400 ms (Whisper deutlich mehr); der „Live-Partial“-Zweig des Overlays ist tote UI.
**Fix:** entweder `feedStableHead` in den Level-Timer verdrahten (v3) bzw. `feed` während der Aufnahme (Unified), oder Session-Code + Partial-UI löschen und CLAUDE.md korrigieren.

### 3.7 Enhancement-Deadline stoppt die CLI nicht; Esc kann Enhancing nicht abbrechen
`DictationEnhancer.swift:236-250` bricht den Swift-Task ab, aber `CLIProcessRunner.run` (`Support/CLIProcessRunner.swift:53-58`) ist ein `withCheckedThrowingContinuation` ohne Cancellation-Handler mit 300 s Default-Timeout (`ClaudeCodeCLIProvider.swift:55` übergibt keinen). Nach „dauerte zu lange“ läuft `claude -p` minutenlang weiter; ein Retry startet einen zweiten. Während `.enhancing` (bis 60 s) ist `cancelRecording` ein No-op (`:458` verlangt `.recording`), der Esc-Tap ist bereits weg (`:496`).
**Fix:** `timeout: deadline` an `run` übergeben, Continuation in `withTaskCancellationHandler { process.terminate() }` wickeln, Esc-Tap durch `.transcribing` hindurch halten und den Task abbrechen.

### 3.8 Freihand-Stopp pastet, während der Modifier noch physisch gedrückt sein kann (auf Hardware prüfen)
`PTTStateMachine.swift:35-39` beendet bei Key-*Down*; bei 5 s Clip und ~119 ms Latenz kann das ⌘V aus `Paster.swift:118-127` vor dem Loslassen gepostet werden. Events an `.cghidEventTap` bekommen den Hardware-Modifier-State gemischt; die Ziel-App sieht ⌥⌘V und ignoriert es. 600 ms später entfernt die Pasteboard-Restaurierung (`:101-115`) den Text auch aus der Zwischenablage.
**Fix:** bei Stopp aus Lock auf `HotkeyMonitor.heldRole == nil` warten (max. ~400 ms) oder via `.cgSessionEventTap` posten.

### 3.9 `recordingGeneration` wird nur geschrieben
`DictationController.swift:76, 406, 459, 505` inkrementieren; nichts liest. Der Doc-Kommentar behauptet „async work checks it after each await“. Heute kein Live-Bug, weil `hotkeyChanged()`/`engineChanged()` während `.transcribing` nichts tun, aber das versprochene Sicherheitsnetz fehlt.
**Fix:** im Task capturen und vor `Paster.insert` und `saveDictation` prüfen, oder löschen.

### 3.10 Plain-`String`-Nutzertexte, die nie lokalisiert werden (bestätigt)
`DictationController.swift:137, 161` (`setupError`), `:168`, `:194`, `:384`, `:403`, `:431`, `:443`, `:629`, `:645/650/658`; `NotchOverlayView.statusText` (`DictationOverlay.swift:422-424` — „Transkribiere…“ hat einen englischen Eintrag, wird als plain String aber nie nachgeschlagen); `accessibilityText` (`:296-297`); `Paster.swift:16`; `WhisperTranscriber.swift:114`; `DictationEnhancer.swift:228`. `hotkeyChanged()` (`:154`) macht es richtig, direkt daneben `engineChanged()` (`:168`) nicht.
**Fix:** `String(localized:)` überall; Scanner-Regex um `flashError("`, `flashNotice("`, `setupError = "`, `errorDescription`-Bodies erweitern.

### 3.11 Pasteboard-Snapshot kopiert synchron jede Repräsentation auf dem Hot Path
`Paster.swift:82-90` ruft `item.data(forType:)` für alle Typen aller Items vor dem ⌘V; ein großes Bild oder ein File-Promise-Typ kostet hunderte ms auf dem Main-Thread innerhalb des Release→Paste-Budgets (und löst Promise-Seiteneffekte aus).
**Fix:** Promise-/große Binärtypen überspringen oder Gesamtbytes deckeln, Fallback „nur String wiederherstellen“.

### 3.12 Polish läuft auf dem Main-Actor mit Regex-Kompilierung pro Aufruf
`DictationController.swift:545` führt `TextPolisher.polish` im `@MainActor`-Task aus: `NLLanguageRecognizer`, 11 Füllwort-Muster, ein Regex pro Wörterbucheintrag, 4 in `tidy`, bis 5×12 in `ParagraphFormatter.applyingCommands` (`:98-107`) + 10 Ordinale, alle über `replacingOccurrences(options: .regularExpression)` (jedes Mal kompiliert). Millisekunden, aber auf dem Main-Thread zwischen Release und Paste.
**Fix:** als `static let NSRegularExpression` vorkompilieren; `polish` in einem Detached Task (ist pur).

### 3.13 `beginEscInterception` scheitert stumm
`HotkeyMonitor.swift:151`: kann der aktive Tap nicht erzeugt werden (Bedienungshilfen fehlen), sagt das Overlay trotzdem „Esc verwirft“ und Esc tut nichts. `stop()`/`endEscInterception()` (`:76-87, 161-170`) rufen nie `CFMachPortInvalidate`.
**Fix:** Bool zurückgeben und wie `start()` anzeigen; Ports explizit invalidieren.

### 3.14 Stille Fehler bei Persistenz und Hinweisen
`DictationController.swift:604` `try? saveDictation` verliert History und Statistik spurlos; `:589-591` zeigt den Auto-Stopp-*Hinweis* über `flashError` (Warnsymbol), obwohl `flashNotice` existiert; `DictationHistory.swift:130` `try? Paster.insert` schluckt den Bedienungshilfen-Fehler für den Notification-Button.

### 3.15 `retryLoad(_:)` ignoriert sein Argument
`DictationController.swift:239-246` leert den übergebenen Slot, `loadSelectedModel()` lädt aber `ASREngineID.current`. `retryLoad(.whisper)` bei gewähltem v3 leert Whisper und lädt nichts. Harmlos nur, weil `EngineStatusRow` die gewählte Engine übergibt.

### 3.16 `FuzzyDictionary.minKeyLength = 4` ist unerreichbar
`TextPolisher.swift:312-314`: mit Schwelle 0,85 und Distanz ≤ 2 braucht ein 1-Edit-Match ≥ 7 Zeichen, ein 2-Edit-Match ≥ 14. `testFuzzyDictionaryIgnoresShortKeys` besteht aus dem falschen Grund.
**Fix:** Konstante auf 7 setzen und begründen, oder Schwelle bewusst senken.

### 3.17 `PCMDownsampler` teilt ungeschützten State mit dem Audio-Thread
`Support/PCMDownsampler.swift:55-58` liest/schreibt `converter`/`sourceFormat` außerhalb des Locks, `reset()` (`:36-52`) schreibt sie darunter. Sicher nur, weil `reset` immer vor der Tap-Installation kommt — eine Invariante, die kein Kommentar nennt. Außerdem eine `AVAudioPCMBuffer`-Allokation und eine skalare RMS-Schleife pro Puffer (`:63, :84`).
**Fix:** Reihenfolge dokumentieren (oder unter den Lock), Ausgabepuffer wiederverwenden, `vDSP_rmsqv`.

### 3.18 `MediaInterrupter.end()` kann Wiedergabe starten
`MediaInterrupter.swift:49-52` sendet Play/Pause erneut, wann immer es pausiert hat; ein Podcast, der während eines langen Diktats von selbst endete, startet den nächsten.
**Fix:** Resume mit `!somethingIsPlaying()` absichern.

### 3.19 `DictationController` ist ein 663-Zeilen-Gott-Objekt
`loadSelectedModel` (`:314-378`) plus `startBootstrapIfNeeded` (`:283-312`) sind vier fast identische Task/State-Blöcke; `finishRecording` (`:482-632`) macht Transcribe→Polish→Enhance→Paste→Save→Refresh→Swap ohne Testnaht — deshalb blieb 3.1 unentdeckt.
**Fix:** generischer `EngineSlot<T>` (Task + State + Retry) und ein `DictationPipeline`-Struct mit injiziertem Transcriber/Paster/Store; Tests für Paste-, Cancel-, Fehler- und Pending-Swap-Pfade.

### 3.20 Latenz-Messung enthält LLM-Zeit
`lastLatencyMillis` (`:597-599`) misst Release→nach Paste, also bei verbesserten Diktaten auch die CLI-Rundreise. Diese Werte landen in `latency_ms` und verzerren p95 der Engine.
**Fix:** Latenz vor dem Enhance-Zweig stoppen oder für `enhanced = 1` getrennt auswerten.

### Chancen
- **Capture vorwärmen.** `recorder.start()` startet `AVAudioEngine` synchron bei Key-Down (`:400`); die ersten ~50–100 ms jedes Diktats fehlen. Engine mit kleinem Ringpuffer laufen lassen (oder bei jedem `flagsChanged` starten) und Key-Down→erstes Sample messen wie Release→Paste.
- **Vorhandene Streaming-Maschinerie nutzen** (oder Word-Timings aus FluidAudio): liefert das Live-Partial, für das das Overlay gebaut ist, hält lange Diktate unter 200 ms und gibt `ParagraphFormatter` das Pausen-Signal, auf das sein eigener Kommentar wartet.
- **Post-Release-Pipeline testbar machen** (3.19).

---

## 4. Meeting-Pfad (`Sources/Notable/Meeting/`, `Calendar/`)

### 4.1 Echtzeit-unsichere Arbeit im HAL-Thread (bestätigt)
`SystemAudioTap.swift:115-123` → `PCMDownsampler.swift:54-111`. Der `AudioDeviceCreateIOProcIDWithBlock`-Callback läuft im Echtzeit-IO-Thread von CoreAudio und allokiert dort zwei `AVAudioPCMBuffer`, führt `AVAudioConverter.convert` aus, nimmt einen `NSLock`, allokiert `Data` und macht einen `FileHandle.write`-Syscall. `padGapToWallClock()` (`:118-144`) hält denselben Lock, während es *Minuten* Stille in 10-s-Blöcken schreibt — und wird direkt nach `AudioDeviceStart` aufgerufen (`SystemAudioTap.swift:179-183`), sodass der IO-Thread für die Dauer des Pads blockiert. Folgen: HAL-Overloads → fallengelassene Tap-Puffer → System-Spur kürzer als die Wanduhr → Mic/System-Merge ordnet die Sprecher für den Rest des Meetings falsch (genau der Fehler, den das Gap-Padding verhindern soll). Die Mic-Seite ist nicht betroffen (`AVAudioEngine`-Taps liefern außerhalb des Render-Threads).
**Fix:** im IO-Proc nur die rohen ABL-Bytes in einen vorallokierten Ringpuffer kopieren (mindestens `Data(bytes:)` + `serialQueue.async`); Konvertierung, RMS und Spool-Write auf einer seriellen `DispatchQueue`. Nie Lock oder `FileHandle` aus dem IO-Proc.

### 4.2 `State.processing` blockiert die nächste Aufnahme (bestätigt)
`MeetingController.swift:93-94` (`startAutomatically` verlangt `.idle`), `:112-113`, `:271` (`state = .processing` bis Pipeline + Naming + Summary fertig), `:342`, `:435`. Während die vorige Notiz produziert wird (30–60 s ASR pro Stunde Audio laut `MeetingScaleTests`, plus zwei LLM-Rundreisen), kommt das One-shot-`.started` des Detektors für den nächsten Call, `ConsentCoordinator` markiert sich `.recording` (`ConsentCoordinator.swift:115-117`), `startAutomatically` ist ein stiller No-op, nichts wiederholt. Gleiches für manuelles `toggle()` (Menü-Button deaktiviert).
**Fix:** State teilen in `captureState` (idle/recording) und `processingCount`; `produceNote` nutzt bereits nur eingefangene Werte, Aufnahme darf während laufender Verarbeitung starten; Recoveries genauso in die Queue.

### 4.3 Sleep/Wake wird nicht behandelt
Kein `NSWorkspace.didWakeNotification`/`willSleepNotification` in `Sources`. `padGapToWallClock()` wird nur bei Gerätewechsel ausgelöst (`AudioRecorder.swift:55-63`, `SystemAudioTap.swift:172-195`). Nach Deckel-zu während eines Calls postet die Mic-Engine typischerweise einen Configuration-Change → `resume()` paddet die Mic-Spur; der Tap bekommt keinen Default-Output-Device-Change → kein Pad → System-Spur um die Schlafdauer kürzer, jedes spätere Segment zu früh gestempelt.
**Fix:** `didWakeNotification` im `MeetingController` beobachten, `padGapToWallClock()` auf beiden Downsamplern aufrufen und den Tap neu bauen; zusätzlich beide Spuren in `stop()` vor `drain()` padden, damit sie immer gleich lang enden.

### 4.4 Meeting-Ende und Crash-Recovery blockieren den Main-Thread mit hunderten MB I/O
`MeetingController.swift:257-258` → `PCMDownsampler.drain()` → `SpoolStore.readSamples` (`SpoolStore.swift:71-81`) liest und kopiert jede Spool-Datei synchron auf dem Main-Actor; `:344-345` dasselbe beim Start für Recovery. `produceNote` (`:521`) ist ein `static` Member einer `@MainActor`-Klasse und damit MainActor-isoliert (der Autor wusste es: `meetingTranscriber` ist explizit `nonisolated`), also laufen `TrackSilence.isSilent` (`:546-547`) und die Markdown-Writes/Renames (`:618, 662, 666`) ebenfalls auf Main. Für 1 h Meeting ~2×230 MB Read+Copy plus Scan auf dem UI-Thread; für 2 h etwa eine Sekunde Beachball genau beim Klick auf „Meeting beenden“.
**Fix:** `produceNote` `nonisolated`, `drain()` gibt Spool-URLs statt `[Float]` zurück, Laden/Scannen im Detached Task; zurück auf Main nur für `@Published`.

### 4.5 Peak-RAM: beide Rohspuren + kompaktierte System-Spur + Diarizer gleichzeitig
`MeetingPipeline.swift:103-191`, `MeetingController.swift:257-258`. `MeetingScaleTests.swift:290-308` misst es und pinnt es als `XCTExpectFailure` (>380 MB für 30 min; ~1 GB extrapoliert für 60 min, auf 16 GB neben der Video-App). Die Daten liegen schon im Spool; die ASR-Schleife (`:170-178`) braucht immer nur ein ≤14-s-Slice.
**Fix:** Spool-URLs an die Pipeline, pro Segment aus der memory-mapped Datei schneiden (`Data(.alwaysMapped)` + `copyBytes`); nur VAD/Diarisierungs-Eingaben im RAM (VAD kann auch in Chunks laufen — `VadManager` ist streaming-fähig).

### 4.6 Crash-Recovery verwirft Capture-Warnung und Summary-Fehler
`MeetingController.swift:384-396`: der Recovery-Zweig meldet nur „wiederhergestellt“ / „ohne erkannten Sprachinhalt“ und ignoriert `note.captureWarning` und `note.summaryError` — der `stop()`-Zweig (`:298-312`) behandelt beide. `CLAUDE.md` behauptet, `produceNote` „puts the warning in the status line and the notification“; für wiederhergestellte Meetings stimmt das nicht. `summaryRetry` wird gesetzt (`:380`), die Statuszeile sagt aber nie, dass die Zusammenfassung fehlschlug.
**Fix:** ein `handle(outcome:spool:)` für beide Zweige (entfernt auch den duplizierten `lastNoteURL`/`summaryRetry`/`refreshSoon`/Archiv/Notify-Block).

### 4.7 Kalender-Zuordnung bevorzugt ein anstehendes Event vor dem laufenden, ignoriert abgelehnte
`Calendar/CalendarMonitor.swift:44-48`: Kandidaten umfassen Events mit Start innerhalb +5 min, sortiert nach `startDate` absteigend → ein überziehender 10:00-Call, aufgenommen um 10:27, wird dem 10:30-Event zugeordnet (Titel, `calendarEventID`, Teilnehmerpool für Speaker-Naming). Kein Filter auf `participationStatus == .declined`. Das Event wird einmal beim Start aufgelöst (`MeetingController.swift:122-135`); eine kurze Aufnahme, die vor dem async Match endet, hat `currentEvent == nil`.
**Fix:** laufende Events (`startDate <= date`) vor anstehenden ranken, `.declined` verwerfen, Events mit Teilnehmern bevorzugen.

### 4.8 Segmente unter 0,5 s werden verworfen — Ein-Wort-Antworten verschwinden
`MeetingPipeline.swift:42, 169`. `groupedSpecs` fusioniert nur gleiche Sprecher innerhalb 1,5 s, ein entferntes „Nein.“ / „Ja.“ / „Okay.“ (0,3–0,5 s; FluidAudio `minSpeechDuration` ist 0,15 s) als Antwort auf eine Frage von „Ich“ fehlt in Transkript und Zusammenfassung. Parakeet transkribiert 0,4-s-Clips problemlos (Diktat tut es).
**Fix:** auf ~0,25 s senken oder kurze Slices mit 0,3 s Umgebungs-Audio padden; leere Ergebnisse wirft `TextPolisher` ohnehin weg.

### 4.9 Speaker-Naming-Validierung ist schwächer als sie aussieht
`SpeakerNameResolver.swift:240-246`: `nameIsAttested` akzeptiert einen Namen, wenn *irgendein* ≥2-Buchstaben-Token davon irgendwo im Transkript vorkommt — „Frank Weber“ wird durch das Adverb „frank“ belegt, „Tim Berger“ durch ein über Dritte gesprochenes „tim“. `:31, 103`: `ownerNameTokens` verwirft jeden Remote-Namen, der ein Token mit `NSFullUserName()` teilt, sodass ein Kollege mit dem Vornamen des Nutzers nie benannt werden kann. Ersteres False Positive (schlimmer laut eigener Regel der Datei), zweiteres permanentes False Negative.
**Fix:** auf das Vornamen-Token (oder den vollen Namen) attestieren; Owner-Regel auf den vollen normalisierten Namen statt Token-Überlappung.

### 4.10 Zwei sequentielle LLM-Rundreisen pro Meeting
`MeetingController.swift:582-587` (Naming), dann `:634-638` (Summary): zwei Provider-Aufrufe, je mit vollem Transkript, beide auf der API gemetert. Der Summary-Prompt liefert bereits strukturiertes JSON (`SummaryParser`).
**Fix:** die `{"Sprecher n": name|null}`-Zuordnung im Summary-Call mit anfordern, gleiche `validated`-Schleuse; separater Call nur als Fallback.

### 4.11 Pipeline ist vollständig seriell
`MeetingPipeline.swift:113-166`: Mic-VAD → System-VAD → Kompaktierung → Diarisierung → ASR-Schleife. Mic-VAD und Mic-ASR hängen von nichts auf der System-Seite ab; `MeetingScaleTests` zeigt ASR bei 79 % der Wartezeit mit 88 ms Fixkosten pro Aufruf.
**Fix:** Mic-VAD + Mic-ASR in einer `TaskGroup` parallel zu System-VAD + Diarisierung, dann mergen. ANE-Contention deckelt den Gewinn, Diarizer-Spike und Mic-ASR überlappen aber gratis.

### 4.12 `MeetingController`-Zuschnitt: drei Extraktionen
707 Zeilen, vier Verantwortungen. (a) `MeetingCaptureSession` — Mic + Tap + Spool + Watchdog + Geräte-/Wake-Handling (`:33-48, 59-81, 139-183, 209-241, 253-265`); (b) `MeetingNoteProducer` — `produceNote` + `retrySummary` + Outcome-Handling, `nonisolated` und injizierbar (Store, Provider, Ordner); `MeetingEndToEndTests.swift:12-15` sagt ausdrücklich, dass es `produceNote` *Schritt für Schritt nachbildet*, weil das Original privat und MainActor ist — das ist die Testlücke; (c) Recovery. Außerdem: `providerID`-Lookup dreifach (`:273, 361, 438`); `recordingStartedFallback` (`:243-251`) liest `meta.json` neu für ein `startedAt`, das bei `:119` schon im Scope ist.

### 4.13 Toter Code
`AudioProcessMonitor.swift:49-54` `firstInput(bundleIDs:)` ist byte-identisch zu `inputEntry(anyOf:)` (`:59-64`) und nur von einem Test benutzt; `MeetingDetector.swift:56-58` `tick(candidatePresent:micActive:)` wird von keinem Produktionscode benutzt (der Fallback bei `:170-177` ruft die neue Form) — der Kommentar „kept for the fallback path“ stimmt nicht.

### 4.14 Detektor-Kandidaten-/Prioritätsregeln ungetestet
`detectInCallCandidate`, `detectBrowserCall`, `isStillActive` (`MeetingDetector.swift:201-256`) sind private Statics; `CallLifecycleTests` deckt nur `AudioProcessSnapshot` und die Zustandsmaschine. Zwei Apps gleichzeitig (Zoom + Slack-Huddle), Placeholder-Kandidat, Browser mit unbekanntem Titel — ungepinnt.
**Fix:** als `static func` (internal) mit `snapshot` + injiziertem `windowTitles: (String) -> [String]`, Tier-Tabelle testen.

### 4.15 Crash-Fenster hinterlässt Duplikat-Notiz
`MeetingController.swift:692-697` schreibt nach SQLite, `stop()` archiviert den Spool bei `:295` erst nach Rückkehr von `produceNote`. Ein Crash dazwischen (oder `insertMeeting` wirft nach dem Markdown-Write bei `:618`) lässt den Spool als Waise zurück → nächster Start produziert eine zweite Notiz „ (2)“.
**Fix:** `done`-Marker (oder Recording-ID) in den Spool vor dem SQLite-Insert; solche Sessions in `orphans()` überspringen/archivieren.

### 4.16 Stiller Puffer-Drop im IO-Proc
`SystemAudioTap.swift:117-121`: gibt `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` nil zurück (Kanal-/Layout-Mismatch), ist das ein nacktes `return` — Datenverlust ohne Zähler, ohne Log. Nur `kAudioHardwarePropertyDefaultOutputDevice` wird beobachtet (`:149-164`); ein Sample-Rate-Wechsel am *selben* Gerät nicht.
**Fix:** Drops zählen und über einen `onRebuildFailure`-artigen Callback melden; zusätzlich `kAudioDevicePropertyNominalSampleRate` beobachten.

### 4.17 Mic-Watchdog vergleicht RMS mit Peak-Schwelle und nutzt falschen Run-Loop-Mode
`MeetingController.swift:221` vergleicht `micRecorder.level` (Chunk-RMS, `PCMDownsampler.swift:85`) mit `TrackSilence.peakThreshold` (1e-4, für *Peak* kalibriert, `TrackSilence.swift:25`); RMS ≤ Peak, also ist der Live-Check strenger als dokumentiert und kann ein sehr leises Interface anschlagen. `Timer.scheduledTimer` (`:215`) läuft im `.default`-Mode — steht still, während das Menüleisten-Menü offen ist (der Detektor-Timer nutzt korrekt `.common`).

### 4.18 `ChatPrompt`-Fallback-Auszug ist unbegrenzt und Stoppwort-blind
`ChatPrompt.swift:114-131, 136-139`: Keywords sind jedes ≥4-Buchstaben-Wort („welche“, „wurden“, „haben“, „nicht“), Substring-Match, sodass der „relevante“ Auszug eines >120k-Zeichen-Transkripts fast das ganze Transkript ist — der Zweig existiert für das Kontextfenster, hat aber keine Deckelung.
**Fix:** kleine DE/EN-Stoppwortliste und Zeichenbudget (Treffer mit niedrigster Keyword-Zahl zuerst verwerfen).

### 4.19 Consent-Flow meldet Erfolg, obwohl nichts startete
`ConsentCoordinator.swift:115-117` setzt `.recording`, `MeetingController.startAutomatically` (`:93-94`) ist stiller No-op bei laufender manueller Aufnahme (oder Processing, 4.2); der Nutzer hat „Aufnehmen“ in der Notification getippt und bekommt nichts.
**Fix:** `startAutomatically` gibt Bool/Grund zurück, Koordinator zeigt Statuszeile.

### 4.20 `MeetingDetector.currentCandidate` wird alle 5 s neu publiziert
`MeetingDetector.swift:179-181` weist die `@Published`-Property unbedingt zu, feuert `objectWillChange` für jede View mit dem Detektor als `EnvironmentObject` bei jedem Poll. Guard auf `!=`.

### Chancen
- **Pipeline aus dem Spool streamen** (4.4 + 4.5 + 4.12): `[Float]`-Spuren durch Spool-URLs ersetzen, VAD in Chunks, mmap-Slices pro Segment. Mehrstündige Meetings werden flach im Speicher, `produceNote` wird testbar.
- **Pre-VAD-Echo-Gate für Lautsprecher ohne Kopfhörer.** VPIO ist aus gutem Grund per Default aus, Bleed also der Live-Zustand; `EchoBleedTests` beweist, dass der Fix vor die VAD muss. Gefensterte normalisierte Kreuzkorrelation zwischen Mic und verzögerter (0–150 ms) System-Spur, Mic-Fenster nullen, wo die System-Spur Sprache hat und die Korrelation hoch ist — günstig, offline, mit der vorhandenen Bleed-Synthese testbar.
- **Capture von Processing entkoppeln, Processing als Queue** (4.2, 4.19): Aufnahme muss immer möglich sein; Notiz-Produktion läuft seriell im Hintergrund mit Status pro Item.

---

## 5. Storage, Retention, Stats, Notizen, Suche

### 5.1 Retention lässt den Vor-Verbesserungs-Text stehen
`Storage/RecordingStore.swift:707-718` — `clearSegmentText(kind: .dictation)` leert nur `segments.text`; `recordings.raw_text` (das volle regelpolierte Diktat bei jedem verbesserten Lauf) überlebt, und `recentDictations` (`:361`) liefert es weiter.
**Fix:** in derselben Transaktion `UPDATE recordings SET raw_text = NULL WHERE kind='dictation' AND started_at < ?`; in `RetentionStoreTests` pinnen.

### 5.2 Whisper-Tiny-Diktate werden als gewählte Engine verbucht
`Dictation/DictationController.swift:608` übergibt `ASREngineID.current.statisticsName`, während `rawTranscript` (`:639`) bei `isUsingBootstrap` tatsächlich `bootstrapTask` nutzte. Jedes Cold-Cache-Diktat landet als `parakeet-v3` mit Tinys Latenz und verfälscht p50/p95 und die Anteils-Karten.
**Fix:** `engine` aus dem Transcriber ableiten, der lief.

### 5.3 Suche: Titel-Treffer fächern pro Segment auf
`Storage/RecordingStore.swift:474-481` — `OR r.title LIKE …` auf dem `segments ⋈ recordings`-Join liefert N Zeilen für ein N-Segment-Meeting mit passendem Titel; mit `ORDER BY started_at DESC LIMIT 30` füllt ein 300-Segment-Meeting die ganze Liste mit identischen Zeilen, deren Snippet (`:501`, aus Segmenttext) den Suchbegriff nicht mal enthält.
**Fix:** zwei Statements (Titel-Treffer: einer pro Recording; Text-Treffer: pro Segment), in Swift gemergt — oder FTS5 (5.9).

### 5.4 `saveDictation` sind zwei INSERTs ohne Transaktion
`:160-161`. Fehler/Crash dazwischen hinterlässt eine `recordings`-Zeile ohne Segment: gezählt von `usageRows`, angezeigt von `recentActivity` (NULL-Snippet), unsichtbar für `recentDictations` (Inner Join). `insertMeeting` (`:224`) macht es richtig.
**Fix:** `transaction { }`-Helper für `saveDictation`, `insertMeeting`, `backfillWordCounts`.

### 5.5 Lese-Schleifen behandeln jeden Step-Fehler als Ergebnisende
Alle neun `while sqlite3_step(statement) == SQLITE_ROW` (`:279, 310, 376, 436, 492, 541, 601, 636, 673`) — `SQLITE_BUSY/IOERR/CORRUPT` liefern still eine kurze oder leere Liste; eine korrupte Page liest sich als „heute keine Diktate“.
**Fix:** finales `rc` erfassen und werfen außer bei `SQLITE_DONE`; ein generischer `query(sql, bind:, row:)`-Helper entfernt die neun Kopien des Prepare/Finalize-Boilerplates.

### 5.6 Keine Schema-Version; `CREATE TABLE` veraltet; Migrationen schlucken jeden Fehler
`:768-853` — frische DBs entstehen ohne `engine/latency_ms/source_app/enhanced/raw_text` und verlassen sich auf elf blinde `ALTER TABLE`s, deren *jeder* Fehler (`SQLITE_BUSY`, read-only, Disk voll) verworfen wird (`:852`) und später als „no such column“ in einer fremden Query auftaucht. Downgrade ist zufällig sicher (alle INSERTs nennen ihre Spalten).
**Fix:** `PRAGMA user_version` + nummerierte Migrationen in einer Transaktion; vollständige aktuelle Form im `CREATE TABLE`; nur „duplicate column name“ ignorieren.

### 5.7 Halboffene Verbindung bleibt bei Schema-Fehler
`:764-766` — `connection` wird zugewiesen, *bevor* `PRAGMA journal_mode=WAL` / `CREATE TABLE` laufen; wirft eines, nutzt jeder spätere Aufruf ein Handle ohne Schema und versucht es nie erneut.
**Fix:** `connection` erst nach erfolgreichem Setup zuweisen, Handle bei Fehler schließen.

### 5.8 Fehlende Indizes für die tatsächlich gestellten Queries
Nur `segments(recording_id)`, `chat_messages(recording_id)`, `llm_usage(created_at)` existieren. `recordings` hat keinen Index auf `started_at` (von `usageRows`, `recentActivity`, `recentMeetings`, `recentDictations`, `clearSegmentText` benutzt), `chat_messages(created_at)` wird von `deleteChatMessages` gescannt, `recentActivity`s korrelierte `ORDER BY start_seconds LIMIT 1`-Subquery (`:418-420`) will `segments(recording_id, start_seconds)`.

### 5.9 LIKE-Suche: ASCII-only Case-Folding, Full Scan, inkonsistent mit dem eigenen Snippet
`:464-477` (als v1 dokumentiert). „über“ findet „Über“ nie; `snippet(around:)` (`:509`) nutzt `.diacriticInsensitive`, der SQL-Match nicht.
**Fix:** FTS5 External-Content-Tabelle über `segments(text)` mit `tokenize='unicode61 remove_diacritics 2'`, trigger-synchronisiert, `snippet()`/`bm25()`.

### 5.10 Rename/Move löschen die alte Datei, bevor SQLite aktualisiert ist
`Notes/NoteManager.swift:84-87` und `:111-114` — neu schreiben, alt löschen, *dann* `updateTitle`/`updateLocation`; wirft der DB-Write, zeigt `markdown_path` auf eine gelöschte Datei („Im Finder zeigen“ bricht). Gleiches Muster in `Meeting/MeetingController.swift:618/692`: `.md` geschrieben und umbenannt vor `insertMeeting`; bei Insert-Fehler geht der Spool nach `spool-failed` und Recovery schreibt ein „(2)“-Duplikat.
**Fix:** neu schreiben → DB aktualisieren → alt löschen.

### 5.11 „SQLite ist die Wahrheit“ — außer beim Kalender-Titel
`Notes/NoteManager.swift:139-141` übergibt `calendarEventTitle: nil`, sodass jedes Rename/Move/Notizen-Speichern/Re-Summarize (`MeetingController:461-468` ebenso) die `event:`-Frontmatter-Zeile still verliert.
**Fix:** Spalte `calendar_event_title TEXT`, in `produceNote` schreiben, in `readRecording` lesen.

### 5.12 Retention-Runner verbirgt SQLite-Fehler
`Storage/RetentionPolicy.swift:286-294` — `(try? …) ?? 0` meldet ein fehlgeschlagenes Leeren als „0 Segmente geleert“ ohne Log; die Datei-Hälfte loggt jeden Fehler (`:280`), die DB-Hälfte keinen.
**Fix:** catch, `log.error`, `errors` in `Result`, in `StorageSettingsView` anzeigen.

### 5.13 Session mit unlesbarem Datum wird zuerst gelöscht
`:214` — fehlende `meta.json` *und* Erstellungsdatum ⇒ `Date.distantPast` ⇒ „älter als ~20000 Tage“, vor allem anderen entfernt. Unbekanntes Alter muss *behalten* heißen.

### 5.14 `didBackfillWordCount` wird auch bei Fehler gesetzt
`NotableApp.swift:105-107` — `try?`, dann unbedingt `set(true)`; ein transienter Fehler lässt NULL-Wortzahlen für immer, die Statistik untertreibt still.

### 5.15 Stats-Oberfläche ist Deutsch im englischen UI, Scanner blind
Plain-`String`-Parameter umgehen Lookup und `LocalizationTests` (`:53-62`). Bestätigt fehlend in `en.lproj`: `UsageMetrics.menuLine` („Wörter“, „Meetings“, „gespart“, `Stats/UsageMetrics.swift:296-309`) und „Heute“ (`UsageSummary.swift:49`, gerendert als `Text(usageLine)` in `NotableApp.swift:325`); `Granularity.periodLabel/rangeLabel/hoverLabel` (`StatsView.swift:442-489`); `StatTile(caption: "Diktate"/"KI-Tokens", footnote: …)` (`:313-342`); jede `DetailCard(title:/emptyMessage:)` in `Cards/EngineCards.swift`, `HeatmapCard.swift`, `DetailCard.swift:13`; `unknownKey`/„Weitere“ (`UsageMetrics.swift:335, 397`); `RecentDictationsView.Window.label`; `RetentionPlanner.Reason.tooOld` (`RetentionPolicy.swift:109`, während der Geschwister-Case lokalisiert ist).

### 5.16 Geleerte Diktate werden leere Menüzeilen, die „“ pasten
Nach Retention liefert `recentDictations` `text: ""` (gepinnt in `RetentionStoreTests:36`), `DictationHistory.recent` zeigt leere Einträge, `pasteLast` (`Dictation/DictationHistory.swift:76-79`) pastet einen Leerstring.
**Fix:** `AND s.text != ''` in `recentDictations` und der `recentActivity`-Snippet-Subquery.

### 5.17 `RecentDictationsView` filtert Kind clientseitig nach gemischtem `LIMIT 200`
`Notes/RecentDictationsView.swift:74-75` / `RecordingStore.swift:411` — Meetings verbrauchen Slots, „Alle“ ist still bei 200 gedeckelt.
**Fix:** `recentActivity(kind:within:limit:)` mit `WHERE kind = ?`.

### 5.18 Trappende `Int32(...)`-Konvertierungen auf dem Save-Pfad
`RecordingStore.swift:192, 198, 648` nutzen `Int32(wordCount)`/`Int32(latencyMs)`, während `:573-576` `Int32(clamping:)` nutzt. Unrealistische Werte, aber ein Trap im Actor mitten in `saveDictation` ist der falsche Fehlermodus; `sqlite3_bind_int64`.

### 5.19 Views verdrahten `RecordingStore.shared` hart; Store→Stats-Mapping doppelt und ungetestet
`StatsView.swift:46, 57`, `RecentDictationsView.swift:74`, `SearchWindow.swift:39`, `Settings/SettingsView.swift:554`, `StorageSettingsView.swift:71, 170`. `StatsModel` hat keinen injizierbaren Store, `UsageRecord → UsageRow` ist zweimal ausgeschrieben (`StatsView.swift:47-56`, `UsageSummary.swift:41-47`, das zweite ohne Engine/Latenz/App).
**Fix:** `StatsModel.init(store:)`, ein `UsageRow.init(_ record:)`.

### 5.20 `RecordingStore`-Zuschnitt
894 Zeilen, neun handgerollte Statement-Schleifen, zwei Ad-hoc-`BEGIN IMMEDIATE`-Blöcke, `readRecording` liest 13 von 18 Spalten, sodass `meeting(id:)` immer `enhanced=false, rawText=nil` liefert, `RecordingStore.wordCount` (`:166`) dupliziert `UsageMetrics.wordCount` (`:117`) byteweise.
**Fix:** `SQLiteConnection` (open/migrate/`query`/`run`/`transaction`) + Extensions `+Recordings`, `+Search`, `+Usage`, `+Chat`, `+Retention`; ein `wordCount`.

### Chancen
- **FTS5 für die Suche** — löst 5.3 und 5.9, bringt Ranking, Präfix-Queries, echte Snippets und macht aus dem Scan einen Index-Lookup.
- **Dünne `SQLiteConnection`-Schicht mit versionierten Migrationen** — löst 5.4–5.8, 5.18, 5.20 in einem Zug, macht Fehlerpfade testbar (fehlschlagendes Handle injizieren).
- **Aufzeichnen, was passiert ist, nicht was konfiguriert war** — Engine aus dem Transcriber, `calendar_event_title` in SQLite, persistiertes Retention-Log.

---

## 6. LLM-Provider, Prozesse, Update, Berechtigungen, Lebenszyklus

### 6.1 Jede Claude-CLI-Zusammenfassung persistiert das volle Transkript in `~/.claude/projects/` (bestätigt)
`Summarization/ClaudeCodeCLIProvider.swift:58` — `claude -p` speichert die Session per Default. Auf diesem Rechner: `~/.claude/projects/-private-var-folders-…-T-notable-cli/` hält **81 `.jsonl`-Dateien, 6,7 MB, 80 davon mit `Transkript:`**, älteste vom 4. August. Der Diktat-Pfad (`complete`) geht durch dasselbe `runAndParse`, verbesserte Diktate landen also ebenfalls dort. `RetentionRunner` sieht dieses Verzeichnis nie; „SQLite ist die Wahrheit“ hat eine unverbuchte zweite Kopie jedes Transkripts.
**Fix:** `--no-session-persistence` in die Argumentliste (in `claude --help` vorhanden, nur mit `--print`, was genau dieser Modus ist). Einmalige Bereinigung des bestehenden Verzeichnisses erwägen; Hinweis in `CLAUDE.md`.

### 6.2 Auto-Update installiert ein ungeprüftes Bundle
`Update/UpdateInstaller.swift:104-118` (Entpacken) und `:124-134` (Swap). Der Kopfkommentar (`:7`) sagt, der Download sei „signed with the same stable identity“, aber nichts prüft es: kein `codesign --verify`, kein TeamIdentifier-Vergleich, `expectedName` fällt auf `apps.first` zurück (irgendeine `.app`). `URLSession`-Downloads tragen keine Quarantäne (`LSFileQuarantineEnabled` nicht in `project.yml`), Gatekeeper bewertet das neue Bundle also nie. Wer ein Zip aufs Release legen kann (kompromittierter GitHub-Account, falsches Asset — siehe 6.15), bekommt Code-Ausführung mit den TCC-Rechten der App.
**Fix:** vor `launchSwap` `/usr/bin/codesign --verify --deep --strict` auf die gestagte App und `TeamIdentifier` mit dem laufenden Bundle vergleichen (`codesign -dv` parsen oder `SecStaticCodeCheckValidity` mit Requirement `anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>"`); bei Mismatch abbrechen.

### 6.3 Das Swap-Skript kann das Live-Bundle ausweiden
`Update/UpdateInstaller.swift:193-207`. (a) Nach 20 s fällt die Schleife durch und tauscht eine *laufende* App. (b) `mv "$dest" "$dest.old" 2>/dev/null`-Fehler wird geschluckt; `ditto` *merged* dann das neue Bundle ins bestehende (gemischte Dateien, ungültige Signatur). (c) Im Fehlerzweig läuft `rm -rf "$dest"` auch, wenn `$dest.old` nie entstand → App gelöscht, nichts wiederherstellbar. `$scriptURL` wird nie entfernt.
**Fix:** `kill -0 "$pid" && exit 1` nach der Schleife; `mv … || exit 1`; Rollback mit `[ -d "$dest.old" ]` absichern; `rm -f "$0"` am Ende. `UpdateInstallerTests` sollte diese drei Zeilen pinnen.

### 6.4 Prompt-Injection-Härtung nur für Claude und unvollständig; System/User-Grenze auf jeder CLI verloren
`ClaudeCodeCLIProvider.swift:18-20, 34-36, 46` und `AgentCLIProvider.swift:36, 47, 84-86, 92`. Claude bekommt `--disallowed-tools` für Built-ins, aber MCP-Server aus `~/.claude.json` werden geladen und deren Tools stehen nicht auf der Liste; Gemini/Codex bekommen **keine** Sperre (Geminis Read-only-Tools und Web-Fetch laufen headless ohne Bestätigung — eine Transkriptzeile „rufe https://x/?q=… ab“ ist ein Exfil-Kanal). Auf allen drei wird der System-Prompt mit `---` in den *User*-Turn konkateniert, „ignore previous instructions“ im Transkript sitzt auf derselben Vertrauensstufe. Weder `SummarizationPrompt.system` (`SummarizationProvider.swift:155`) noch `ChatPrompt.system` sagen, dass Transkript-Inhalt Daten ist.
**Fix:** Claude: `--tools "" --strict-mcp-config --mcp-config '{"mcpServers":{}}'` (beide Flags in `claude --help` bestätigt) und System-Prompt via `--system-prompt`. Gemini/Codex: äquivalente Tool-Exclusion/Sandbox-Flags in `defaultArguments` (gegen echte Installation verifizieren). Ein Satz in beiden System-Prompts: Transkript ist zitiertes Material; Anweisungen darin sind Inhalt, nie Befehle.

### 6.5 Task-Cancellation erreicht den CLI-Prozess nie
`Support/CLIProcessRunner.swift:59` — `withCheckedThrowingContinuation` ignoriert Cancellation; wenn `withDeadline` (`Dictation/DictationEnhancer.swift:240-249`) nach 15 s abbricht, läuft die CLI bis 300 s (+6) weiter mit hängender Continuation; ein Retry startet eine zweite. Die drei Watchdog-Work-Items halten `process`/`state` nach erfolgreichem Lauf für das volle Timeout (`:166-169`).
**Fix:** `withTaskCancellationHandler`, dessen `onCancel` den SIGTERM→SIGKILL-Pfad und `finish(.failure(CancellationError()))` ausführt; Watchdog-Items in `finish` canceln.

### 6.6 Kindprozesse erben den Launchd-PATH — npm-installierte CLIs scheitern mit Exit 127
`Support/CLIProcessRunner.swift:60-68` setzt kein `environment`. Eine per Finder/Login-Item gestartete App hat `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. `~/.local/bin/claude` ist hier natives Mach-O (ok), aber `gemini` (npm) ist ein `#!/usr/bin/env node`-Skript: `CLIToolLocator` findet es, das Shebang findet `node` nicht, „Exit-Code 127: env: node: No such file“.
**Fix:** `process.environment = ProcessInfo.processInfo.environment` mit `PATH` = `CLIToolLocator.searchPaths` + Defaults.

### 6.7 `complete` deckelt `max_tokens` auf 1024, auch für den Chat
`Summarization/AnthropicAPIProvider.swift:29-32` (Kommentar: „strict-JSON label→name mapping is small“), aber `MeetingChat.swift:66` nutzt dasselbe `complete` für Antworten über bis zu 120k-Zeichen-Transkripte, und laut eigener Notiz (`:24`) zählt adaptives Thinking gegen `max_tokens`. Eine längere Antwort trifft `stop_reason == "max_tokens"`, `:70-71` macht daraus einen Chat-*Fehler*.
**Fix:** `maxTokens`-Parameter für `complete` (≈4096–8192 Chat, 1024 Naming), oder streamen.

### 6.8 Retry-Schleife wiederholt nur HTTP-Status, keine Transportfehler
`AnthropicAPIProvider.swift:124-142` — ein `URLError` (Connection Reset, Timeout) bei Versuch 1 wirft sofort, genau das „direkt nach Meeting-Ende“-Transient, das der Kommentar überleben wollte.
**Fix:** `URLError` mit `.networkConnectionLost/.timedOut/.cannotConnectToHost/.notConnectedToInternet` in der Schleife fangen und gleich backoffen.

### 6.9 Keychain-Read schluckt jeden OSStatus — Identitätswechsel sieht aus wie „kein Key“
`Support/KeychainStore.swift:11-26, 29-38`. Nach den in `project.yml:202-217` dokumentierten Wechseln ad-hoc→Apple Development→Developer ID kann die Legacy-Keychain-ACL `errSecAuthFailed`/`errSecInteractionNotAllowed` antworten; `availability()` meldet dann „Kein API-Key im Schlüsselbund“, obwohl er existiert. `write` ist delete-then-add, ein fehlgeschlagenes `SecItemAdd` verliert den alten Key.
**Fix:** Status loggen/zurückgeben, „absent“ von „denied“ unterscheiden; `SecItemUpdate` mit Add bei `errSecItemNotFound`.

### 6.10 Kein Single-Instance-Guard
`project.yml:163-176` hat kein `LSMultipleInstancesProhibited`, nichts in `NotableApp.swift` prüft `NSRunningApplication`. Debug-Build aus `$DD` neben `/Applications/Notable.app` (der dokumentierte Workflow) ergibt zwei Flags-Taps, zwei Meeting-Detektoren, zwei Spools für einen Call, zwei Notification-Delegates.
**Fix:** `LSMultipleInstancesProhibited: true` in `info.properties`.

### 6.11 Update-Notification kann verloren gehen und wird nie wieder angekündigt
`Update/UpdateChecker.swift:225-227` markiert die Version als benachrichtigt, *bevor* `NotificationCenterService.post` (`:173-177`) bei `!isAuthorized` still zurückkehrt. Bei frischer Installation ist der Autorisierungsdialog (`NotableApp.swift:55`) noch offen, wenn der Check fertig ist → diese Version wird nie angekündigt.
**Fix:** `post` gibt zurück, ob gepostet wurde; nur dann `notifiedVersionKey` schreiben.

### 6.12 Beenden (oder Update) mitten im Meeting killt die Aufnahme
`Update/UpdateInstaller.swift:70` ruft `NSApp.terminate(nil)` unbedingt; kein `applicationShouldTerminate` irgendwo, also killt ⌘Q / „Notable beenden“ / Update-Installation während einer Aufnahme diese und überlässt der Spool-Recovery das Aufräumen.
**Fix:** `applicationShouldTerminate` → `.terminateLater` während `meeting.state.isRecording`, Meeting stoppen, `reply(toApplicationShouldTerminate:)`; `installAndRelaunch` während Aufnahme verweigern.

### 6.13 Lokalisierungslücken, die der Scanner nicht sieht (verifiziert fehlend in `en.lproj`)
`NotableApp.swift:293-298` — `statusLabel` ist `String`, `Text(statusLabel)` ist wörtlich: „Meeting wird aufgezeichnet…“/„…verarbeitet…“ erscheinen Deutsch in Englisch; `:488-490` „jetzt“, „in … min“. `Support/AppLanguage.swift:31` „Systemsprache“. `Support/NotificationCenterService.swift:125, 148, 162`. Jeder Provider-/Runner-/Updater-Fehlerstring (`SummarizationProvider.swift:101`, `AnthropicAPIProvider.swift:69, 71, 148, 160, 163`, `ClaudeCodeCLIProvider.swift:24, 31`, `CLIProcessRunner.swift:115, 121, 133`, `UpdateInstaller.swift:93, 110, 116`, `UpdateChecker.swift:263, 285`). Das Idiom `String.LocalizationValue = switch` (`PermissionsManager.swift:27`, `SummarizationProvider.swift:120`) wird von den Regexen in `LocalizationTests.swift:53-63` nicht erfasst. `excludedFiles` (`:29`) nennt `Summarization/SummarizationPrompt.swift`, das nicht existiert.
**Fix:** Literale wrappen; Scanner-Muster für `LocalizationValue = switch … case … : "…"`; `Text(<bareIdentifier>)` zur manuellen Prüfung flaggen; stale Exclusion entfernen.

### 6.14 `install.sh`/`notarize.sh --install` löschen das Bundle unter der laufenden App weg
`scripts/install.sh:35-36`, `scripts/notarize.sh:150-151` — `rm -rf /Applications/Notable.app`, während Notable läuft. Zusammen mit 6.10 ergibt das nächste `open` zwei Instanzen.
**Fix:** `osascript -e 'tell application id "…" to quit'` + Warteschleife vor `rm`, `open` danach.

### 6.15 Asset-Auswahl nimmt jedes `.zip`
`Update/UpdateChecker.swift:123-125` — das erste `.zip`-Asset gewinnt; ein zuerst angehängtes `dSYM.zip` würde „installiert“ (und mit 6.2 ohne Widerspruch). Der Klassen-Kommentar `:153-155` („never downloads or installs anything“) ist veraltet.
**Fix:** `Notable-<version>.zip` bevorzugen, Namen mit `dSYM`/`symbols` ausschließen.

### 6.16 Codex/Gemini-JSONL-Ausgabe wird roh gepastet
`Summarization/AgentCLIProvider.swift:117-140` — `codex exec --json` und Geminis Stream-Modus geben ein JSON-Objekt pro Zeile aus; `JSONSerialization` scheitert am ganzen Blob, der Parser fällt auf „plain stdout ist die Antwort“ zurück, eine Seite JSONL wird die Zusammenfassung. Custom-Args (`:63`) werden an einzelnen Leerzeichen ohne Quoting gesplittet.
**Fix:** wenn jede nichtleere Zeile als JSON parst, das letzte Objekt nehmen; Quoting unterstützen (oder `[String]`-Setting).

### 6.17 Release-Skript pusht jeden lokalen Tag
`scripts/release.sh:169` `git push origin HEAD --tags`. **Fix:** `git push origin HEAD "$TAG"`.

### Chancen
- **Updater vertrauenswürdig machen** (6.2, 6.3, 6.12).
- **CLI-Datenschutz-/Injection-Lücke schließen** (6.1, 6.4).
- **Prozess-Runner fertigstellen** (6.5, 6.6).

---

## 7. UI, Settings, Design, UX

### 7.1 Plain-`String`-Enum-Labels leaken Deutsch ins englische UI
`EnglishStreamingTranscriber.swift:47-53` (`ASREngineID.label`), `WhisperTranscriber.swift:35-42`, `NotchGeometry.swift:22-28` (`OverlayStyle.label`), `IconPickerView.swift:20-60` (39 von 40 Icon-Labels), `RecentDictationsView.swift:15-21`, `StatsView.swift:174` (Tag/Woche/Monat/Jahr), `:442-489`, `:313/324/337`, `:310/320/330`, `:261`, `NotableApp.swift:292-298`, `:487-490`, `AppState.swift:19-25` („Bereit“ und „Transkribiere…“ unlokalisiert, „Aufnahme läuft…“ lokalisiert — dasselbe Switch), `UsageSummary.swift:37`, `SettingsView.swift:320`. Keiner dieser Keys existiert in `en.lproj`. `CLAUDE.md`s Behauptung, der Test „fails on any user-facing literal without an English entry“, stimmt für genau das Muster nicht, vor dem `CLAUDE.md` selbst warnt.
**Fix:** `String(localized:)`; Scanner-Muster für `case \.\w+:\s*"…"` in `var label/title/name`; positiver Test, der jedes Enum-Label gegen das en-Bundle auflöst.

### 7.2 Ternary- und Interpolationsvarianten produzieren still unübersetzte Strings
`SettingsView.swift:423-425`: `Text(x == 0 ? String(localized: "…") : "Freihändig nach \(n) s Stille beenden")` — zweiter Zweig ist `String`. Ebenso `LiveNotesView.swift:60-62`, `SettingsView.swift:513` (`String(format: "%d ms bei %.1f s Audio")` — auch C-Locale-Dezimalpunkt), `EnhancementSettingsSection.swift:152, 154`, `DictationOverlay.swift:773-774`.

### 7.3 Eigene Verbesserungsprofile hängen bei jedem Speichern die Grundregeln erneut an (bestätigt)
`EnhancementSettingsSection.swift:187-190` macht `saved.systemPrompt += EnhancementProfile.commonRules`; das Sheet wird mit dem gespeicherten Profil geöffnet (`:76, 112`), das die Regeln schon trägt (`DictationEnhancer.swift:75-86` speichert sie wörtlich). Der TextEditor zeigt also die Regeln, die die Fußnote (`:181`) als „automatisch angehängt“ bezeichnet, und jeder Edit fügt eine weitere Kopie in den Prompt.
**Fix:** Prompt ohne Regeln speichern und in `DictationEnhancer` zur Laufzeit anhängen (Built-ins tun das bei `:36-63`), oder beim Laden in den Editor das `commonRules`-Suffix strippen.

### 7.4 Menü-Shortcuts sehen global aus, wirken aber nur bei offenem Menü
`NotableApp.swift:336, 355, 358, 383, 391, 401, 413` hängen `.keyboardShortcut` an `MenuBarExtra(.menu)`-Items. Status-Item-Menüs sind nicht in der Key-Equivalent-Kette des Hauptmenüs, ⌘⇧V „Letztes Diktat einfügen“ kann aus der Ziel-App nie gedrückt werden — dem einzigen Ort, wo es nützt.
**Fix:** die drei Diktat-/Meeting-Shortcuts als echte globale Hotkeys (Input Monitoring ist da; Listen-only-Tap von `HotkeyMonitor` oder `NSEvent.addGlobalMonitorForEvents`), oder die angezeigten Equivalents entfernen. ⌘, und ⌘Q behalten.

### 7.5 „Einfügen“ aus einem Notable-Fenster pastet in Notable; Paste-Fehler geschluckt
`RecentDictationsView.swift:121` `try? Paster.insert(text)`: der Klick macht das Fenster key, `Paster.paste` (`Paster.swift:79-117`) synthetisiert ⌘V in dieses Fenster. `NotableApp.swift:354, 387` und `DictationHistory.swift:130` ebenfalls `try?` — `PasteError.accessibilityDenied` wird nirgends gezeigt.
**Fix:** im Fenster „Einfügen“ durch Kopieren ersetzen (oder `NSApp.hide(nil)` + ~150 ms vor dem Paste); `PasteError` ans Overlay.

### 7.6 `LiveNotesView` rendert die ganze Editor-Bridge jede Sekunde neu, mit oder ohne Meeting
`LiveNotesView.swift:25-27, 42` aktualisieren `now` sekündlich; `body` wird neu evaluiert, `NotesTextEditor.updateNSView` (`:414-425`) serialisiert dann das gesamte Attributed-Dokument nach Markdown (`:421`) für einen Vergleich — einmal pro Sekunde beim Tippen, und auch ohne laufendes Meeting.
**Fix:** Uhr in ein kleines `ElapsedLabel` (oder `TimelineView(.periodic)`), nur bei `notes.isActive` starten.

### 7.7 Gemini/Codex sind als Meeting-Provider wählbar, der Summary-Bereich zeigt nichts für sie
`SettingsView.swift:738-802` hat Status-Sektionen nur für `.anthropicAPI` und `.claudeCodeCLI`; `SummarizationProviderID.allCases` hat vier. „Verbindung testen“ (laut `CLAUDE.md` in Settings) existiert nur im Diktat-Bereich (`EnhancementSettingsSection.swift:63`), das `cliArguments.<id>`-Override hat gar keine UI.
**Fix:** `CLIProviderStatusRow(provider:)` aus `EnhancementSettingsSection.swift:62-70, 126-157` extrahieren und in beiden Panes nutzen.

### 7.8 Gleicher Key für beide Hotkeys wählbar; UI stumm, Routing schaltet ab
`EnhancementSettingsSection.swift:37-42` bietet jeden `HotkeySpec`; `HotkeyRouting.swift:35` behandelt einen Match mit dem Plain-Key als „kein Enhance-Key“. Rechts-⌥ für beide → Verbesserung feuert nie, keine Erklärung.
**Fix:** `HotkeySpec.current` aus dem Picker filtern (und umgekehrt) oder Inline-Warnung.

### 7.9 Onboarding-Fenster schließen bringt es bei jedem Start zurück
Nur `finish()` setzt `didCompleteOnboarding` (`OnboardingView.swift:235-239`); `MenuBarLabel.onAppear` öffnet es bei `NotableApp.swift:261-265` erneut, solange false. ⌘W oder roter Knopf → Onboarding beim nächsten Start, für immer.
**Fix:** Schließen als Skip behandeln; „Einführung zeigen“ bietet den Wiedereinstieg.

### 7.10 Berechtigungs-Text zählt falsch und widerspricht dem Onboarding
`SettingsView.swift:826` „Alle fünf werden gebraucht“ — `PermissionsManager.Kind` hat sechs Fälle (`PermissionsManager.swift:55-61`); Onboarding sagt, das Mikrofon sei „die einzige zwingende Berechtigung“ (`OnboardingView.swift:68`).

### 7.11 Irreversible Aktionen ohne Bestätigung und Feedback
`StorageSettingsView.swift:70-73` „Erfasste Ziel-Apps löschen“ (DB-Write, Ergebnis verworfen), `SmartReplaceSettings.swift:46-53` Snippet-Papierkorb, `EnhancementSettingsSection.swift:78-84` Profil-Papierkorb, `SettingsView.swift:761` API-Key entfernen, `MeetingChat.swift:133` „Verlauf löschen“.
**Fix:** `.confirmationDialog` für DB/Keychain, „N gelöscht“-Zeile für den Rest (Vorbild: Retention-Plan-dann-Löschen in `StorageSettingsView.swift:80-96`).

### 7.12 Fehler mit `try?` geschluckt, wo der Nutzer es wissen muss
`SmartReplaceSettings.swift:112` Export und `:119-122` Import (kaputte Datei tut still nichts), `StorageSettingsView.swift:164-173` (`RetentionRunner.Result` trägt keine Fehler), plus 7.5.
**Fix:** `NoteListView.perform` + `.alert` (`NoteListView.swift:246-260`) kopieren — das richtige Muster, schon im Code.

### 7.13 `@AppStorage`-Keys als String-Literale über Views und Controller dupliziert
`"summarizationProvider"` ×3 Views + `MeetingController.swift:273, 361, 438`; `"typingWPM"` (`SettingsView:77`, `StatsView:118`, `UsageSummary:39`); `"showNextMeeting"`, `"showUsageInMenu"`, `"meetingNotesFloating"`, `"didCompleteOnboarding"` je ×2; die fünf `polish*`-Keys in `TextPolisher.swift:44-57`; `dictationIdleTimeout/dictationSounds/appStatistics` in `DictationController.swift:419-495`; `openNotesOnMeetingStart/notifyOnMeetingReady/speakerNamingEnabled/meetingHookPath` im `MeetingController`. Defaults driften: `appStatistics` ist in der View `true`, im Controller „nil ⇒ true“.
**Fix:** `enum DefaultsKey` mit statischen Konstanten (HotkeySpec/RetentionPolicy/MediaInterrupter tun es schon), ein Ort pro Default.

### 7.14 Keine Pluralbehandlung, Locale-blinde Zahlenformate
`StorageSettingsView.swift:86, 98, 120` „1 Sitzungen“/„1 sessions“, `NotableApp.swift:488` „in 1 min“, `EngineCards.swift:66` „(1)“, `StatsView.swift:574` „+12 %“ (deutscher Abstand im Englischen), `SettingsView.swift:513` `%.1f` mit C-Locale.
**Fix:** `.stringsdict` (oder `^[…](inflect: true)`) für Zählungen; `Int.formatted(.percent)` und `Double.formatted(...)`.

### 7.15 Fehlübersetzungen und Register-Drift in `en.lproj/Localizable.strings`
`:96` „Belegung“ = „Key“ (Speicherbelegungs-Header → „Disk usage“), `:427` „Zeitbudget“ = „Size budget“ (Sekunden-Slider → „Time budget“), `:228` „Lernen“ = „Learning“ (Button → „Learn“), `:206/241` Header und Button beide „Clean up now“, `:200` „Always in front“ → „Always on top“, `:425` „the line stays away“ → „the line is hidden“, `:392` „Behaviour“ (BrE) neben „summarized“/„recognized“ (AmE).
**Fix:** ein redaktioneller Durchgang mit offenem englischen UI; eine Schreibvariante.

### 7.16 `SettingsView.swift` (879 Zeilen) hält sieben Views plus dreifache Helper
`relaunch()` existiert dreimal (`SettingsView:209-215`, `:845-851`, `OnboardingView:248-254`); `RememberedConsentSection.displayName` (`:697-709`) re-implementiert die Known-App-Tabelle aus `MeetingDetector.swift:110`; „Letzte Diktate“ (`:522-550`) dupliziert `RecentDictationsView`; Tippgeschwindigkeits-Stepper in `SettingsView:89-95` und `StatsView:391`; das verschachtelte `enum Section` (`:10`) schattet `SwiftUI.Section`, sein Kommentar sagt sechs Panes für sieben.
**Fix:** eine Datei pro Pane, `AppRelauncher.relaunch()`, `MeetingDetector.displayName(for:)`, Enum → `Pane`.

### 7.17 Accessibility-Lücken auf eigenen Controls
`LiveNotesView.swift:106-115` Format-Buttons nur Bild mit `.help`, ohne `accessibilityLabel`; ebenso `SmartReplaceSettings.swift:47-53`, `EnhancementSettingsSection.swift:78-84`, `NoteListView.swift:163-168`; `HeatmapCard.swift:31-36` exponiert 168 unbeschriftete Shapes; `Theme.swift:83-113` `CalSegmented` sind plain Buttons ohne `.isSelected`-Trait und Pfeiltasten-Navigation.

### 7.18 Typografie: Stats, Onboarding, LiveNotes und Cards mit festen Punktgrößen
`StatsView.swift` (≈25 Stellen, 9–40 pt), `OnboardingView.swift:116, 123, 130, 152, 155`, `LiveNotesView.swift:57, 63, 70, 98, 109, 142, 158`, `DetailCard.swift`, `EngineCards.swift`, `HeatmapCard.swift`, während Settings `.caption/.callout` nutzt. Diese Fenster ignorieren die System-Textgröße.
**Fix:** Textstile (`.caption2/.caption/.callout/.body/.title2`) mit `.weight()`; feste Größe nur für die Hero-Zahl.

### 7.19 `SmartReplaceSection` hält eine stale Kopie des Wörterbuchs
`SmartReplaceSettings.swift:13` lädt `dictionary` einmal und aktualisiert nur in `persist()` (`:97-100`); `DictationSettingsView` editiert das Wörterbuch bei `SettingsView.swift:445-466`, ohne es mitzuteilen — die Kollisionswarnung (`:32-36`) hinkt.
**Fix:** `SmartReplaceSection(dictionary:)` vom Parent.

### 7.20 Synchrones Directory-Listing im Menü-Builder jeder Notizzeile
`NoteListView.swift:151` ruft `noteManager.projectFolders()` (`FileManager.contentsOfDirectory`, `NoteManager.swift:40-52`) im `Menu`-Content für jede von bis zu 200 Zeilen.
**Fix:** einmal in `NoteManager.reload()` in `@Published projectFolders` laden.

### Chancen
- **Echte globale Shortcut-Schicht** für „letztes Diktat einfügen“, „letzte Diktate zeigen“, „Meeting starten/stoppen“, mit HUD-Flash bei Paste-Fehler.
- **Ein „Dienste“-Pane + Settings-Deep-Links**: gemeinsame Provider-Status-Zeile (Pfad, Verfügbarkeit, Testaufruf, Argument-Override) für Meeting-Summary und Diktat-Verbesserung; `presentWindow("settings", pane: .summary)`, damit Onboarding (`OnboardingView.swift:92-95`) und Notifications im richtigen Pane landen.
- **Lokalisierung als System, nicht als Tabelle**: `String(localized:)` für jedes Enum-Label, stringsdict, Scanner, der Enum-Labels gegen das en-Bundle auflöst, ein End-to-End-Durchgang durch das englische UI.

---

## 8. Empfohlene Reihenfolge

**Einzeiler mit größter Wirkung (heute):**
1. `--no-session-persistence` in `ClaudeCodeCLIProvider.swift:58` (6.1)
2. Füllwort-Regex `TextPolisher.swift:152` (3.2)
3. `pendingSwap`-Check ins `defer` in `DictationController` (3.1)
4. `LSMultipleInstancesProhibited: true` in `project.yml` (6.10)
5. `commonRules` nicht mehr im Editor-Save anhängen (7.3)
6. `engine` aus dem tatsächlich benutzten Transcriber (5.2)

**Diese Woche:**
- Updater: Signatur-/Team-ID-Prüfung, Swap-Skript-Guards, kein Update während Aufnahme (6.2, 6.3, 6.12)
- IO-Proc entlasten: Ringpuffer + serielle Queue (4.1)
- CLI-Runner: Cancellation-Handler, PATH, `--system-prompt`, `--tools ""` (6.4, 6.5, 6.6)
- Retention: `raw_text` leeren, geleerte Diktate aus dem Menü (5.1, 5.16)
- Sleep/Wake-Padding (4.3)

**Nächste Iteration (Architektur):**
- Capture/Processing trennen, Processing-Queue (4.2)
- Pipeline aus dem Spool streamen, `MeetingNoteProducer` nonisolated (4.4, 4.5, 4.12)
- `DictationPipeline` mit Injektion, `EngineSlot<T>` (3.19)
- `SQLiteConnection` + versionierte Migrationen + FTS5 (5.4–5.9, 5.20)
- Lokalisierung: Enum-Labels, Scanner, stringsdict (3.10, 5.15, 6.13, 7.1, 7.2, 7.14)

**Doku angleichen (`CLAUDE.md`):** Inkrementelles Dekodieren (3.6), `recordingGeneration` (3.9), „Verbindung testen“ für alle CLI-Provider (7.7), Lokalisierungs-Scanner-Reichweite (7.1), Capture-Warnung bei Recovery (4.6), CLI-Session-Persistenz (6.1).
