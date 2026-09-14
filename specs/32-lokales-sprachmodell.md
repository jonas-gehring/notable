# Spec 32 — Ein lokales Sprachmodell als Textstufe

> **Aufwand: Stufe 0 = ½ Tag Messung, Stufe 1 = M (3 Tage), Stufe 2 = L.** Das ist die
> einzige Stelle, an der Notable Wispr Flow in der Sache nachholen muss: Selbstkorrektur,
> Satzzeichenreparatur, Listen, Tonfall — bei Wispr ein LLM-Durchlauf in der Cloud, bei
> Notable bewusst nicht vorhanden, weil Diktattext das Gerät nicht verlassen darf. Ein
> Modell, das auf dem Gerät läuft, verlässt es nicht. Der Rechner hat eines, und es ist
> nichts herunterzuladen.
> **Vor Stufe 1 wird gemessen. Ohne Messung wird nichts gebaut.**
> Quelle: `docs/analyse-wispr-flow-paritaet-2026-09-14.md` §4.2.

## 1. Ausgangslage (Fakten aus dem Code und vom Rechner)

- **Die Regel.** `CLAUDE.md`: „Dictation text leaves only on an explicit,
  per-invocation request". `specs/README.md:100-102` zu Spec 04: „Zulässig nur mit
  einem lokalen Modell." Beides sind Regeln über Text, der das Gerät verlässt — nicht
  über Modelle.
- **Der heutige Abruf-Pfad.** `DictationEnhancer.enhance` (`DictationEnhancer.swift:262-286`):
  Provider rein, Text raus, wirft nie, Deadline 15 s, `EnhancementGuard.accept`
  (`:181-196`: Kommentar-Erkennung, Code-Fences, Längenverhältnis 0,4–2,5 ab 12
  Zeichen) — und der Rückfall auf das regelpolierte Original in jedem Fehlerfall. Die
  Profile (`EnhancementProfile`, `:6-70`) sind System-Prompts mit `commonRules`
  (nichts erfinden, Sprache behalten, Namen und Zahlen exakt). Jeder Lauf wird als
  `purpose = "dictation-enhance"` in `llm_usage` gebucht (`UsageRecorder.swift:22`),
  weil die Zeile zählt, **wie oft Text das Gerät verlassen hat**.
- **Der Rechner.** macOS 26.6.2, Xcode 26.6, M2 Pro, 16 GB. Das SDK enthält
  `FoundationModels.framework` mit `SystemLanguageModel`, `LanguageModelSession` und
  `Availability` (`.available` / `.unavailable(.deviceNotEligible |
  .appleIntelligenceNotEnabled | .modelNotReady)`) — verifiziert im
  `.swiftinterface`. Kein Treffer für `FoundationModels`, `MLX` oder `llama` in
  `Sources`. Deployment-Target ist macOS 14.4 (`project.yml:19`).
- **Die Latenz heute.** ~119 ms für 5 s Audio, ~397 ms für 60 s (Transcriber allein,
  `LatencyProbeTests`). Das Ziel „< 200 ms" aus `PLAN.md:56` gilt für kurze Äußerungen.
- **Was die Regeln nicht können** (Spec 31 zieht nach, was sie können):
  Selbstkorrektur („um zwei — nein, um drei"), fehlende Satzzeichen setzen, Tonfall je
  Ziel, Kontext aus dem Umfeld. Alles, was in der Tabelle in
  `docs/analyse-…` §4.1 ein „nein" trägt.

## 2. Ziel

Ein Diktat kann optional durch ein Modell laufen, das auf diesem Mac läuft — und dann
sagt die Kapsel „Formatiere…", ohne den Zusatz „Text verlässt das Gerät", weil es das
nicht tut. Kurze Diktate bleiben so schnell wie heute. Fällt das Modell aus, in
welcher Form auch immer, landet der regelpolierte Text — wie heute bei der
CLI-Verbesserung. Die Datengrenze bleibt exakt, wie sie ist.

## 3. Konzept

### Stufe 0 — Messen

`LocalModelProbeTests` (übersprungen ohne `TEST_RUNNER_NOTABLE_LOCAL_MODEL=1`, wie
`MeetingReplayTests`): zieht die letzten 40 Diktate aus `recordings`
(`raw_text` wo vorhanden, sonst `text`), schickt jedes durch die Stufe-1-Instruktion
und druckt je Diktat: Wörter, Latenz (Prewarm ausgeschlossen, dann eingeschlossen),
Diff Regel-Text → Modell-Text, Sprache vorher/nachher, Zahlen- und Namensmenge
vorher/nachher. Dazu ein handgemachtes Set von 30 Sätzen mit Selbstkorrekturen,
fehlenden Satzzeichen, gesprochenen Listen und Eigennamen.

**Weiter geht es nur, wenn:** Median-Latenz für 60 Wörter unter 1,5 s (Entscheidung
§7 für die Betriebsart hängt an dieser Zahl); keine Sprachwechsel; keine erfundenen
Inhalte im Set (von Hand beurteilt); Zahlen und Namen in ≥ 98 % der Fälle identisch.
Fällt die Messung durch, ist die Rückfalloption MLX Swift mit einem 1,7–4-B-Modell —
eine eigene Spec, weil sie 1–3 GB Download und einen weiteren Fall für Spec 20 bedeutet.

### Stufe 1 — `LocalPolisher`

**3.1 Der Typ.** `Dictation/LocalPolisher.swift`, `@available(macOS 26, *)`. Gleiche
Form wie `DictationEnhancer`: `polish(_ text: String, category: AppCategory) async ->
Result` mit `text`, `didPolish`, `failure`. **Wirft nie.** Deadline 4 s (nicht 15: der
Nutzer wartet hier nicht absichtlich). Session einmal je Prozess mit festen
`instructions`, `prewarm()` beim Start und nach jedem Modellwechsel; jeder Aufruf ein
neuer `respond`, ohne Verlauf — ein Diktat weiß nichts vom vorigen.

**3.2 Verfügbarkeit.** `SystemLanguageModel.default.availability` beim Start und bei
`NSApplication.didBecomeActiveNotification`. Nicht verfügbar ⇒ der Pfad existiert nicht:
kein Aufruf, kein Zustand, die Einstellung zeigt den Grund („Apple Intelligence ist
aus — Systemeinstellungen → Apple Intelligence & Siri") und ist ausgegraut. Unter
macOS 26 zeigt sie „braucht macOS 26". Kein Schalter erscheint, der nichts tut.

**3.3 Guided Generation.**

```swift
@Generable struct PolishedDictation {
    @Guide(description: "Der überarbeitete Text, sonst nichts.")
    var text: String
}
```

Kein Freitext-Parsing, keine Kommentar-Erkennung nötig — die bleibt trotzdem drin,
weil `EnhancementGuard.accept` sie schon hat und sie nichts kostet. Zusätzlich ein
neuer Wächter `NumbersAndNamesPreserved`: die Menge der Ziffernfolgen und der
großgeschriebenen Wörter (ohne Satzanfang) im Ergebnis muss die des Eingangs enthalten;
sonst verworfen. Das ist der Wächter, den die CLI-Verbesserung nie bekam, weil dort
der Nutzer ausdrücklich um Umformulierung bat; hier bittet niemand.

**3.4 Die Instruktion** (eine, fest, je Kategorie ein Zusatz):

- Setze Satzzeichen und Groß-/Kleinschreibung; beende Sätze.
- Führe Selbstkorrekturen aus („nein, ich meine", „beziehungsweise", „Korrektur:",
  „actually", „I mean"): der letzte Stand gilt, die Korrekturphrase fällt weg.
- Entferne Füllwörter, Wiederholungen und Fehlstarts.
- Gesprochene Listen werden Listen mit „- ", nur wenn ≥ 2 Punkte erkennbar sind.
- Behalte Sprache, Wortwahl, Namen, Zahlen, Termine, Fachbegriffe, Zeilenumbrüche.
- Füge nichts hinzu: keine Anrede, keine Grußformel, keine Erklärung.
- Kategorie `chat`: eine bis drei Zeilen, keine Absätze. `mail`: ganze Sätze,
  Absätze. `code`: **das Modell läuft nicht** (verbatim bleibt verbatim).

**3.5 Die Stelle in der Pipeline.** Nach `TextPolisher.polish`, vor der
CLI-Verbesserung und vor dem Paste: Regeln zuerst, weil Wörterbuch, Snippets und
Kommandos deterministisch sind und ein Modell sie nicht rückgängig machen darf. Als
Pipeline-Schritt in `DictationPipeline` (Spec 29): `PipelineEffect.localPolish
(generation:)`, Overlay-Zustand `.formatting` („Formatiere…"), erst nach 300 ms
sichtbar (Spec 30 §3.3). Das Ergebnis wird als `raw_text` (Regel-Text) und `text`
(Modell-Text) gespeichert — dieselben Spalten, die die CLI-Verbesserung benutzt; eine
neue nullable Spalte `recordings.polisher TEXT` („rules" | „local" | „cli") sagt, was
den Text zuletzt geformt hat. Migration 6, nicht rückgefüllt; die Statistik zeigt
„Unbekannt" für alte Zeilen (wie `engine`).

**3.6 Betriebsart.** `DefaultsKey.localPolishMode`: `off` | `long` | `always`.
Vorgabe nach §7. `long` = ab 25 Wörtern; darunter geht der Text direkt zum Paste.
Ein Schalter nach Spec 22 §3.4: beide Stellungen sind für denselben Nutzer vertretbar
(Tempo gegen Qualität), also Einstellung, nicht Konstante.

**3.7 Buchung.** **Keine** Zeile in `llm_usage`: die Tabelle zählt, was das Gerät
verlassen hat und was es gekostet hat, und beides ist hier null. Die Statistik
bekommt stattdessen aus `polisher` eine Verteilung (Regeln / lokal / CLI), gerechnet
in `recompute` wie die anderen Detailkarten.

**3.8 Latenz sagen.** `lastLatencyMillis` bleibt die Transcriber-Latenz (`:650`
stoppt vor der Verbesserung); eine zweite Zahl `lastPolishMillis` wird gespeichert
(`latency_ms` bleibt, neue nullable Spalte `polish_ms` in derselben Migration), damit
die Statistik Median/p95 des Modells getrennt zeigt und niemand die 119 ms mit der
Sekunde des Modells verwechselt.

### Stufe 2 — Was das Modell freischaltet (je eine eigene Spec, hier nur benannt)

Jede der drei folgenden Zeilen liest Fremdtext — Text, den Notable nicht selbst
aufgenommen hat. Die Datengrenze ist unberührt (nichts verlässt das Gerät), aber es ist
das erste Mal, dass Notable in fremden Fenstern liest. Das ist Entscheidung §7, Punkt 2,
und sie fällt **nach** einem Monat Alltag mit Stufe 1.

- **Kontext um den Cursor** (Wispr: „Context Awareness"): per Accessibility
  `kAXValueAttribute`/`kAXSelectedTextRangeAttribute` des fokussierten Elements, ±500
  Zeichen um den Cursor, als Kontext in die Instruktion (Anrede, Sprache des Threads,
  laufende Aufzählung). Nie gespeichert, nie geloggt.
- **Spec 04 mit lokalem Provider.** Der Bauplan liegt (`SelectionAccess`,
  `CommandController`, zweiter Hotkey); `LocalPolisher` ist der Provider.
- **Wörterbuch-Quelle C** (Spec 06 §3.3): Korrektur im Zielfeld erkennen.

## 4. Integration

| Stelle | Änderung |
|---|---|
| `Dictation/LocalPolisher.swift` (neu) | Session, Verfügbarkeit, `polish`, Guided Generation, Deadline |
| `Dictation/LocalPolishGuard.swift` (neu, pur) | `NumbersAndNamesPreserved`, Wortzahl-Schwelle, Betriebsart-Entscheidung — alles testbar ohne Modell |
| `Dictation/DictationPipeline.swift` (Spec 29) | Schritt `localPolish` zwischen `polish` und `enhance`/`paste` |
| `DictationOverlay.swift` | Zustand `.formatting` |
| `SQLiteConnection.swift` | Migration 6: `recordings.polisher TEXT`, `recordings.polish_ms INTEGER`, beide nullable |
| `RecordingStore.saveDictation` | zwei Parameter mehr |
| `DefaultsKey.swift` | `localPolishMode` |
| `DictationSettingsView.swift` | Sektion „Textstufe": Verfügbarkeit, Betriebsart, ein Satz Erklärung |
| `Stats/` | Verteilung Regeln/lokal/CLI; Median/p95 `polish_ms` |
| `Tests/LocalPolishGuardTests.swift` (neu, pur) | Wächter, Schwelle, Betriebsart |
| `Tests/LocalModelProbeTests.swift` (neu, opt-in) | Stufe 0, bleibt als Regressionsmessung |
| `CLAUDE.md`, `specs/README.md` (Datengrenze) | ein Absatz: „Ein lokales Modell verletzt die Grenze nicht; was lokal heißt, steht hier." |

Unter macOS 26 ist der Code ein `#available`-Zweig; unter 14.4–15.x existiert der
Pfad nicht und die Pipeline ist die von Spec 29.

## 5. Risiken

- **Latenz.** Die Regeln liefern 119 ms, das Modell voraussichtlich das Zehnfache.
  Deshalb Stufe 0 vor allem anderen, deshalb `long` als Vorschlag, deshalb das 300-ms-
  Fenster für den Zustand und die 4-s-Deadline. Ein Diktat, das länger wartet als der
  Nutzer, ist schlechter als eines ohne Modell.
- **Qualität eines 3-B-Modells.** Für Satzzeichen, Kasus und Selbstkorrektur
  ausreichend, für Umformulierung nicht — und Umformulierung ist nicht gefragt. Der
  Wächter für Zahlen und Namen ist die Versicherung gegen den einen Fehler, der
  wehtut.
- **Apple Intelligence aus.** Dann gibt es den Pfad nicht, und die Einstellung sagt,
  warum. Nichts fällt still auf Regeln zurück, ohne dass es sichtbar wäre.
- **Speicher.** Das Modell gehört dem System; Notables RSS wächst um die Session,
  nicht um die Gewichte. Wird nach Stufe 1 gemessen und in `CLAUDE.md` unter Runtime
  health nachgetragen.
- **Zwei Modelle in einem Diktat.** Lokal **und** CLI-Verbesserung nacheinander sind
  möglich (zweiter Hotkey nach lokaler Stufe). Bewusst erlaubt: die CLI bekommt dann
  den besseren Text, und die Buchung in `llm_usage` bleibt die der CLI.

## 6. Abnahme

1. Stufe 0 bestanden mit den Zahlen aus §3 Stufe 0, protokolliert in dieser Spec (§8).
2. „Wir treffen uns um zwei, nein um drei" → „Wir treffen uns um drei."; „an Max, ich
   meine an Moritz" → „an Moritz"; ein Text mit fehlenden Punkten bekommt sie.
3. Ein 10-Wort-Diktat in Betriebsart `long`: kein Modellaufruf, Latenz wie heute.
4. Modell verwirft (Zahl fehlt) ⇒ regelpolierter Text eingefügt, Notice sagt es,
   `polisher = "rules"`.
5. Apple Intelligence aus ⇒ Einstellung ausgegraut mit Grund, kein Aufruf.
6. `llm_usage` bekommt keine Zeile; Statistik zeigt die Verteilung.
7. Die Kapsel sagt „Formatiere…" — und nicht „Text verlässt das Gerät".

## 7. Offene Entscheidungen

1. **Betriebsart-Vorgabe:** `long` (Vorschlag), `always` oder `off`. Hängt an der
   Median-Latenz aus Stufe 0: unter 0,8 s wäre `always` vertretbar.
2. **Fremdtext lokal lesen** (Stufe 2): erst nach einem Monat Stufe 1 entscheiden.
3. **Der zweite Hotkey**: bleibt er CLI, oder wird er „lokal, mit Profil"? Dann wäre
   der Consent-Schalter überflüssig — und das ist genau der Grund, es nicht nebenbei
   zu entscheiden.

## 8. Stand der Messung

**Nicht gemessen (2026-09-14): Apple Intelligence ist auf dem Build-Rechner aus.**
`LocalModelProbeTests` lief mit `TEST_RUNNER_NOTABLE_LOCAL_MODEL=1` und hat sich mit
`appleIntelligenceOff` übersprungen, wie vorgesehen. Einschalten ist eine
Systemeinstellung (Systemeinstellungen → Apple Intelligence & Siri, danach lädt macOS
das Modell) und damit Sache des Owners. Danach:

    TEST_RUNNER_NOTABLE_LOCAL_MODEL=1 xcodebuild -project Notable.xcodeproj -scheme Notable \
        -derivedDataPath "$TMPDIR/notable" test -only-testing:NotableTests/LocalModelProbeTests

Die Zeilen `LOCAL_POLISH_PROBE bucket=…` und `accepted=…` gehören hierher.

## 9. Stand des Baus (2026-09-14)

**Abweichung von der eigenen Regel „ohne Messung wird nichts gebaut":** Stufe 1 ist
gebaut, aber **nicht eingeschaltet**. Die Vorgabe der Betriebsart ist `off`, und solange
das Modell nicht verfügbar ist, ist der Picker ausgegraut und der Grund steht darunter.
Auf diesem Rechner läuft also kein einziger Modellaufruf, bis jemand Apple Intelligence
einschaltet *und* die Betriebsart wählt. Gebaut wurde, weil die Messung von einer
Systemeinstellung abhängt und nicht vom Code — und weil der Messtest die fertige Hülle
braucht, um das zu messen, was später tatsächlich läuft.

**Gebaut:**

- `LocalPolish` (pur): Betriebsart `off`/`long`/`always` (Schlüssel `localPolishMode`),
  Schwelle 25 Wörter, nie in `.code`, die feste Instruktion, der Prompt je Kategorie und
  die Prüfung der Antwort.
- `LocalPolisher` (Actor, macOS 26): eine frische Session je Diktat, die nächste wird
  sofort vorgewärmt; 4 s Zeitgrenze; `@Generable PolishedDictation`; wirft nie.
- `LocalModelAvailability` mit Grund für jeden Fall, `LocalPolishSection` in den
  Einstellungen, Zustand „Formatiere…" im HUD (nach 300 ms), Migration 6 mit
  `recordings.polisher` und `recordings.polish_ms`.
- Im Controller: nach den Regeln, vor der CLI-Verbesserung; `enhanced` zählt nur noch
  die CLI, `polisher` sagt, welche Stufe den Text zuletzt geformt hat. Kein Eintrag in
  `llm_usage`.

**Abweichungen:**

1. **Die Prüfung ist umgedreht** (§3.3): nicht „alle Zahlen und Namen der Eingabe
   bleiben", sondern „keine Zahl und kein großgeschriebenes Wort, das nicht in der
   Eingabe stand". Die ursprüngliche Regel hätte jede Selbstkorrektur verworfen — „an
   Max, ich meine an Moritz" löscht Max absichtlich. Was nie passieren darf, ist ein
   erfundener Name oder eine erfundene Zahl; das prüft sie.
2. **Keine Statistik-Karte** (§3.7, §3.8): die Spalten werden geschrieben, die
   Verteilung Regeln/lokal/CLI und Median/p95 von `polish_ms` sind noch nicht in
   `Stats/`. Ohne Messwerte gäbe es darin nichts zu sehen.
3. **Stufe 2** (Kontext, Spec 04 lokal, Wörterbuch-Quelle C) ist nicht angefasst — wie
   vorgesehen erst nach einem Monat Stufe 1.
4. `CLAUDE.md` bekam den Absatz zur Datengrenze nicht, weil dort unkommittierte
   Änderungen des Owners liegen; er steht in `specs/README.md`.

**Tests:** `LocalPolishTests` 14 (neu, ohne Modell), `LocalModelProbeTests` 1 (opt-in,
übersprungen). **Nicht verifiziert:** alles in §6, was ein laufendes Modell braucht (2–7).
