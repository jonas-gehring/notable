# Spec 05 — Live-Partial-Text reaktivieren (inkrementelles Decoding)

> **Aufwand: S–M.** Text erscheint live im Overlay während des Sprechens; beim
> Loslassen ist fast alles schon da.
> **Achtung — bewusste Entscheidung:** Der ganze Apparat ist **schon gebaut**
> (`IncrementalDictation.swift`, `DictationSession`, `ParakeetTranscriber.makeSession`,
> Overlay-`updatePartial`), wurde aber in Commit `c90bb30` **absichtlich abgeschaltet**
> zugunsten robuster Ganzclip-Transkription (robust über clever). Diese Spec
> reaktiviert ihn **nur mit Zustimmung** und unter strengen Stabilitätsgarantien.

## 1. Ausgangslage (Fakten aus dem Code)

- `DictationController.finishRecording` nutzt heute **Ganzclip**: eine ASR-Passage auf
  Release (`rawTranscript`, `DictationController.swift:358–381`). Der Level-Timer macht nur
  den Pegel, kein Vor-Decoding (`:258–261`).
- `DictationSession` (`IncrementalDictation.swift:66`) kann während der Aufnahme stabile
  Kopf-Stücke an Silbenpausen dekodieren (`feedStableHead`) und beim Loslassen nur den Rest
  (`finish`). Es kennt seine eigene Falle: oberhalb ~14 s pro Slice routet FluidAudio in
  den *stateless* Chunker und der mitgeführte Decoder-State „reißt" — dann wirft es
  `sliceExceedsStatefulLimit`, und der Aufrufer muss auf Ganzclip zurückfallen.
- Das Overlay hat einen ungenutzten `updatePartial`-Pfad für Live-Text.

Warum es abgeschaltet wurde: Die inkrementelle Variante hatte in der Praxis Hänger/
Kontextabrisse bei langen Diktaten. Ganzclip ist langsamer bei 60 s (~400 ms), aber immer
korrekt.

## 2. Ziel

Zwei getrennt schaltbare Gewinne, in dieser Priorität:

1. **Live-Partial-Text im Overlay** (der sichtbare Effekt) — auch wenn das finale
   Ergebnis weiterhin per Ganzclip entsteht.
2. **Latenzgewinn bei langen Diktaten** durch echtes inkrementelles Vor-Decoding (nur der
   Tail bleibt beim Loslassen).

Diese Trennung ist der Schlüssel: **(1) ist risikoarm, (2) ist der riskante Teil.** Wir
können (1) liefern, ohne (2) scharf zu schalten.

## 3. Zwei Betriebsarten

### Modus 1 — „Partial-Anzeige, Ganzclip-Wahrheit" (empfohlener Default, wenn an)
- Während der Aufnahme läuft ein `DictationSession` **nur zur Anzeige**: `feedStableHead`
  produziert Partial-Text → `overlay.updatePartial(session.text + tail?)`.
- Beim Loslassen wird das **finale Ergebnis trotzdem per Ganzclip** erzeugt (heutiger,
  robuster Pfad). Der inkrementelle Text war nur Vorschau; das eingefügte Ergebnis ist die
  bewährte Ganzclip-Ausgabe.
- **Risiko:** minimal — der Anzeige-Pfad kann nie das eingefügte Ergebnis verfälschen. Wenn
  die Session `sliceExceedsStatefulLimit` wirft oder hängt, wird die Partial-Anzeige still
  eingefroren, die Wahrheit bleibt Ganzclip.
- **Kosten:** etwas ANE-Last während der Aufnahme (Vor-Decoding). Für normale Diktate
  vernachlässigbar; abschaltbar.

### Modus 2 — „Inkrementell final" (opt-in, der Latenz-Modus)
- Wie Modus 1, aber beim Loslassen liefert `session.finish(with:)` das **finale** Ergebnis
  (nur der Tail wird noch dekodiert → geringere Release→Paste-Latenz bei langen Clips).
- **Harte Fallback-Regel:** Wirft die Session irgendwann `sliceExceedsStatefulLimit` (oder
  ein anderer Fehler), wird der **komplette Clip per Ganzclip** neu transkribiert und dieses
  Ergebnis eingefügt. Das ist genau die in `DictationSession` schon vorgesehene Semantik —
  wir müssen sie im Controller nur verdrahten.
- **Nur für lange Diktate** aktiv (> `minimumPendingSeconds`, 8 s). Kurze Diktate laufen
  weiter Ganzclip — dort ist Ganzclip ohnehin ~120 ms.

## 4. Integration

In `DictationController`:

- `beginRecording`: wenn Partial/Inkrementell aktiv **und** Engine == Parakeet v3 (der
  einzige mit `TdtDecoderState`; Unified/Whisper haben keine Session) → eine Session über
  `ParakeetTranscriber.makeSession()` anlegen. Der Level-Timer (`:242`) füttert nicht nur
  den Pegel, sondern ruft periodisch (z. B. jede ~1–2 s, nicht jeden 0.1-s-Tick)
  `feedStableHead` mit einem **Snapshot** des Recorders und aktualisiert `updatePartial`.
- Serialisierung: `DictationSession`-Calls müssen serialisiert sein (sagt der Doc-Kommentar).
  Ein `Task`-Ketten-/`isProcessing`-Guard verhindert überlappende `feed`-Aufrufe — ein
  laufender Vor-Decode wird nicht doppelt gestartet.
- `finishRecording`:
  - Modus 1: Ganzclip wie heute; Partial nur weggeworfen/als Overlay-Endzustand.
  - Modus 2: `try? session.finish(with: allSamples)`; bei nil/Fehler → `rawTranscript`
    (Ganzclip). Danach identisch weiter (Polishing, Paste, Speichern, Latenzmessung).
- Generationszähler (`recordingGeneration`) auch in den Session-Callbacks prüfen (wie überall
  im Controller), damit ein alter Vor-Decode ein neues Diktat nicht kontaminiert.

## 5. UI

Settings → Diktat, Abschnitt „Textqualität"/„Leistung":

- Toggle **„Live-Text während des Diktierens anzeigen"** (Modus 1). Default: **konservativ
  AUS**, bis in der Praxis bestätigt — entschieden wird beim Aktivieren (die
  Abschaltung war eine bewusste Stabilitätsentscheidung).
- Toggle **„Lange Diktate schneller einfügen (inkrementell)"** (Modus 2), abhängig sichtbar
  nur bei Engine Parakeet v3, mit Hinweis „fällt bei Bedarf automatisch auf Ganzclip zurück".
- Das Overlay zeigt Partial-Text kompakt (eine/zwei Zeilen, `updatePartial`), reduce-motion-fest.

## 6. Edge Cases

- **Engine ≠ Parakeet v3:** keine Session, Partial-Anzeige aus (kein `TdtDecoderState`).
  Unified hat echtes Streaming — separater, späterer Weg; hier nicht vermischen.
- **`sliceExceedsStatefulLimit` / Hänger:** Modus 1 friert Anzeige ein; Modus 2 fällt auf
  Ganzclip zurück. **Nie** den halb-inkrementellen Text einfügen, wenn die Session
  abgebrochen ist.
- **Audio-Gerätewechsel:** bestehender Abbruchpfad (`onConfigurationChange`) räumt die
  Session mit ab.
- **Sehr kurzes Diktat:** Session tut nichts (`feedStableHead` returned false unter 8 s
  Pending) — Ganzclip.
- **ANE-Kontention** mit Modell-Warmladen beim Start: Session erst starten, wenn
  `modelState == .ready`.

## 7. Tests

- `IncrementalDictation.cutPoint` ist schon getestet — beibehalten.
- Neuer Test: `DictationSession` über einen Fake-`AsrManager`, der stückweise Text liefert →
  `feedStableHead`/`finish` akkumulieren korrekt; Slice über Limit wirft
  `sliceExceedsStatefulLimit`.
- Controller-Test (mit Fake-Session/Transcriber): Modus 2 nutzt Session-Ergebnis; bei
  geworfenem Limit-Fehler wird Ganzclip aufgerufen und **dessen** Ergebnis eingefügt.
- Manuelle Verifikation über `LatencyProbeTests`-Stil + echtes langes Diktat: 60 s Release→Paste
  messbar niedriger als Ganzclip; Ergebnis textgleich zur Ganzclip-Referenz (keine
  Kontextabrisse).

## 8. Umsetzungsschritte

1. Modus 1 zuerst (Partial-Anzeige, Ganzclip-Wahrheit) — reiner Gewinn, kaum Risiko.
2. In der Praxis am eigenen Rechran über Tage bestätigen, dass die Anzeige stabil ist.
3. Erst dann Modus 2 (inkrementell final) mit hartem Ganzclip-Fallback scharf schalten.
4. Latenz vorher/nachher dokumentieren (füttert Spec 01 Latenz-Panel).

## 9. Nicht-Ziele / Vorsicht

- **Die Ganzclip-Abschaltung nicht ohne ausdrückliches OK rückgängig machen.** Sie war eine
  Stabilitätsentscheidung (Commit `c90bb30`). Modus 1 ist der sichere Wiedereinstieg.
- Kein inkrementelles Decoding für Unified/Whisper in dieser Spec.
- Kein Verändern der `DictationSession`-Kernlogik — sie ist korrekt; wir verdrahten sie nur.
