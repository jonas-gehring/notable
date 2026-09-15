# Spec 34 — Die Aufnahme endet mit dem Call

> **Aufwand: S–M (1–2 Tage).** Spec 09 hat das Ende eines Calls messbar gemacht, und in
> den meisten archivierten Meetings stoppte die Aufnahme Sekunden nach dem letzten Wort.
> Drei Fälle laufen trotzdem weiter — der Owner hat alle drei erlebt (Teams als App,
> Call im Browser, manuell gestartet). Diese Spec schließt sie und hält fest, *warum*
> eine Aufnahme endete, damit der nächste Fall nicht wieder rekonstruiert werden muss.

## 1. Ausgangslage (Fakten aus dem Code und den Daten, 2026-09-15)

- **Messung:** In 17 von 20 Meetings der letzten 45 Tage endete die Aufnahme
  0,1–0,4 min nach dem letzten Wort; einmal (04.08.) 16 min danach. Ob der Detektor
  stoppte oder die Hand, sagt keine Quelle: der Detektor loggte nichts, `meta.json`
  kannte weder Startart noch Endgrund.
- **Manueller Start vor der Erkennung läuft endlos.** `startedDuringCall` wird nur
  beim Start gesetzt (`auto || isCallActive()`). Bestätigt der Detektor den Call
  danach (≈ 10 s), fragt `ConsentCoordinator.callDetected` *mitten in der eigenen
  Aufnahme* noch einmal nach, `startAutomatically` lehnt mit `.alreadyRecording` ab,
  und beim Call-Ende scheitert `stopAutomatically()` an seinem Guard.
- **Eine App, die nach dem Auflegen ihre Ausgabe offen hält, beendet den Call nie.**
  Für dedizierte Apps zählt `isActive` (Eingabe *oder* Ausgabe) — gewollt, weil
  stummgeschaltet-zuhören ein laufender Call ist (Spec 09 §3.4), aber nie im echten
  Call gemessen (Spec 09 §10).
- **Ohne Call-Prozess gibt es kein Ende.** Browser-Calls enden nur, wenn der Browser
  das Mikrofon freigibt; Telefon, vor Ort, unbekannte Apps nie.

## 2. Ziel

Jede Aufnahme endet, wenn der Call endet — und wo kein Call-Ende messbar ist, fragt
Notable nach längerer Stille und stoppt, wenn niemand antwortet. Jede Aufnahme sagt
hinterher, wie sie begann und warum sie endete.

## 3. Konzept

### 3.1 A — Eine laufende Aufnahme übernimmt den erkannten Call

`ConsentCoordinator.callDetected` fragt zuerst `meeting.adoptDetectedCall(source:)`.
Läuft eine Aufnahme, setzt der Controller `startedDuringCall = true`, merkt sich die
Quelle und der Koordinator geht auf `.recording` — **keine** zweite Nachfrage. Vor dem
Hauptschalter „automatisch aufnehmen": der betrifft das Starten, nicht das Enden.

### 3.2 B — Nur Ausgabe offen zählt nur, solange die Gegenseite hörbar ist

`CallEndRule.isStillActive` (pur): Mikrofon gehalten → läuft. Dedizierte App mit nur
Ausgabe → läuft, solange die **Systemspur der Aufnahme** in den letzten 60 s Ton hatte
(`remoteSilenceForEnd`). Stummgeschaltet-zuhörend hat Ton auf der Systemspur; eine
aufgelegte App, die ihren Stream offen hält, nicht. Ohne Aufnahme oder ohne Systemspur
gilt die alte Regel. Browser und Slack: unverändert nur das Mikrofon.

### 3.3 C — Sicherheitsnetz Stille, für jede Aufnahme

`MeetingSilenceWatch` (pur), einmal pro Sekunde mit dem Pegel beider Spuren:

- beide Spuren **3 min** ohne Ton → Mitteilung „Kein Ton in der Aufnahme" mit
  **Aufnahme beenden** / **Weiter aufnehmen**, dazu die Statuszeile im Menü;
- **2 min** später weiter still und keine Antwort → Stopp (`endReason = silence`);
- ein Ton dazwischen → Mitteilung zurückgezogen, die Zählung beginnt neu;
- „Weiter aufnehmen" → nächste Frage erst nach **10 min** Stille.

Zwei Schwellen wie `IdleDetector`: Stille beginnt unter 0,005 RMS, endet erst über
0,015; dazwischen bleibt der Zustand. **Startwerte, nicht gemessen.**

### 3.4 D — Wie sie begann, warum sie endete

`SpoolStore.Meta` bekommt `startMode` (`automatic`/`manual`), `callSource` und
`endReason` (`manual`, `callEnded`, `silence`, `quit`), nachsichtig dekodiert wie
`diagnostics`. Dazu Log-Einträge (Subsystem `de.jonasgehring.notable`): Call erkannt,
Call beendet, Aufnahme gestartet/übernommen/beendet mit Grund, Stille-Frage.

## 4. Integration

- `MeetingDetector.remoteSilentFor` ← `MeetingController.remoteSilentFor`
  (`AppDelegate`), `NotificationCenterService.onMeetingSilenceAction` ←
  `MeetingController.silenceAnswered`.
- `SystemAudioTap.level` (RMS des letzten Chunks, wie `AudioRecorder.level`).
- `stop()` heißt `stop(reason:)`; alle vier Aufrufer nennen ihren Grund.
- `CallEnd.swift` steht als `path:` im Testziel (der Detektor im Testziel braucht es).

## 5. Risiken

- **B beendet einen echten Call, in dem 60 s niemand spricht *und* die App das
  Mikrofon freigibt** (etwa Teams, falls es beim Stummschalten freigibt — ungemessen).
  Dann endet die Aufnahme zu früh; `endReason = callEnded` im Archiv zeigt es, und die
  Schwelle steht an einer Stelle.
- **C fragt in einer langen, gewollten Stille** (Präsentation ohne Ton, Warteraum).
  Deshalb erst fragen, und nach „Weiter aufnehmen" zehn Minuten Ruhe.
- **Die Pegel-Schwellen sind geraten.** Ein lauter Raum hält die Aufnahme am Leben —
  das ist die sichere Richtung.

## 6. Abnahme

1. `CallEndRuleTests`, `MeetingSilenceWatchTests`, `SpoolMetaLifecycleTests` grün;
   die bestehenden Detektor- und Spool-Tests unverändert grün.
2. Manuell aufnehmen, *dann* dem Teams-Call beitreten: keine „Meeting erkannt"-Frage;
   Auflegen → Aufnahme endet; `meta.json`: `startMode = manual`, `endReason = callEnded`.
3. Teams-App nach dem Auflegen offen lassen → Aufnahme endet binnen etwa 90 s.
4. Stummgeschaltet in einem Call, in dem andere sprechen → Aufnahme läuft weiter.
5. Browser-Call verlassen, Tab bleibt offen → spätestens nach 3 min Frage, nach 5 min
   Stopp (`endReason = silence`), falls der Browser das Mikrofon hält.
6. „Weiter aufnehmen" → keine neue Frage vor 10 min Stille.

## 7. Offene Entscheidungen

- Keine. Entschieden am 2026-09-15: B wie beschrieben; C „erst fragen, dann stoppen"
  (3 + 2 min).

## 8. Stand des Baus (2026-09-15)

Gebaut: A–D wie beschrieben. Abnahme 2–6 sind Handtests im echten Call und offen.
