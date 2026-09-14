# Analyse — Was Notable von Wispr Flow trennt, und was davon Local-First erlaubt

Stand: `main` bei `8d92a93` (Release v1.2.0), 2026-09-14. Rund 24 600 Zeilen Swift,
697 Testmethoden. Maßstab ist Wispr Flow im September 2026 (Quellen im Anhang).

Vorgehen: vier unabhängige Durchgänge — Diktat-Kernpfad vollständig gelesen,
Oberfläche und Einstellungen vollständig gelesen, Specs und Code-Review vom 3. September
gegen den heutigen Code abgeglichen, Wispr Flow aus Herstellerdoku, Changelog und
Rezensionen inventarisiert. Jeder Befund, der hier eine Zeile bekommt, wurde am Code
verifiziert; Vermutungen sind als solche markiert. Die Festlegungen aus `CLAUDE.md`
(Audio verlässt das Gerät nie, Diktattext nur auf Abruf, kein Cloud-ASR) werden nicht in
Frage gestellt — sie sind die Randbedingung, unter der jede Empfehlung hier steht.

---

## 0. Kurzfassung

**Die Lücke liegt nicht in der Erkennung.** Parakeet v3 auf der Neural Engine liefert
5 s Audio in ~119 ms; Wispr Flow nimmt ebenfalls den ganzen Clip auf und transkribiert
erst nach dem Loslassen, nur eben in der Cloud. Was Wispr besser macht, sind drei Dinge,
und keines davon ist ein Modell:

1. **Die Kernschleife fühlt sich nie kaputt an.** Bei Notable gibt es fünf verifizierte
   Stellen, an denen ein normaler Ablauf still ins Leere läuft: der Hotkey während der
   Transkription wird verworfen, ein leeres Transkript verschwindet ohne Meldung, Esc
   greift nach dem Loslassen nicht mehr, das Ziel wird vor dem Einfügen nicht erneut
   geprüft, ein Gerätewechsel bricht ab statt weiterzunehmen. Jede davon ist klein.
   Zusammen sind sie das „buggy".
2. **Wispr hat eine Textintelligenz, Notable hat Regeln.** Selbstkorrektur („um zwei —
   nein, um drei"), Tonfall je Ziel-App, Kontext aus dem Text um den Cursor, Befehle auf
   markiertem Text: alles ein LLM-Durchlauf, alles Cloud. Notables automatischer Polish
   ist bewusst offline und regelbasiert, und Regeln kommen dort nicht hin. **Der Weg,
   der Local-First nicht verletzt, ist ein lokales Modell** — und der Rechner hat eines:
   macOS 26.6 mit dem FoundationModels-Framework, im SDK vorhanden, nichts herunterzuladen.
   Damit wird nicht nur der Polish besser; es fällt auch die Sperre von Spec 04
   (Voice-Commands) und die Sperre vor Kontextlesen, denn beide waren Datengrenzen, keine
   Funktionsgrenzen.
3. **Craft.** Das HUD springt ohne Übergang auf und weg und hat zwei unverwandte
   Erscheinungsbilder; ~50 Einstellungs-Controls, davon ein Teil Messinstrumente; rohe
   `localizedDescription` als Standard-Fehlerfläche an 13 Stellen; kein Ton in der
   Vorgabe; vier Lokalisierungslecks, eines davon der Hauptknopf der Consent-Mitteilung.

Wispr hat auch, was Notable nicht will: Cloud-ASR ohne Offline-Modus, einen
Datenschutzvorfall (Bildschirmfotos an Drittanbieter, Ende 2025), 75+ Ausfälle in sechs
Monaten laut StatusGator, 2,7 von 5 auf Trustpilot. Local-First ist hier kein Handicap,
das es zu kompensieren gilt, sondern die Position. Was fehlt, ist die Verlässlichkeit
und die Politur, die man von einer Position erwartet.

**Empfohlene Reihenfolge:** Kernschleife härten (S–M, sofort spürbar) → HUD und
Fehlerfläche (S–M) → lokales Sprachmodell als optionale Textstufe (M, die eigentliche
Paritätsfrage) → Einstellungen-Diät (M) → Kontextbewusstsein und Spec 04 auf lokalem Weg
(L, erst wenn das Modell sich bewährt hat). Details in §7.

---

## 1. Der Maßstab: Wispr Flow, September 2026

Nur was für den Vergleich zählt. Belege im Anhang.

| Bereich | Wispr Flow | Bemerkung |
|---|---|---|
| Aktivierung | Taste halten (Standard `fn`), Doppeldruck = freihändig, Dreifachdruck verwirft | Notable: halten / kurzer Tap / nächster Tap |
| Ablauf | **Ganzclip nach dem Loslassen**, kein Live-Text; max. ~6 min | identisch zu Notable |
| Erkennung | **ausschließlich Cloud**, kein Offline-Modus | die Architekturgrenze |
| Textstufe | LLM: Zeichensetzung, Füllwörter, **Selbstkorrektur**, Listen, Tonfall („Styles", nur Englisch) | Notable: Regeln, offline |
| Kontext | liest Text um den Cursor, bucketet die App (E-Mail / Arbeit / Privat / Sonstiges) | Notable: 20 Bundle-IDs, kein Browser |
| Wörterbuch | automatisch ergänzt, wenn man das eingefügte Wort korrigiert; Sync über Geräte | Notable: Korrektur in „Letzte Diktate" → Vorschlag → manuell übernehmen |
| Snippets | ja, seit 07/2026 mit Formatierung | Notable: `SmartReplace`, mehrzeilig, gleichwertig |
| Command Mode | markierten Text per Sprache umschreiben (Pro) | Notable: Spec 04, zurückgestellt (Datengrenze) |
| Code | camelCase/snake_case, Symbole in VS Code/Cursor/Windsurf | Notable: `.code` = verbatim, drei Editoren in der Tabelle |
| Sprachen | 100+, Auswahl mehrerer; Auto-Erkennung nur Android | Notable: de/en-Profil, Parakeet v3 mehrsprachig |
| HUD | „Flow Bar": Blase, an unteren/linken/rechten Rand schnappend, Position bleibt; pulsierende Wellenform; Abbrechen/Stopp klickbar | Notable: unten / Notch / aus; nicht klickbar; Spec 28 ergänzt rechts |
| Ton | Ping beim Start, standardmäßig an | Notable: zwei Systemtöne, **standardmäßig aus** |
| Fehler | Toast mit Wiederholen, Zwischenablage-Fallback, **fehlgeschlagene Diktate orange in der Historie, dort wiederholbar** | Notable: 3 s schwarze Kapsel, Audio danach weg |
| Historie | Hub-Seite, Suche, Kopieren/Wiederholen/Löschen | Notable: Fenster + Menü, Kopieren, Korrigieren |
| Meetings | „Notetaker" (Beta, Mac, seit 08/2026): Systemaudio ohne Beitritt, Live-Transkript, Summary, Kalender | Notable hat das seit v1 — mit Diarisierung, lokal |
| Plattformen | macOS, Windows, iOS, Android; Wörterbuch-Sync | Notable: macOS |
| Datenschutz | „Privacy Mode" = Aufbewahrungsschalter, kein lokaler Modus; Vorfall 2025 | Notable: Architektur |
| Preis | 15 $/Monat Pro; 2 000 Wörter/Woche frei | — |
| Ressourcen (Rezensionen) | ~800 MB RSS, ~8 % CPU im Leerlauf berichtet | Notable gemessen: 28 MB, 0,0 % |

Was daraus folgt: **Notable ist bei Erkennung, Latenz, Ressourcen, Meetings und
Datenschutz gleichauf oder voraus.** Zurück liegt es in der Textstufe, im Kontext, in der
Fehler- und Historien-Erfahrung und in der Politur. Genau das ist die Reihenfolge der
folgenden Kapitel.

---

## 2. Was Notable heute tatsächlich tut — und was die Doku sagt

Der laufende Pfad, verifiziert (`DictationController.swift:554-704`):

Loslassen → `recorder.stop()` → Mindestdauer 0,3 s → `overlay.show(.transcribing)` →
**ein** Ganzclip-Durchlauf `rawTranscript` (`:625`) → `TextPolisher.polish` abseits des
Main-Actors (`:635`) → Leer-Guard (`:639`) → Latenzuhr gestoppt (`:650`) → optional
`DictationEnhancer` nur mit zweitem Hotkey (`:662`) → `Paster.insert` (`:688`) → Ton,
Speichern, Historie.

Der Unified-„Streaming"-Pfad bekommt den fertigen Clip in einem `feed` (`:771-774`).
`IncrementalDictation`, `ParakeetTranscriber.makeSession`, `AudioRecorder.snapshot()`
und `overlay.updatePartial` haben **keinen Produktionsaufrufer** — nur Tests.

**Drei Dokumente, zwei Aussagen.** `CLAUDE.md:21` sagt es richtig („reached from no
production path"). `specs/README.md:17` führt Spec 05 als „gebaut". `README.md:21-22`
verspricht: „Long dictations decode incrementally while you speak". Das Zweite und
Dritte sind falsch. Der Review vom 3. September (Punkt 3.6) verlangte „verdrahten oder
löschen und die Doku richtigstellen"; passiert ist: `CLAUDE.md` korrigiert, Code und die
beiden anderen Dokumente nicht. Vier Tests (`IncrementalDictationTests`,
`IncrementalQualityTests`) bewachen toten Code. Das ist kein Nutzer-Bug, aber es ist der
Grund, warum eine Analyse wie diese den Code lesen muss statt der Doku zu glauben — und
es gehört in die Liste der offenen Entscheidungen (§9), wo es bisher fehlt.

**Vom Review vom 3. September** sind im Diktatpfad 16 von 20 Punkten behoben, im
Oberflächenteil 13 von 20 ganz und 6 teilweise. Offen geblieben sind genau die, die das
Gefühl prägen: 3.6 (Live-Text), 3.8 (freihändiger Stopp fügt ein, während der Modifier
noch physisch gedrückt sein kann — `PTTStateMachine.swift:35-39` beendet auf keyDown,
`Paster.swift:160` postet ⌘V ungeprüft), 3.19 (`DictationController` inzwischen 782
Zeilen, `finishRecording` ohne Testnaht — es gibt keine `DictationControllerTests`,
keine für `HotkeyMonitor`, `AudioRecorder`, `Paster.paste`), 7.18 (62 feste
Punktgrößen), 7.4 (die irreführenden Menü-Shortcuts sind weg, der globale Shortcut für
„Letztes Diktat einfügen" kam nicht).

---

## 3. Befunde A — die Kernschleife

Das sind die Stellen, an denen Notable im Alltag „buggy" wirkt. Alle verifiziert.

| # | Befund | Was der Nutzer erlebt | Stelle | Aufwand |
|---|---|---|---|---|
| A1 | **Hotkey während `.transcribing` wird still verworfen.** `beginRecording` prüft `.idle`, setzt die PTT-Maschine zurück, kein Overlay, kein Ton. | Zweites Diktat direkt nach dem ersten: nichts passiert. Bei Verbesserung (bis 15 s) minutenlang „tot". Der häufigste „kaputt"-Moment gegenüber Wispr. | `DictationController.swift:421` | S: nächste Aufnahme **anstellen** (Audio puffern, nach dem Paste transkribieren) oder mindestens Kapsel + Ton „gleich" |
| A2 | **Leeres Transkript verschwindet ohne Meldung.** `guard !trimmed.isEmpty else { overlay.hide() }`. Das ist auch, wie ein verweigertes Mikrofon aussieht: `beginRecording` prüft die TCC-Berechtigung nie, ein verweigertes Gerät liefert Nullen. | „Taste gedrückt, gesprochen, nichts" — für immer, ohne Hinweis. | `:639`, `:427-443` | S: Kapsel „Nichts verstanden" + Ton; Pegel-Peak der Aufnahme prüfen und bei 0,0 die Ursache nennen — `TrackSilence`/`SilenceDiagnosis` existieren für Meetings schon |
| A3 | **Esc nach dem Loslassen ist tot.** `isRecordingActive` = `captureState == .recording`; während `.transcribing`/`.enhancing` wird Esc weder geschluckt noch verarbeitet. Der `.transcribing`-Zweig von `cancelRecording` (`:509-518`) ist **unerreichbar**; die Kommentare `:504-508` und `:564-566` beschreiben Verhalten, das nicht stattfindet. | Eine 15–60 s Verbesserung lässt sich nicht abbrechen; Esc geht an die fokussierte App. | `HotkeyMonitor.swift:193` vs. `DictationController.swift:124` | S (eine Zeile) |
| A4 | **Ziel wird vor dem Einfügen nicht erneut geprüft; Erfolg nie verifiziert.** `targetBundleID` wird beim Loslassen eingefroren, aber nur für Profil und Statistik benutzt. ⌘Tab während der Transkription pastet in die falsche App. Nichts prüft, ob ⌘V ankam; die Zwischenablage wird nach 600 ms zurückgesetzt — der Text ist dann auch dort weg. | Text landet im falschen Fenster oder nirgends, ohne Spur. | `:559`, `:688`, `Paster.swift:137` | S–M: frontmost vor Paste vergleichen, bei Abweichung in die Zwischenablage + Notice; nach Paste `changeCount` beobachten |
| A5 | **Gerätewechsel bricht ab statt weiterzunehmen.** `onConfigurationChange` cancelt und meldet „Aufnahme abgebrochen", obwohl `AudioRecorder.resume(device:)` existiert und für Meetings genau das Richtige tut. | AirPods verbinden mitten im Satz = Diktat weg, Audio verworfen. | `:131` vs. `MeetingController.swift:464` | S |
| A6 | **Consent-Überraschung bei zwei Hotkeys.** `enhanceRequested` wird beim keyDown gesetzt; ein freihändiges Diktat wird durch **jeden** keyDown beendet. Plain-Diktat mit der Verbessern-Taste beenden ⇒ Text verlässt das Gerät; umgekehrt fällt die Verbesserung still weg. | Datengrenze wird durch einen Tippfehler überschritten. | `:112`, `PTTStateMachine.swift:35` | S: Stopp-Taste ignorieren, Rolle vom Start behalten |
| A7 | **Kein Secure-Input-Bewusstsein.** Null Treffer für `SecureEventInput`. Bei aktivem Passwortfeld erreicht der Flags-Tap nichts, ⌘V wird nicht zugestellt. | Hotkey „geht plötzlich nicht", ohne Erklärung. | — | S: `IsSecureEventInputEnabled()` beim keyDown, Kapsel „Sicheres Eingabefeld aktiv" |
| A8 | **Kein Feedback in der Vorgabe.** Zwei Systemtöne, beide hinter `dictationSounds` mit Fallback `false`. Kein Ton bei Abbruch, Fehler, Lock, zu kurz. | Vier häufige Ausgänge ohne jedes Signal. | `DefaultsKey.swift:51`, `DictationController.swift:458, 689` | S: Vorgabe an, eigene kurze Töne für Start/Ende/Abbruch/Fehler |
| A9 | **Diktat-Audio ist RAM-only und bei jedem Fehler verloren.** Kein Spool wie bei Meetings, kein „Wiederholen" in der Historie. | Wispr zeigt fehlgeschlagene Diktate orange und lässt sie wiederholen. | `:764-777` | S–M: letzten Clip als `.i16` im Spool behalten bis zum nächsten Diktat; Historie-Eintrag „fehlgeschlagen — wiederholen" |
| A10 | **Freihändig-Lock aus Versehen.** Halten 0,30–0,35 s = Lock; Idle-Timeout Vorgabe 0 (aus); Abbruch nur nach 10 min (Timer-Ticks, nicht Wanduhr). | Ein schnelles „ja, mach das" lässt das Mikrofon offen. | `PTTStateMachine.swift:22`, `DictationController.swift:67-70, 482` | S: Lock erst ab deutlichem Tap (< 0,2 s), Idle-Timeout Vorgabe 30 s mit Hysterese |
| A11 | **Key-Down-Pfad läuft im Event-Tap-Callback.** CoreAudio-Enumeration, IORegistry-Lid-Abfrage, `AVAudioEngine.start()`, `CGEvent.tapCreate`, erster `NSHostingView`-Aufbau — alles synchron im Tap. macOS deaktiviert Taps, die hängen; der Code re-aktiviert bei `tapDisabledByTimeout` (`HotkeyMonitor.swift:93, 189`), was liest, als sei es schon vorgekommen. Ohne Pre-Roll fehlen die ersten ~50–100 ms Audio (Review §3, offen). | Erste Silbe abgeschnitten; gelegentlich „Hotkey reagiert nicht". | `HotkeyMonitor.swift:57`, `DictationController.swift:427-456` | M: Engine warm halten oder Ring vorlaufen lassen; Policy-Abfrage cachen |
| A12 | **Kein Schlaf/Wach-Handler für Diktat**, nur für Meetings. | Lock über einen Schlaf sammelt stumme Zeit oder stirbt. | `MeetingController.swift:151` | S |

Dazu die **Testnaht** (Review 3.19, offen): keiner dieser zwölf Punkte hat heute einen
Test, weil `finishRecording` keinen haben kann. Wer A1–A5 anfasst, sollte den Pfad
dabei in ein pures `DictationPipeline`-Stück (Entscheidungen) und eine dünne Hülle
(AppKit/CoreAudio) trennen — sonst kommt die nächste Version dieser Liste in drei Monaten.

---

## 4. Befunde B — Textintelligenz

### 4.1 Was die Regeln heute tun und nicht tun

`TextPolisher.polish` (`TextPolisher.swift:85`), in Reihenfolge: Spracherkennung auf dem
Rohtext (ein Urteil pro Clip) → Füllwörter (universell: ähm/äh/mhm/hmm; englisch nur bei
erkanntem Englisch: um/uh/er…) → ITN **nur englisch** → SmartReplace → Wörterbuch exakt +
unscharf → `tidy` → Schlusspunkt (Mail) → `ParagraphFormatter`.

Was fehlt, geordnet nach dem, was ein Nutzer täglich merkt:

| Lücke | Regelbasiert machbar? | Aufwand |
|---|---|---|
| **Keine Großschreibung nach Satzende.** Nur das erste Wort des Texts und das erste eines gesprochenen Blocks werden angefasst; alles andere kommt vom ASR. Fällt ein Punkt weg, läuft der Text durch. | ja — Satzgrenzen aus `NLTokenizer` hat der Formatter schon | S |
| **Deutsche Zahlen, Daten, Uhrzeiten bleiben ausgeschrieben** („zweiundzwanzig Euro", „dritter März", „halb drei"). `EnglishITN` ist eine echte, konservative Implementierung; eine deutsche gibt es nicht. | ja, konservativ wie die englische | M |
| **Füllwörter-Liste ist dünn.** Kein „also", „halt", „sozusagen", „quasi", „irgendwie" (deutsch), kein „like", „you know", „I mean", „sort of" (englisch). Wiederholungen („ich ich habe") und Fehlstarts werden nie berührt. | Wiederholungen ja; Fehlstarts nur teilweise | S |
| **Selbstkorrektur** („um zwei — nein, um drei"; „an Max, ich meine an Moritz") | nein, verlässlich nur mit Modell | — |
| **Absätze an Sprechpausen.** Heute: Satz*zahl*, weil „kein Engine Wortzeiten liefert" (`specs/README.md:112`). **Das stimmt nicht mehr:** FluidAudios `ASRResult` trägt `tokenTimings: [TokenTiming]?` mit `startTime`/`endTime`/`confidence` (`AsrTypes.swift:142`, verifiziert im Checkout unter `build/SourcePackages`; der Checkout unter `$TMPDIR/notable` enthält derzeit nur leere Verzeichnisse). Notable liest das Feld nirgends. | ja — das Feld kommt beim Ganzclip-Aufruf ohnehin mit, keine Protokolländerung im Kernpfad | S–M |
| **Tonfall je Ziel** (Slack knapp, Mail förmlich) | nein | — |
| **Kontext aus dem Text um den Cursor** (Anrede, Sprache des Threads, laufende Liste) | nein | — |
| **App-Tabelle:** 20 Bundle-IDs, **kein Browser**, kein Notion/Linear/Teams/Zoom, kein Cursor/Zed/Ghostty/Warp. `overrides:` existiert und wird nie befüllt; Spec 03 §5 (Tabelle + App-Picker) ist ungebaut. In der Praxis bekommt fast jedes Diktat `.unknown`. | ja | S (Tabelle) + S (Picker) |
| **Wörterbuch-Auto-Learn** nur über den Korrektur-Dialog in „Letzte Diktate". Wispr liest die Korrektur aus dem eingefügten Text der Ziel-App. | AX-Lesen des Zielfelds ist Fremdtext — mit lokaler Verarbeitung *zulässig*, weil nichts das Gerät verlässt; trotzdem ein eigener Beschluss (§9) | M |

Die ersten drei Zeilen und die App-Tabelle sind eine Woche Arbeit und holen einen
spürbaren Teil des Alltagsgefühls — ohne Modell, ohne neue Entscheidung.

### 4.2 Die Paritätsfrage: ein lokales Sprachmodell

Alles, was in der Tabelle „nein" trägt, ist bei Wispr ein LLM-Durchlauf. Notables
Regel dazu (`CLAUDE.md`, „Dictation text leaves only on request") ist eine Regel über
**Text, der das Gerät verlässt**. Ein Modell, das auf dem Gerät läuft, verletzt sie nicht
— `specs/README.md:100-102` sagt das für Spec 04 ausdrücklich: „Zulässig nur mit einem
lokalen Modell."

**Was auf diesem Rechner verfügbar ist** (gemessen: macOS 26.6.2, Xcode 26.6, M2 Pro,
16 GB; kein Treffer für `FoundationModels`, `MLX` oder `llama` im Code):

| Option | Was es ist | Für | Gegen |
|---|---|---|---|
| **Apple FoundationModels** (`SystemLanguageModel`, `LanguageModelSession`) | On-Device-Modell von Apple Intelligence, ~3 B Parameter, im SDK vorhanden, kein Download, Deutsch unterstützt; `Availability` meldet `deviceNotEligible` / `appleIntelligenceNotEnabled` / `modelNotReady` | nichts zu bündeln, nichts zu verwalten, Speicher trägt das System, Guided Generation (`@Generable`) gibt typisierte Antworten statt Freitext-Parsing | macOS 26+ (Deployment-Target ist 14.4 ⇒ `#available`-Pfad, darunter bleibt es bei Regeln); Kontext 4 096 Token; Qualität eines 3-B-Modells — für Formatieren und Selbstkorrektur ausreichend, für freies Umschreiben grenzwertig; setzt eingeschaltete Apple Intelligence voraus |
| MLX Swift / llama.cpp mit Qwen3 1,7–4 B oder Gemma 3n | eigenes Modell im Prozess | Wahl des Modells, läuft ab macOS 14, kein Apple-Intelligence-Zwang | 1–3 GB Download (neben 1,1 GB ASR), Speicherdruck bei 16 GB, ein weiterer Modellverwaltungs-Fall (Spec 20 ist noch nicht zu Ende) |
| Ollama als Prozess | wie heute die CLIs, nur lokal | schon als „someday" in `CLAUDE.md` | Fremdprozess, Installation durch den Nutzer; für einen Diktat-Kernpfad zu viel Beweglichkeit |

**Empfehlung:** FoundationModels als **erste** Textstufe mit Modell, hinter
`#available(macOS 26, *)` und `availability == .available`; alles andere bleibt exakt
der heutige Regelpfad. Kein Download, kein neuer Speicherposten, nichts, was Spec 20
weiter aufbläht. MLX bleibt die Rückfalloption, falls die Qualität nicht reicht — das
Protokoll (`Prompt rein, Text raus, nie werfen`) ist dasselbe wie bei
`DictationEnhancer`, der schon jeden Fehlerfall auf das regelpolierte Original zurückfällt.

**Die Latenzfrage ist die eigentliche Entscheidung.** Heute: ~119 ms. Ein
3-B-Modell für ein 60-Wort-Diktat: geschätzt 1–3 s auf diesem Rechner — **zu messen,
bevor irgendetwas gebaut wird**, mit demselben Harness wie `LatencyProbeTests`. Wispr
liegt insgesamt bei etwa einer Sekunde. Drei Betriebsarten sind vertretbar, und die
Wahl gehört dem Owner (§9):

- **Nur lang:** Modell erst ab ~25 Wörtern. Kurze Antworten bleiben sofort; wo
  Formatierung zählt, ist die relative Wartezeit klein. (Vorschlag.)
- **Immer:** einfachste Erklärung, kostet bei jedem „ja, passt" eine Sekunde.
- **Nie automatisch:** wie heute, das Modell nur hinter dem zweiten Hotkey — dann aber
  lokal statt CLI, was den zweiten Hotkey vom Consent-Thema befreit.

Nach Spec 22 §3.4 rechtfertigt sich ein Schalter nur, wenn beide Stellungen für
denselben Nutzer vertretbar sind. Hier sind sie es: Tempo gegen Qualität.

**Was das Modell freischaltet, sobald es da ist**, jeweils ohne dass ein Zeichen das
Gerät verlässt:

1. **Selbstkorrektur, Satzzeichen-Reparatur, Listen** — der Kern von Wispr Flows Gefühl.
2. **Tonfall je `AppCategory`** — heute schaltet die Kategorie nur Regeln um.
3. **Kontext um den Cursor** (per Accessibility, wie Wispr): Anrede, Sprache, laufende
   Aufzählung. Fremdtext, aber lokal — ein eigener Beschluss, weil es das erste Mal
   wäre, dass Notable liest, was in fremden Fenstern steht.
4. **Spec 04 (Voice-Commands auf markiertem Text)** — der Bauplan liegt fertig da
   (`SelectionAccess`, `CommandController`, zweiter Hotkey); nur der Provider-Aufruf
   war das Problem.
5. **Wörterbuch-Auto-Learn aus der Ziel-App** (Spec 06, Quelle C) — dieselbe Frage wie 3.

Die Datengrenze bleibt in jeder dieser fünf Zeilen exakt, wie sie ist. Was sich ändert,
ist, dass die Grenze nicht mehr das Argument gegen die Funktion ist.

### 4.3 Live-Text (Spec 05)

Wispr Flow zeigt **keinen** Live-Text. Das relativiert Spec 05 Modus 1 als
Paritätsthema: es ist ein Notable-eigener Vorsprung, kein Rückstand. Modus 2 (inkrementell
final) war der Latenzgewinn bei 60 s (397 → deutlich weniger), und 60-s-Diktate sind
selten. Vorschlag: Modus 1 bauen, wenn das HUD ohnehin angefasst wird (§5.1), oder den
toten Code samt vier Tests **löschen** und `README`/`specs/README` richtigstellen.
Beides ist besser als der heutige Zustand. Entscheidung in §9.

---

## 5. Befunde C — Oberfläche und Craft

### 5.1 Das HUD

- **Kein Ein-/Ausblenden.** `orderFrontRegardless()` und `orderOut(nil)`
  (`DictationOverlay.swift:73, 122`) — die Kapsel springt. Wispr skaliert und blendet.
  Das ist das einzelne Detail, das am stärksten „unfertig" liest. S.
- **Zwei Erscheinungsbilder.** Unten: feste schwarze Kapsel mit weißem Text
  (`:248-252`), passt sich nicht an. Notch: `.regularMaterial` + `.primary`
  (`:396, 412`), passt sich an. Dasselbe HUD, je nach Picker eine andere Identität;
  keines nutzt `Theme`. S.
- **Wellenform mit 10 Hz** gefüttert, 0,12 s Ease-Out gegen ein 60/120-Hz-Display: die
  Balken stufen. `reduceMotion` als `static let` einmalig gelesen (`:226, :330`). S.
- **Spinner für 120 ms.** `.transcribing` zeigt `ProgressView` + „Transkribiere…" auch
  bei einem Diktat, das in 119 ms fertig ist — sichtbares Flackern für nichts. Erst ab
  ~300 ms anzeigen. S.
- **Fehler:** rohe `localizedDescription`, zwei Zeilen, drei Sekunden, dann weg; keine
  Historie, kein erneutes Lesen. Wispr: Toast mit „Wiederholen" und orange in der
  Historie. Siehe A9. S–M.
- **Nicht klickbar** (`ignoresMouseEvents`, `:156`), Abbruch nur per Esc, und Esc nur
  mit Bedienungshilfe-Recht; fehlt es, verschwindet der Hinweis und es gibt **keine**
  Abbruch-Affordanz. Wispr: Abbrechen/Stopp in der Bar. Ein klickbarer Abbruch-Knopf
  verlangt, dass das Panel Mausereignisse annimmt, ohne key zu werden —
  `NSPanel.nonactivatingPanel` kann das; der Test „nie key" bleibt der Wächter. M.
- Spec 28 (rechts am Rand) ist in Arbeit; damit sind Wispr's drei Kanten abgedeckt.

### 5.2 Einstellungen

Sieben Seiten, gezählt **~29 Toggles, 18 Picker, 3 Stepper/Slider**, zwei editierbare
Tabellen, ein 40-Zellen-Icon-Raster, vier destruktive Flüsse. Die Diktat-Seite allein
hat 8 Abschnitte, 10 Toggles, 8 Picker, einen Slider, einen Stepper, zwei Tabellen, eine
Latenzanzeige und eine eingebettete Kopie der Diktat-Historie. Wispr Flow hat eine
Handvoll Schalter.

Was davon Entwicklerwerkzeug ist und nicht Produkt:

1. **„Call-Fenster jetzt auslesen"** (`MeetingsSettingsView.swift:86-103`): eine
   Sektion für eine Funktion, deren Adapterliste leer ist („Unterstützte Apps: noch
   keine — erst messen"), mit einem Knopf, der einen AX-Baum in ein Log-Verzeichnis
   schreibt, dessen Pfad im Footer steht. Das ist Spec 24 Stufe 0 — ein Messgerät.
   Gehört hinter einen Debug-Schalter oder in ein Skript.
2. **Rohes CLI-Argument-Feld** (`CLIProviderStatusRow.swift:40-57`), monospaced,
   „Anführungszeichen gruppieren, wie in der Shell". Existiert, weil zwei von drei
   CLI-Aufrufen nie verifiziert wurden. Ehrlich, aber ein Terminal in den Einstellungen.
3. **Latenz-Telemetrie** als Einstellungszeile und als Median/p95-Karte in der
   Statistik.
4. **Modellinventar** mit „unvollständig", „verwaist" und einem Footer über
   umbenannte Bibliotheksverzeichnisse.
5. **VPIO** als Nutzerbegriff mit Postmortem-Footer („war die Ursache leerer
   Transkripte").
6. **„Beim ersten Start ein kleines Modell vorschalten"**, **„Einfügemethode"**,
   **„ASR-Engine: Parakeet v3 / Unified / Whisper (OpenAI)"**, **„Modell:
   claude-sonnet-5."** — Mechanik und Herstellernamen als Produktvokabular.
7. **Footer in Changelog-Stimme**: mehrere Absätze erklären, *warum der Code so ist*
   („weil zwei davon lange keiner genannt hat", `StorageSettingsView.swift:52-55`).
   Das ist das Muster, das Spec 22 abstellen wollte und das die Specs 20–27 wieder
   hineingetragen haben: die Begründung gehört in die Spec, der Footer sagt, was der
   Schalter tut. Einen Satz.

Dazu die Inkonsistenzen: vier Abschnitte der Diktat-Seite ohne Überschrift, Überschriften
mal Nomen mal Satz, destruktive Aktionen in drei verschiedenen Button-Stilen, ein
einziger `.radioGroup`-Picker in der ganzen App, vier Einstellungen ohne jede Erklärung.

**Empfehlung:** eine Diät-Spec mit drei Regeln — (a) Messinstrumente hinter einen
`⌥`-Klick oder in Skripte, (b) jeder Footer ein Satz über die Wirkung, (c) Vorgaben, die
ein Nutzer nicht ändern will, sind keine Einstellungen (Einfügemethode, Bootstrap,
Idle-Timeout-Zahl, VPIO). Ziel: Diktat-Seite mit ≤ 6 Schaltern über dem Falz. M.

### 5.3 Fehlerfläche, Feedback, Leerzustände

- **Rohe `localizedDescription`** erreicht den Nutzer an ~13 Stellen direkt und an
  ~13 weiteren hinter einem deutschen Präfix; drei davon setzen interne Verzeichnis- oder
  Spurnamen zusammen („spool-xyz/mic: …"). Ein `UserFacingError`-Mapping mit drei Sätzen
  pro Fehlerklasse (was, warum, was tun) an einer Stelle. S–M.
- **Töne aus in der Vorgabe** (A8). Keine Haptik (null Treffer). Wispr: Ping an.
- **Drei Leerzustands-Sprachen**: `ContentUnavailableView`, eigene Karte, sieben
  ad-hoc `Text("Noch keine …")`. `RecentDictationsView.swift:57` benutzt
  `ContentUnavailableView` als Ladeanzeige. S.
- **Download-Fortschritt** viermal anders formuliert, nur einmal als Balken. S.
- `try? await history.paste(...)` im Menü-Untermenü schluckt den Fehler
  (`NotableApp.swift:640`), während der Geschwister-Eintrag ihn meldet. S.

### 5.4 Visuelles System

`Theme.swift` deckt die Statistik gut ab und sonst nichts konsistent: **62 feste
Punktgrößen** gegen 72 semantische Fonts, getrennt nach Datei (Stats, Onboarding,
LiveNotes, Chat, HUD fest; Settings, Notes, Search semantisch); **neun Eckenradien**
gegen drei Tokens; kein Abstands-, kein Typo-, kein Schatten-, kein Dauer-Token;
`Theme.textEmphasis == Theme.textDefault`; ein eigenes `CalSegmented` neben einem
System-`.segmented` für dieselbe Aufgabe. Das App-Icon ist ein `.icns` mit einer
Auflösung, kein Asset-Katalog, keine Dark-/Tinted-Variante für macOS 26. Kein
`setFrameAutosaveName` — jedes Fenster öffnet an der SwiftUI-Vorgabeposition.

Das ist keine Bug-Liste, sondern der Grund, warum die App „aus zwei Händen" aussieht.
Ein Tag für Tokens (Abstand 4/8/12/16/24, Typo-Rollen, drei Radien konsequent) und ein
Tag für die Migration der festen Größen. S–M.

### 5.5 Lokalisierung und Tastatur

Vier verifizierte Lecks, die `LocalizationTests` nicht sehen kann (alle das
„plain `String`"-Muster aus `CLAUDE.md`):

1. `NotificationCenterService.swift:69, 81` — `UNNotificationAction(title: "Aufnehmen")`.
   **Der Hauptknopf der Consent-Mitteilung ist im englischen UI deutsch.** Der Schlüssel
   existiert in `en.lproj` und wird nie nachgeschlagen.
2. `NoteListView.swift:89` — `Text(note.title ?? "Ohne Titel")`, `String?` ⇒ verbatim,
   nicht in `en.lproj`.
3. `RecentDictationsList.swift:76` — `Text(text.isEmpty ? "(kein Text)" : text)`,
   nicht in `en.lproj`.
4. `MeetingChat.swift:136` — gleicher Mechanismus, zufällig sprachneutral.

Tastatur: 16 `keyboardShortcut` in der ganzen App; kein `@FocusState`; kein
Hauptmenü (`LSUIElement` ohne `.commands`), also kein Über-Fenster, kein Hilfe-Menü —
und **ob ⌘C/⌘V/⌘Z in den Textfeldern der App funktionieren, ist ungeprüft** (das ist ein
Handtest, kein Grep). `MeetingsSettingsView.swift:130` dokumentiert ein ⇧⌘N, das nirgends
registriert ist. Der globale Shortcut für „Letztes Diktat einfügen" (Review 7.4) fehlt.

Diagramme sind maus-only (`BucketChart` ohne Accessibility, exakte Werte nur per Hover).

---

## 6. Funktionsmatrix

● gleichwertig oder voraus · ◐ vorhanden, schwächer · ○ fehlt · ⛔ bewusst nicht

| Fähigkeit | Notable | Was fehlt, um ● zu werden |
|---|---|---|
| Push-to-talk / freihändig | ● | A10 (Lock-Schwelle) |
| Erkennungslatenz | ● | — |
| Ressourcen im Leerlauf | ● | — |
| Offline / Datenschutz | ● | — (Wispr: ○) |
| Mehrsprachigkeit | ● (de/en-Profil, v3 mehrsprachig) | Auto-Erkennung pro Clip ist da; Wispr kann sie auf dem Desktop nicht |
| Snippets | ● | Formatierung (rich) — nur wenn Ziel-App es annimmt |
| Meetings | ● (Diarisierung lokal; Wispr Beta) | — |
| Zeichensetzung / Großschreibung | ◐ | §4.1 Zeile 1 |
| Füllwörter | ◐ | §4.1 Zeile 3 |
| Zahlen/Daten deutsch | ○ | §4.1 Zeile 2 |
| Selbstkorrektur | ○ | lokales Modell (§4.2) |
| Tonfall je App | ◐ (Regeln je Kategorie) | lokales Modell |
| App-Erkennung | ◐ (20 IDs, kein Browser) | Tabelle + Picker (Spec 03 §5) |
| Kontext um den Cursor | ○ | lokales Modell + Beschluss (§9) |
| Command Mode / Text bearbeiten | ⛔ → ○ mit lokalem Modell | Spec 04 auf lokalem Weg |
| Wörterbuch-Auto-Learn | ◐ (nur über Korrektur-Dialog) | Quelle C mit Beschluss |
| Code-Diktat | ◐ (verbatim, 3 Editoren) | camelCase/Symbole: Regeln S; Editoren in Tabelle |
| Fehler: Wiederholen aus Historie | ○ | A9 |
| Fehlerfläche | ◐ | §5.3 |
| HUD-Übergänge / Identität | ◐ | §5.1 |
| HUD klickbar (Abbrechen) | ○ | §5.1 |
| HUD-Position | ◐ (unten/Notch) → ● mit Spec 28 | — |
| Ton in der Vorgabe | ○ | A8 |
| Live-Text | ○ (Wispr: ○) | Spec 05 Modus 1 oder löschen |
| Einstellungen: Dichte | ◐ | §5.2 |
| Onboarding-Demo-Moment | ◐ (Text + Häkchen) | animierte Wellenform, Beispieltext; Mikrofon-Seite darf nicht ohne Grant weitergehen |
| Sync / Teams / Windows / iOS | ⛔ | — |

---

## 7. Empfehlung: Reihenfolge und Zuschnitt

Fünf Bausteine, je einer eine Spec — geschrieben am selben Tag als
[29](../specs/29-kernschleife-haerten.md), [30](../specs/30-hud-und-fehlerflaeche.md),
[31](../specs/31-regeln-nachziehen.md), [32](../specs/32-lokales-sprachmodell.md) und
[33](../specs/33-einstellungen-diaet-und-craft.md); die Kurzfassung hier bleibt, die
Specs sind maßgeblich.

**Baustein 1 — Kernschleife härten (Spec 29, S–M, zuerst).** A1–A7, A10, A12 in einer
Runde, plus die Testnaht: `finishRecording` in ein pures Entscheidungsstück
(`DictationPipeline`: Zustand rein, nächster Schritt raus) und eine dünne Hülle
trennen, mit `DictationControllerTests` für Paste, Cancel, Fehler, Pending-Swap,
Generationswechsel. Abnahme: zwei Diktate hintereinander ohne Pause; Esc in jeder Phase;
verweigertes Mikrofon nennt sich beim ersten Druck; AirPods mitten im Satz verbinden
verliert kein Wort. Nichts davon braucht eine Entscheidung.

**Baustein 2 — HUD und Fehlerfläche (Spec 30, S–M).** Ein-/Ausblenden, eine Identität
(Material, `Theme`), Spinner erst ab 300 ms, Wellenform aus dem Audio-Callback statt
10-Hz-Timer, Töne an in der Vorgabe, `UserFacingError`-Mapping, letzter Clip im Spool
mit „Wiederholen" in der Historie (A8, A9, §5.1, §5.3). Optional: klickbarer Abbruch.
Dazu die vier Lokalisierungslecks (§5.5) — ein Vormittag.

**Baustein 3 — Regeln nachziehen (Spec 31, S–M).** Großschreibung nach Satzende,
deutsche ITN, Füllwörter und Wiederholungen, App-Tabelle mit Browsern und Editoren plus
der Picker aus Spec 03 §5, Token-Zeiten aus FluidAudio prüfen und wenn vorhanden Absätze
an Pausen. Alles offline, alles pur, alles testbar mit dem bestehenden Muster.

**Baustein 4 — Lokales Sprachmodell als Textstufe (Spec 32, M, die Paritätsfrage).**
Zuerst **messen** (Latenz und Qualität von FoundationModels auf zwanzig echten Diktaten
aus `recordings.raw_text`, gegen den Regelpfad), dann bauen: `LocalPolisher` hinter
`#available(macOS 26, *)`, Guided Generation für Text + „was ich geändert habe", nie
werfen, Fallback Regelpfad, Betriebsart nach §9. Abnahme: Selbstkorrektur-Sätze,
Listen, Satzzeichenreparatur auf einem festen Korpus; die 119 ms bleiben für kurze
Diktate unangetastet. Der Overlay-Zustand sagt „Formatiere…", ohne „verlässt das Gerät",
weil es das nicht tut — und genau das ist der Satz, den Wispr nicht schreiben kann.

**Baustein 5 — Einstellungen-Diät (Spec 33, M).** §5.2 Regeln a–c, Tokens aus §5.4,
Fenstergrößen aus einer Konstante, Frame-Persistenz, Hauptmenü mit Über/Hilfe,
Onboarding-Mikrofonseite blockierend, der demonstrierende Erste-Diktat-Moment. Reines
Craft, kein Risiko im Kernpfad.

**Danach, nur mit Baustein 4 im Alltag bewährt — Kontext und Befehle lokal (L).**
Kontext um den Cursor per AX, Spec 04 mit lokalem Provider, Wörterbuch-Quelle C. Alle
drei lesen Fremdtext; §9.

Was **nicht** empfohlen wird: Cloud-ASR (Architektur), Live-Text als Paritätsthema
(Wispr hat keinen), Geräte-Sync, Team-Funktionen, weitere Plattformen, ein ziehbares HUD
(Panel darf nie key werden; ein Picker mit vier Plätzen deckt das ab).

Grob: Bausteine 1–3 zusammen etwa zwei Wochen und holen den größten Teil des
„buggy"-Gefühls. Baustein 4 ist die einzige Stelle, an der Notable Wispr in der Sache
nachholen muss — und die einzige, die eine Messung vor der Entscheidung braucht.

---

## 8. Doku-Abweichungen, die mit erledigt werden sollten

- `README.md:21-22`, `README.de.md:23`: „decode incrementally while you speak" — falsch.
- `specs/README.md:17`: Spec 05 „gebaut" — nur der Apparat, nicht der Pfad.
- `DictationController.swift:504-508, 564-566`: Kommentare beschreiben Esc-Verhalten,
  das unerreichbar ist (A3).
- `MeetingsSettingsView.swift:130`: ⇧⌘N existiert nicht.
- `CLAUDE.md:99` nennt vier Testklassen, die „real models" laufen — nur
  `WhisperTranscriberTests` überspringt ohne Modell, die anderen vier schlagen fehl.
- `PLAN.md:3-5` „alle Phasen inkl. 8 implementiert": 8.2 (inkrementell) und 8.3
  (Partial-Text) sind es nicht.

---

## 9. Offene Entscheidungen (für den Owner, nicht für die Spec)

1. **Betriebsart des lokalen Modells:** nur ab ~25 Wörtern (Vorschlag), immer, oder nur
   auf Abruf. Entscheidet über die Latenzerfahrung jedes einzelnen Diktats.
2. **Fremdtext lokal lesen** (Kontext um den Cursor, Spec 04, Wörterbuch-Quelle C): die
   Datengrenze ist nicht berührt, aber es ist das erste Mal, dass Notable in fremden
   Fenstern liest. Ja mit Schalter, oder nein.
3. **Spec 05:** Modus 1 bauen oder den toten Code samt vier Tests löschen. Der heutige
   Zustand — drei Dokumente, zwei Aussagen — ist die schlechteste der drei Optionen.
4. **Töne an in der Vorgabe** — ändert das Verhalten einer laufenden Installation.
5. **Messinstrumente in den Einstellungen** (Call-Fenster-Probe, CLI-Argumente,
   Latenzzeile): hinter ⌥-Klick, in Skripte, oder bleiben.
6. **Vertikaler Anker und Links-Spiegel** für Spec 28 (dort §7).

---

## Anhang — Quellen zu Wispr Flow

Herstellerseiten und Doku (abgerufen 2026-09-14): `wisprflow.ai/features`,
`wisprflow.ai/pricing`, `wisprflow.ai/privacy`, `docs.wisprflow.ai` (Artikel:
„What is Flow", „Use Flow hands-free", „Starting your first dictation", „Navigating the
Wispr Flow app", „Teach Flow your words with the dictionary", „How to use Command Mode",
„Feature: Context Awareness", „Retry failed transcriptions", „Security and compliance
FAQ", Sammlung „Wispr Notetaker"), `roadmap.wisprflow.ai/changelog`.
Presse: TechCrunch (2026-02-23 Android; 2026-08-05 Notetaker), Computerworld (Notetaker).
Rezensionen und Berichte, als Richtung, nicht als Messung: tldv.io, ModelPiper
(Datenschutzvorfall 2025), StatusGator (Ausfälle), Trustpilot (2,7/5).
Ein Widerspruch in den Quellen: Marketing „HIPAA fully compliant on all plans" gegen die
Security-FAQ „SOC 2 Type II observation underway" — für diese Analyse ohne Belang.

Notable-Messwerte: `CLAUDE.md` (Latenz, RSS), `LatencyProbeTests`,
`sw_vers`/`xcodebuild -version`/`sysctl` auf dem Build-Rechner.
