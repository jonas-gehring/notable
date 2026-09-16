# Spec 39 — Genauigkeit: erst messen, dann heben

> **Aufwand: S (Messen) + S (Pre-Roll) + S–M (Konfidenz) + S (Meetings) + S (Phonetik)
> + M (Vokabular, hängt an Spec 32).** Die Analyse vom 14.09. sagt: „Die Lücke liegt
> nicht in der Erkennung." Das stimmt für die *Latenz* — und ist für die *Genauigkeit*
> unbelegt, weil Notable sie noch nie gemessen hat. Diese Spec baut zuerst die Messung
> und dann die fünf Hebel, die vor dem Modell liegen. **Kein Modellwechsel**: Parakeet
> v3 ist heute nicht der Engpass, alles davor ist es.

## 1. Ausgangslage (gemessen am 2026-09-16 an der laufenden Installation)

- **Es gibt keine Genauigkeitsmessung.** Kein WER-Harness, kein Korpus, kein
  Referenztext. `grep -rniE "wordErrorRate|\bWER\b" Sources Tests` findet nur einen
  Kommentar über Parakeet Unified („WER 2.2 % streaming") — eine Herstellerzahl über
  Englisch, nicht über diesen Nutzer.
- **Der Rohtext wird nicht aufbewahrt.** `recordings.raw_text` ist in **0 von 234**
  Diktaten belegt: die Spalte wird nur geschrieben, wenn die LLM-Verbesserung lief. Was
  die ASR wirklich lieferte, bevor `TextPolisher` darüber ging, steht nirgends.
- **Das Diktat-Audio ist weg.** RAM-only, nach dem Einfügen verworfen (`LastClip` hält
  genau einen fehlgeschlagenen Clip). Es gibt also nichts, wogegen man einen
  Referenztext stellen könnte.
- **Das persönliche Wörterbuch ist leer.** 0 Einträge, 0 gelernte Vorschläge, 0
  Textbausteine — nach 234 Diktaten. Der einzige Genauigkeits-Hebel, den es seit v1
  gibt, wurde nie benutzt. Die Erklärung liegt nahe: Notable sagt nie, *welches* Wort
  es nicht kannte; man muss den Fehler selbst bemerken, den Korrektur-Dialog öffnen und
  ihn abtippen.
- **Konfidenz wird weggeworfen.** FluidAudios `tokenTimings` trägt pro Token
  `startTime`/`endTime`/`confidence`. Spec 31 liest daraus die Pausen; **kein einziger
  Codepfad liest `confidence`** (`grep -rn "confidence" Sources/Notable` ist leer).
- **Kein Pre-Roll, kein Nachlauf.** Die Aufnahme beginnt im keyDown-Zweig des
  Event-Taps — die Analyse §3 A11 nennt ~50–100 ms fehlendes Audio am Anfang — und
  endet exakt beim Loslassen (`AudioRecorder.stop()`). Wispr Flow nimmt an beiden Enden
  über den Tastendruck hinaus auf.
- **Meetings laufen auf dem Diktat-Modell.** `meetingUseDictationEngine` ist `false`,
  was auf Parakeet v3 hinausläuft — dasselbe Modell, das für 119 ms Latenz gewählt
  wurde, in einem Pfad, in dem Latenz keine Rolle spielt und Whisper Large bereits auf
  der Platte liegt.
- **Die unscharfe Wörterbuchsuche ist Levenshtein** (`TextPolisher.swift:548`). Für
  deutsche Eigennamen ist das das falsche Maß: „Meier"/„Mayer"/„Maier" haben Abstand 1–2
  und sind dasselbe Wort; „Meier"/„Meyer" und „Beier" ebenfalls Abstand 1, aber
  verschiedene Wörter.

Was daraus folgt: Jede Aussage über „die Erkennung ist gut/schlecht" wäre heute geraten.
**Stufe 0 ist deshalb keine Vorarbeit, sondern die Spec.**

## 2. Ziel

Notable kann sagen, wie gut es diesen Nutzer versteht — in Zahlen, pro Engine, pro
Sprache, pro Ziel-App —, und jede Änderung an Regeln, Modell oder Aufnahme lässt sich
gegen dieselbe Messung stellen. Die drei Fehlerklassen, die *vor* dem Modell liegen
(abgeschnittene Enden, unbekannte Eigennamen, nicht gelernte Korrekturen), sind
geschlossen. Und ein Wort, das Notable nicht kannte, sagt das, statt still falsch zu
sein.

## 3. Konzept

### 3.0 Stufe 0 — Der Korpus und das Maß (S, Voraussetzung für alles)

Ein Schalter unter Diktat › Erweitert: **„Qualitätsmessung"** (aus in der Vorgabe).
Solange er an ist:

- Jeder Diktat-Clip wird als `.i16` unter `Application Support/Notable/quality/<id>.i16`
  behalten, zusammen mit `raw` (ASR-Ausgabe vor `TextPolisher`), `polished`, Engine,
  Sprache, Ziel-App und Dauer in `<id>.json`. **Ringpuffer: die letzten 50** — mehr
  braucht niemand, und es sind ~1,5 MB je Minute.
- `recordings.raw_text` wird **immer** geschrieben, nicht nur bei LLM-Verbesserung. Die
  Spalte existiert, ist nullable und wird nicht rückwirkend befüllt (Spec 01-Regel).
- Im Fenster „Letzte Diktate" bekommt jeder Eintrag mit Clip ein **„Referenz
  eingeben…"**: der Nutzer korrigiert den Text auf das, was er gesagt hat. Das ist
  derselbe Dialog wie „Korrigieren…", nur wird das Ergebnis zusätzlich als
  `reference` in die `.json` geschrieben.
- `WERProbeTests` (läuft nur mit `TEST_RUNNER_NOTABLE_QUALITY=1`, wie
  `MeetingReplayTests`) transkribiert jeden Clip mit **jeder** verfügbaren Engine und
  druckt WER und CER, aufgeschlüsselt nach Engine, Sprache und Ziel-App, dazu die
  häufigsten Substitutionen. **Die Substitutionsliste ist der eigentliche Ertrag**: sie
  sagt, ob die Fehler Eigennamen, Zahlen, Wortenden oder echte Modellfehler sind — vier
  verschiedene Baustellen, von denen nur die letzte ein anderes Modell braucht.

Der WER-Rechner ist pur (`WordErrorRate.swift`: Levenshtein über Wortfolgen mit
Rückverfolgung zu Substitution/Einfügung/Auslassung) und wird gegen bekannte Paare
getestet. Normalisierung vor dem Vergleich: Kleinschreibung, Satzzeichen weg, Zahlen
ausgeschrieben — sonst misst man `GermanITN` statt der ASR.

**Datenschutz:** Der Ordner enthält Audio. Er liegt neben dem Spool, verlässt das Gerät
nie, ist auf 50 Clips begrenzt, wird beim Ausschalten des Schalters gelöscht und
erscheint in `StorageFootprint` als eigene Zeile (sonst wäre es genau der unsichtbare
Posten, den Spec 21 abgeschafft hat).

### 3.1 Stufe 1 — Pre-Roll und Nachlauf (S, der sicherste Gewinn)

- **Pre-Roll:** Der Recorder läuft nicht erst ab keyDown. `AudioRecorder` hält einen
  Ring von **300 ms**, der gefüllt wird, sobald… — und hier liegt die Entscheidung
  (§7): entweder dauerhaft (das Mikrofon ist dann immer offen, was diese App bisher
  ausdrücklich nicht tut und was die Mikrofon-Anzeige von macOS permanent einschaltet),
  oder ab dem **Niederdrücken des Modifiers** im Flags-Tap, der ohnehin always-on ist.
  Vorschlag: der Flags-Tap. Er feuert typisch 100–300 ms vor dem eigentlichen
  Auslösen, kostet keine Dauerspur und ist genau die Lücke, die heute fehlt.
- **Nachlauf:** Nach dem Loslassen **250 ms** weiterschreiben, bevor `stop()` den Puffer
  übergibt. Das rettet die letzte Silbe („…machen" statt „…mach"), kostet 250 ms auf der
  gemessenen Strecke Loslassen → Einfügen, und beides muss in derselben Messung stehen.
- Beides wird gegen den Korpus aus Stufe 0 gemessen: dieselben 50 Clips, einmal mit,
  einmal ohne. **Wenn die Substitutionsliste keine abgeschnittenen Wortenden zeigt,
  wird der Nachlauf nicht gebaut** — 250 ms Latenz für nichts ist ein schlechter Tausch.

### 3.2 Stufe 2 — Konfidenz sichtbar machen (S–M, der Hebel für das leere Wörterbuch)

`ParakeetTranscriber.transcribeDetailed` liefert die Konfidenz schon; sie wird nur
verworfen. Neu:

- `recordings.low_confidence_words TEXT` (nullable, nie rückwirkend befüllt): die Wörter
  unter der Schwelle, mit Position.
- In „Letzte Diktate" werden sie im Text **unterstrichelt** dargestellt. Ein Klick
  darauf öffnet die Korrektur mit genau diesem Wort vorbelegt — aus dem Fehler wird in
  zwei Klicks ein Wörterbuch-Eintrag. Das ist Spec 06 Quelle B, die endlich *sagt*, wo
  sie ansetzt.
- Die Schwelle ist **zu messen** (Stufe 0 liefert sie: die Konfidenzverteilung der
  falschen gegen die der richtigen Wörter). Startwert erst nach dieser Messung, keine
  runde Zahl aus dem Bauch.
- **Nichts wird automatisch korrigiert.** Ein niedriger Wert heißt „unsicher", nicht
  „falsch"; ein automatischer Ersatz wäre genau die Sorte selbstsicherer Fehler, die
  diese Codebasis überall sonst verbietet.

### 3.3 Stufe 3 — Vokabular in die lokale Textstufe (M, hängt an Spec 32)

Das ist Wispr Flows eigentlicher Genauigkeits-Trick, und er ist kein ASR-Trick: der
LLM-Durchlauf repariert Homophone und Eigennamen, die die Erkennung nie kennen konnte.
Lokal (FoundationModels, Spec 32) geht das ohne Datengrenze. In den Prompt gehören:

1. das persönliche Wörterbuch und die Textbausteine,
2. die **Teilnehmer des laufenden Kalendertermins** (EventKit liest Notable schon),
3. die Eigennamen der letzten zwanzig Notizen (aus `recordings.participants` und
   `attendees`, nicht aus dem Fließtext).

Damit wird „Jana Schulze" zu „Jana Schultze", ohne dass ein Modell nachtrainiert wird
und ohne dass ein Zeichen das Gerät verlässt. **Setzt die Messung aus Spec 32 §8
voraus** (Apple Intelligence ist auf dem Build-Rechner aus) und die Regel von dort: die
Abnahme ist invertiert — keine Zahl und kein großgeschriebenes Wort, das nicht im Input
stand. Ein Name aus der Vokabelliste ist die **eine** erlaubte Ausnahme, und nur bei
einem Wort mit niedriger Konfidenz (Stufe 2) und geringem phonetischem Abstand
(Stufe 5).

### 3.4 Stufe 4 — Meetings bekommen das beste Modell (S)

Im Meeting-Pfad gibt es keine Latenzgrenze: die Notiz entsteht nach dem Call, im
Hintergrund. Also darf dort das langsamere, bessere Modell laufen — Whisper Large v3
liegt bereits auf der Platte, und `meetingUseDictationEngine` existiert schon als
Schalter, er steht nur auf „Diktat-Modell".

Vorgehen, nicht Annahme: **drei archivierte Meetings aus `spool-archive/` mit beiden
Modellen transkribieren und die Transkripte nebeneinanderlegen** (die Archive sind
ALAC, verlustfrei, genau dafür aufgehoben). Erst wenn Whisper dort sichtbar besser ist,
wird es die Vorgabe für Meetings — und die Zeile in den Einstellungen sagt, dass die
Notiz dann ein paar Minuten später fertig ist.

Zweite Möglichkeit, falls die Messung uneindeutig ist: **Zweitmeinung** — nur die
Segmente mit niedriger Konfidenz (Stufe 2) werden mit dem zweiten Modell nachgerechnet.
Das ist teurer im Code als in der Zeit und bleibt Rückfalloption.

### 3.5 Stufe 5 — Phonetik statt Buchstabenabstand (S)

Die unscharfe Wörterbuchsuche bekommt **Kölner Phonetik** (das deutsche Pendant zu
Soundex, für deutsche Namen gebaut) als zusätzliches Maß: ein Treffer verlangt
Levenshtein ≤ heutige Schwelle **oder** gleichen Phonetikcode bei Längenunterschied ≤ 2.
Für Englisch bleibt es beim heutigen Maß — Kölner Phonetik auf englische Wörter
angewandt ist Unfug, und `SpokenLanguages` sagt schon, welche Sprache vorliegt.

Wirkt erst, wenn das Wörterbuch nicht leer ist — also **nach** Stufe 2. Die Reihenfolge
ist kein Zufall: heute würde diese Stufe exakt nichts ändern.

### 3.6 Was bewusst nicht gebaut wird

- **Ein anderes ASR-Modell.** FluidAudio bietet für Deutsch nichts oberhalb von
  Parakeet v3 (`Repo`: v3, v2, CTC-Varianten, ja, EOU-Realtime, Unified-Englisch);
  Whisper Large ist fürs Diktat zu langsam. Wenn Stufe 0 zeigt, dass die Mehrheit der
  Fehler echte Modellfehler sind, wird das hier neu aufgemacht — vorher nicht.
- **Cloud-ASR.** Architektur (CLAUDE.md).
- **Nachtrainieren / Fine-Tuning.** Ein personalisiertes CoreML-Modell wäre die
  ehrlichste Form von „lernt meine Stimme" — und ein Modellverwaltungs-Fall, den Spec 20
  noch nicht einmal für heruntergeladene Modelle zu Ende gebracht hat.
- **Automatische Korrektur unsicherer Wörter** (§3.2).

## 4. Integration

| Stelle | Änderung |
|---|---|
| `Support/WordErrorRate.swift` (neu, pur) | WER/CER mit Substitutionsliste |
| `Dictation/QualityCorpus.swift` (neu) | Ringpuffer 50, `.i16` + `.json`, Löschen beim Ausschalten |
| `Dictation/DictationTextStages.swift` | `raw_text` immer schreiben; Korpus-Haken |
| `Dictation/AudioRecorder.swift` | Pre-Roll-Ring, Nachlauf (§3.1) |
| `Dictation/HotkeyMonitor.swift` | Pre-Roll-Start am Flags-Tap |
| `Dictation/ParakeetTranscriber.swift`, `TranscriptionEngine.swift` | Konfidenz durchreichen |
| `Storage/SQLiteConnection.swift` | Migration: `recordings.low_confidence_words` |
| `Notes/RecentDictationsList.swift` | unsichere Wörter markiert, Klick → Korrektur; „Referenz eingeben…" |
| `Dictation/TextPolisher.swift`, `Support/KoelnerPhonetik.swift` (neu, pur) | §3.5 |
| `Dictation/LocalPolish.swift` | Vokabular in den Prompt (§3.3) |
| `Settings/…` | „Qualitätsmessung" unter Diktat › Erweitert; Meeting-Modell-Zeile |
| `Storage/StorageFootprint.swift` | `quality/` als eigene Zeile |
| `Tests/WERProbeTests.swift` (neu, gated), `WordErrorRateTests`, `KoelnerPhonetikTests` | — |

## 5. Risiken

- **Der Korpus ist Audio auf der Platte.** 50 Clips, ein Schalter, eine sichtbare Zahl,
  Löschen beim Ausschalten. Trotzdem die erste Stelle, an der Notable Diktat-Audio
  *behält* — deshalb aus in der Vorgabe und eine Entscheidung (§7).
- **Pre-Roll am Flags-Tap heißt: das Mikrofon öffnet bei jedem Druck auf den Modifier**,
  auch wenn nie diktiert wird. Bei `fn` ist das häufig. Gegenmittel: der Ring läuft erst
  nach 80 ms Halten an und wird verworfen, wenn kein Diktat folgt — und die
  Mikrofon-Anzeige von macOS blinkt trotzdem. Das ist der ehrliche Preis und gehört in
  §7.
- **Nachlauf kostet Latenz** — 250 ms auf 119 ms sind sichtbar. Wird nur gebaut, wenn
  die Messung die Fehlerklasse zeigt.
- **WER über 50 Clips ist eine kleine Stichprobe.** Sie taugt für Vorher/Nachher an
  *derselben* Stichprobe, nicht für absolute Aussagen. Die Spec behauptet nirgends
  anderes.
- **Referenztexte tippt der Nutzer.** Ein falsch getippter Referenztext erzeugt einen
  Fehler, den es nicht gab. Deshalb ist die Referenz optional und das Werkzeug zeigt
  beide Texte nebeneinander.

## 6. Abnahme

1. Schalter an, zehn Diktate: zehn Clips mit `.json`, Ringpuffer hält 50, Schalter aus
   löscht den Ordner, `StorageFootprint` nennt ihn.
2. `WordErrorRateTests` grün gegen bekannte Paare (identisch ⇒ 0; ein Wort ersetzt ⇒
   1/n; Einfügung und Auslassung getrennt gezählt).
3. `WERProbeTests` druckt für den Korpus WER/CER je Engine und die zwanzig häufigsten
   Substitutionen; das Ergebnis steht in §8 dieser Spec.
4. Pre-Roll: ein Diktat, das mit dem ersten Laut beginnt, verliert ihn nicht (Messung am
   Korpus, nicht nach Gefühl). `LatencyProbeTests` vorher/nachher protokolliert.
5. Konfidenz: unsichere Wörter sind markiert; Klick legt einen Wörterbuch-Eintrag an;
   nach zwei Wochen Gebrauch ist das Wörterbuch **nicht mehr leer** (die eigentliche
   Abnahme dieser Stufe).
6. Meetings: drei Archiv-Meetings mit beiden Modellen, Transkripte nebeneinander, das
   Ergebnis in §8; Vorgabe erst danach geändert.
7. Phonetik: „Meier"/„Mayer"/„Maier" treffen einen Eintrag, „Beier" nicht;
   englischer Text unberührt.

## 7. Offene Entscheidungen

- **Diktat-Audio behalten** (Stufe 0): ja mit Schalter, aus in der Vorgabe (Vorschlag) —
  oder gar nicht, dann bleibt die Messung auf Referenztexte ohne Audio beschränkt und
  Engines lassen sich nicht gegeneinander stellen.
- **Pre-Roll am Flags-Tap** (Vorschlag) oder dauerhaft offenes Mikrofon (nein) oder gar
  nicht. Der Flags-Tap ist ein Kompromiss mit sichtbarer Nebenwirkung (§5).
- **Nachlauf 250 ms**: erst nach der Messung entscheiden (Vorschlag), oder sofort bauen.
- **Meetings auf Whisper**: erst messen (Vorschlag), oder sofort umstellen, weil die
  Latenz dort ohnehin niemanden interessiert.
- **Reihenfolge zu Spec 32**: Stufe 3 setzt die dortige Messung voraus, die an
  eingeschalteter Apple Intelligence hängt. Bis dahin ruht sie.

## 8. Messwerte

*Noch nicht erhoben.* Hierher gehören: die WER/CER-Tabelle je Engine, die zwanzig
häufigsten Substitutionen mit ihrer Einordnung (Eigenname / Zahl / Wortende /
Modellfehler), die Konfidenzverteilung richtiger gegen falsche Wörter mit der daraus
gewählten Schwelle, Latenz vorher/nachher für Pre-Roll und Nachlauf, und der
Modellvergleich aus Abnahme 6.
