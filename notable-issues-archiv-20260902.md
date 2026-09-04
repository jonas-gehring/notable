# Notable — GitHub-Issues #1–#5 (archiviert vor dem Löschen, 2026-09-02)

---

## #1 — Spec 15 — Textverbesserung & Formatierung für Diktate (offline + Claude-CLI auf Abruf)

Status: CLOSED · erstellt 2026-09-01T06:01:30Z · geschlossen 2026-09-01T13:27:32Z

> **✅ Umgesetzt am 2026-09-01.** Was beim Bauen anders entschieden wurde, steht in den Kommentaren; die Abnahme unten ist auf den tatsächlichen Stand gesetzt.

> **Spec 15** der Feature-Welle in `Specs/` · **Vorbild:** VoiceInk (`Features/Enhancement/`) · **Aufwand: Stufe 1 = S, Stufe 2 = M**

## 0. Scope-Entscheidung (Owner, 2026-09-01) — ersetzt einen Teil von 2026-07-18

Bis heute galt: **Diktattext verlässt das Gerät nie**, jede LLM-Berührung nur über ein
lokales Modell. Diese Regel wird **eng und ausdrücklich** gelockert:

- ✅ **Erlaubt:** `ClaudeCodeCLIProvider` (Claude Max via `claude -p`) darf Diktattext
  verarbeiten — **aber ausschließlich auf ausdrücklichen Abruf** durch den Nutzer.
- ⛔ **Nicht erlaubt:** kein automatischer Lauf nach jedem Diktat. Ohne Abruf verlässt
  weiterhin kein Diktatzeichen das Gerät.
- ⛔ **Nicht erlaubt:** `AnthropicAPIProvider` (bezahlter API-Key) für Diktattext. Der
  Meeting-Pfad behält beide Provider, der Diktat-Pfad bekommt **nur** den CLI-Weg.
- ℹ️ **Zur Klarstellung, weil es leicht zu verwechseln ist:** die CLI ist *nicht* lokal.
  `claude -p` ist ein lokal gestarteter Prozess, der Text an Anthropic schickt. Lokal ist
  daran nur die Abrechnung (Max-Kontingent statt Rechnung pro Token). Diese Spec behandelt
  ihn deshalb überall als Cloud-Weg — mit Einwilligung, Anzeige und Protokoll.

Audio bleibt davon vollständig unberührt: es verlässt das Gerät weiterhin nie.

---

## 1. Stufe 1 — Absatz- und Strukturformatierung (offline, regelbasiert)

Unabhängig von Stufe 2, braucht kein Netz, kein Modell, keine Einwilligung. **Zuerst bauen.**

### Problem
`TextPolisher.polish` liefert heute **eine einzige Zeile**: `tidy()` kollabiert jeden
Whitespace zu einem Leerzeichen (`TextPolisher.swift:117–125`). Ein 90-Sekunden-Diktat
landet als Textwurm im Zielfeld.

### Lösung: `ParagraphFormatter` (pure, neu in `Sources/Notable/Dictation/`)

1. **Absätze**: Nach *n* Sätzen (Default 3) **und** einer Sprechpause an dieser Stelle.
   Die Pause muss vom ASR kommen, nicht geraten werden:
   - Parakeet v3 liefert Segment-/Wortzeiten; eine Lücke > `paragraphGapSeconds`
     (Default 0,8 s) macht eine Absatzgrenze **zulässig**.
   - Ohne Zeiten (Whisper-Pfad) wird **nur** nach Satzanzahl umgebrochen — nie im Satz.
2. **Diktierte Struktur-Kommandos** (deutsch + englisch, wortgenau, case-insensitiv):
   „neue Zeile" / „new line" → `\n` · „neuer Absatz" → `\n\n` · „Aufzählung" /
   „Stichpunkt" → `- ` · „erstens/zweitens/…" am Satzanfang → `1. `, `2. `.
   Die Kommandos werden entfernt und durch ihre Wirkung ersetzt.
3. **Verbatim-Schutz**: In `AppCategory.code` (`options.verbatim`) komplett aus.

### Integration
- Neue Felder in `TextPolisher.Options`: `paragraphs` / `structureCommands` (Default an),
  gesetzt in `Options.fromDefaults()` (`:29`) wie `removeFillers`/`applyITN`.
- `PolishProfile.options(for:)` (`:137`) schaltet beides für `.code` ab, für `.chat` nur
  die Absätze (eine Slack-Zeile bleibt eine Zeile).
- Aufruf am Ende von `polish()`, **nach** `tidy()`. ⚠️ `tidy` muss Zeilenumbrüche, die der
  Formatter setzt, überleben lassen — dieselbe Änderung braucht #4 (Smart Replace) für
  mehrzeilige Bausteine. Wer zuerst baut, macht es; der andere erbt.

### Tests (`TextPolisherTests`)
5 Sätze ohne Zeiten ⇒ ein Umbruch nach Satz 3, keiner im Satz · 1,2-s-Lücke ⇒ Umbruch
genau dort · „neue Zeile" mitten im Satz ⇒ `\n`, Kommando weg, kein Doppel-Whitespace ·
`verbatim` ⇒ Ausgabe identisch zur Eingabe · Idempotenz `format(format(x)) == format(x)`.

---

## 2. Stufe 2 — Verbesserung auf Abruf über die Claude-Code-CLI

### 2.1 Der Kernpfad wird nicht angefasst

Das ist der Sinn von „auf Abruf": `DictationController.finishRecording`
(`DictationController.swift:313–401`) bleibt **unverändert**. Kein zusätzlicher `await`,
kein Availability-Check, keine neue Latenz. Ein normales Diktat ist nach dem Update
exakt so schnell wie heute (~119 ms bei 5 s Audio) — und exakt so offline.

Das ist auch die Antwort auf die Latenzfrage: ein `claude -p`-Roundtrip kostet
Prozessstart + Netz, realistisch **2–6 s**. In den Kernpfad gehört das nicht.

### 2.2 Zwei Abrufwege

**Weg A — „Diktat mit Verbesserung" (der Hauptweg).**
Ein **zweiter, eigener Hotkey**. Er startet dieselbe Aufnahme wie der normale, aber beim
Loslassen läuft nach dem Polieren zusätzlich der CLI-Roundtrip; eingefügt wird **genau
einmal**, das verbesserte Ergebnis. Warum das der Hauptweg ist: es gibt keinen Weg,
bereits eingefügten Text in einer fremden App zurückzuholen — `DictationHistory`
begründet das schon ausführlich („macOS gibt keinen verlässlichen Hook, um ein
synthetisiertes ⌘V zurückzunehmen"). Wer die Verbesserung *vorher* anfordert, hat das
Problem nicht.

Overlay-Zustand `.enhancing` („Verbessere…", neu in `OverlayState`,
`DictationOverlay.swift:10–15`). Profil: aus `AppCategory` des Ziels vorbelegt.

**Weg B — „Letztes Diktat verbessern" (Menü).**
Im Menüleisten-Dropdown unter den letzten Diktaten, als Untermenü mit den Profilen
(E-Mail · Notiz/Stichpunkte · Straffen · Eigenes …). Angedockt an `DictationHistory`
(`DictationHistory.swift`), das `last`, `copy` und `paste` bereits kann:

```swift
@discardableResult
func enhanceLast(profile: EnhancementProfile) async throws -> String
```

Ergebnis landet **in der Zwischenablage**, plus eine Benachrichtigung mit „Einfügen".
Es wird **nicht** stillschweigend über den alten Text geschrieben — der steht längst
irgendwo, und wir tun nicht so, als könnten wir ihn zurückholen.

### 2.3 Provider — kein neuer Code, das Protokoll trägt schon

`SummarizationProvider.complete(system:user:)` (`SummarizationProvider.swift`) macht
genau das, was hier gebraucht wird: ein System+User-Roundtrip, Text zurück, Verbrauch
inklusive (`Completion.usage`). `SpeakerNameResolver` benutzt es bereits so.

Also: **kein neuer Provider.** Ein `DictationEnhancer` (dünn) nimmt eine
`SummarizationProvider`-Instanz entgegen und ist im Diktat-Pfad **hart auf den
CLI-Provider verdrahtet** — der API-Provider wird nicht durchgereicht, auch nicht, wenn
er in den Einstellungen als Meeting-Provider gewählt ist. Diese Verdrahtung ist eine
Zeile, sie ist die Umsetzung von §0, und sie gehört durch einen Test abgesichert.

Ist die CLI nicht eingeloggt/vorhanden (`ClaudeCodeCLILocator`), sagt der Menüpunkt das
und ist deaktiviert. Kein Fallback auf irgendetwas.

### 2.4 Profile

`EnhancementProfile`: Titel + Systemprompt, eingebaut (`mail`, `notes`, `chat`, `tighten`)
und benutzerdefiniert (Titel + freier Prompt, wie VoiceInks `CustomPrompt`), gespeichert
als JSON in `UserDefaults`. Systemprompt-Regeln analog `SummarizationPrompt`: nichts
erfinden, keine Meta-Sätze, nur den überarbeiteten Text ausgeben, Sprache beibehalten.

### 2.5 Guardrails vor dem Einfügen

Die Ausgabe wird verworfen (⇒ polierter Rohtext), wenn sie leer ist, > 250 % der
Eingabelänge, < 40 % der Eingabelänge, oder Meta-Text/Codefences enthält („Hier ist die
überarbeitete Version"). Analog VoiceInks `AIEnhancementOutputFilter`. Timeout hart bei
`enhancementDeadline` (Default 15 s — großzügiger als im Kernpfad, weil hier bewusst
gewartet wird); Abbruch per Esc.

### 2.6 Einwilligung, Sichtbarkeit, Protokoll

- **Einmalige Bestätigung** beim ersten Abruf: ein Dialog, der sagt, dass der Text an
  Anthropic geht (Max-Kontingent, kein API-Key), mit „Verstanden, nicht mehr fragen".
  Gespeichert in `UserDefaults`, zurücksetzbar in den Einstellungen.
- Jeder Lauf wird über `UsageRecorder` in `llm_usage` gebucht:
  `purpose = "dictation-enhance"`, `provider = <CLI-ID>`, `billed = 0`. Damit ist
  jederzeit nachzählbar, wie oft Diktattext das Gerät verlassen hat — das ist der
  eigentliche Grund für diese Buchung, nicht die Kosten. **`billed = 0` heißt weiterhin:
  taucht in keiner Ausgabensumme auf** (siehe #5).
- `RecordingStore` bekommt eine Spalte `raw_text` (nullable, nur gesetzt wenn verbessert):
  sonst ist nicht mehr nachvollziehbar, was das Modell verändert hat.

### 2.7 Einstellungen (Diktat-Tab, Abschnitt „Textverbesserung")

Hotkey für „Diktat mit Verbesserung" (Default: leer = aus) · Profil-Editor ·
Zeitbudget · Status der CLI · Einwilligung zurücksetzen · ein Satz, der ohne Beschönigung
sagt, wohin der Text geht und wann.

### 2.8 Ausdrücklich nicht in dieser Spec

Markierten Text per Stimme umschreiben (Accessibility/`SelectedTextService`) — das ist
`Specs/04-voice-commands.md` und bleibt zurückgestellt. Diese Spec berührt nur Text, den
Notable selbst gerade diktiert hat.

---

## 3. Abnahme

**Stufe 1 — Absatz- und Strukturformatierung**
- [x] „neue Zeile"/„Stichpunkt" wirken und verschwinden aus dem Text
- [x] Xcode/Terminal: Ausgabe unverändert (verbatim kehrt vor `tidy` zurück, Test)
- [x] `polish()` bleibt pure, alle bestehenden `TextPolisherTests` grün
- [x] ~~90-s-Diktat hat Absätze an Sprechpausen~~ — **gestrichen (Owner, 2026-09-01).**
      Nicht baubar: `TranscriptionEngine.transcribe` liefert bei allen drei Engines nur
      `String`, es gibt im Diktatpfad keine Wortzeiten. Umgesetzt ist der Fallback aus
      der Spec selbst (Umbruch nach je drei Sätzen, nie im Satz).

**Stufe 2 — Verbesserung auf Abruf**
- [x] Test belegt: der Diktatpfad erreicht `AnthropicAPIProvider` nie — auch nicht, wenn
      er als Meeting-Provider eingestellt ist
- [x] Fehler/Timeout/verworfene Antwort ⇒ polierter Rohtext wird eingefügt, Meldung danach
- [x] Jeder Lauf erzeugt genau eine `llm_usage`-Zeile mit `billed = 0` — auch dann, wenn
      die CLI keine Zahlen meldet (`countEvenWhenUnknown`)
- [x] Ohne Zustimmung passiert nichts: der Einstellungsschalter **ist** die Zustimmung,
      und solange er aus ist, wird die zweite Taste nicht einmal installiert

**Nachtrag 2026-09-01:** neben Claude Code sind auch Gemini CLI und Codex CLI wählbar.
Die Regel „kein bezahlter API-Schlüssel im Diktatpfad" gilt unverändert — sie war immer
eine Aussage über die Abrechnung, nicht über einen Anbieter.

### Bleibt manuell zu prüfen (nach der Installation)
- Normales Diktat: identische Latenz, kein Netzverkehr — als Messung, nicht als Behauptung
- Diktat mit Verbesserung: genau ein Einfügevorgang, Overlay zeigt „Verbessere…"


---

## #2 — Spec 16 — Aufbewahrung & Auto-Cleanup (Meeting-Audio, Diktate, Chats)

Status: CLOSED · erstellt 2026-09-01T06:01:32Z · geschlossen 2026-09-01T13:27:35Z

> **✅ Umgesetzt am 2026-09-01.** Was beim Bauen anders entschieden wurde, steht in den Kommentaren; die Abnahme unten ist auf den tatsächlichen Stand gesetzt.

> **Spec 16** der Feature-Welle in `Specs/` · **Vorbild:** VoiceInk (`AudioCleanupManager`, `TranscriptionAutoCleanupService`) · **Aufwand: M**

## 1. Der Befund (gemessen am 2026-09-01, produktive Installation)

```
~/Library/Application Support/Notable/
  spool-archive   9,8 GB   (15 Sessions, 2026-07-19 … 2026-08-27)
  spool-failed     80 MB   (6 Sessions)
  spool             0 B
  notable.sqlite  960 KB
```

Sechs Wochen Nutzung ⇒ **9,8 GB**. Nichts davon wird je gelöscht: `SpoolStore.archive`
verschiebt eine fertig verarbeitete Session nach `spool-archive` und dort bleibt sie
(`SpoolStore.swift:110–121`), `markFailed` dasselbe nach `spool-failed` (`:44–50`).
Rohaudio ist Float32 @ 16 kHz mono ⇒ **64 kB/s je Spur, ~460 MB je Meeting-Stunde**
für Mic + System.

Nebenbefund, der in dieselbe Kerbe schlägt: eine einzelne Session belegt **6,4 GB** ≈
**14 Stunden** Aufnahme. Da ist eine Aufnahme nicht beendet worden. Ein Aufräumen ist
also nicht nur Hygiene — es ist auch der Ort, an dem so ein Ausreißer überhaupt
**sichtbar** wird.

Die SQLite-Seite ist heute unkritisch (960 KB), wächst aber monoton: `recordings`,
`segments`, `chat_messages` werden nie gelöscht.

## 2. Was NICHT gelöscht werden darf — die Leitplanken

Das ist der schwierige Teil, nicht das Löschen selbst.

1. **Die Statistik darf nicht schrumpfen.** `UsageMetrics` rechnet Wörter, gesparte Zeit
   und Meeting-Dauer aus `recordings`-Zeilen (`RecordingStore.usageRows`,
   `:467`). Wer eine alte Diktatzeile löscht, radiert rückwirkend Statistik. Deshalb:
   **Aufräumen löscht Text, nie die Zeile.** Konkret ⇒ `segments.text` eines alten
   Diktats wird geleert, `recordings.word_count` bleibt stehen (die Spalte existiert
   genau dafür, `RecordingStore.swift:558` `backfillWordCounts`).
2. **`llm_usage` wird nie angefasst.** Append-only Kassenbuch, ohne Foreign Key
   (bewusst, `RecordingStore.swift:691–709`). Es sagt, was tatsächlich ausgegeben wurde,
   und das bleibt wahr, auch wenn das Meeting weg ist.
3. **Der Notiz-Ordner des Nutzers ist tabu.** `NotesFolderManager.folderURL` zeigt auf
   Dokumente/Obsidian/iCloud — fremdes Terrain. Markdown-Notizen werden **nie**
   automatisch gelöscht, auch nicht optional. Wer aufräumen will, tut das im Finder.
4. **`spool/` (laufend) bleibt tabu.** Crash-Recovery liest daraus beim Start.
5. **Nie löschen, was nie verarbeitet wurde.** `spool-failed` ist ausdrücklich zum
   Von-Hand-Retten da. Es bekommt eine eigene, längere Frist und eine ausdrückliche
   Warnung in der UI.

## 3. Retention-Regeln (alle einstellbar, Default in Klammern)

| Klasse | Ort | Aktion | Default |
|---|---|---|---|
| Meeting-Rohaudio | `spool-archive/` | Session-Ordner löschen | nach **30 Tagen** |
| Meeting-Rohaudio | `spool-archive/` | zusätzlich: Gesamtbudget | **20 GB**, älteste zuerst |
| Fehlgeschlagene Spools | `spool-failed/` | Ordner löschen | nach **90 Tagen** |
| Diktat-Text | `segments` (kind=dictation) | `text = ''`, Zeile bleibt | **nie** (aus) |
| Meeting-Transkripte | `segments` (kind=meeting) | `text = ''`, Zeile bleibt | **nie** (aus) |
| Chat-Verläufe | `chat_messages` | löschen | **nie** (aus) |
| Statistik / `llm_usage` | — | — | **nie**, nicht abschaltbar |

Zwei Achsen für Audio (Alter **und** Budget), weil eine allein nicht reicht: 30 Tage
schützen nicht vor der 6,4-GB-Session, ein Budget allein nicht vor dem stillen
Weiterwachsen bei viel Platz.

Nach `VACUUM`-Bedarf wird geprüft, aber nur beim manuellen Aufräumen — nicht im
Autostart-Pfad.

## 4. Umsetzung

Neu: `Sources/Notable/Storage/RetentionPolicy.swift`

- `struct RetentionPolicy` — pure, aus `UserDefaults` geladen (`fromDefaults()`, wie
  `TextPolisher.Options`), mit den Feldern oben.
- `enum RetentionPlanner` — **pure**: `plan(policy:now:sessions:) -> RetentionPlan`.
  Eingabe ist eine Liste `(url, startedAt, byteSize)`, Ausgabe eine Liste zu löschender
  URLs plus eine Begründung je Eintrag (`.tooOld(days:)`, `.overBudget`). Kein
  Dateisystem, kein SQLite ⇒ vollständig testbar. **Hier liegt die ganze Logik.**
- `actor RetentionRunner` — führt den Plan aus: `FileManager.removeItem`, dann die
  SQLite-Teile über `RecordingStore`. Schreibt eine Zeile je gelöschtem Eintrag ins
  Log (`Logger`), damit „wo ist meine Aufnahme hin" beantwortbar bleibt.

`RecordingStore` bekommt:
- `func archiveSizes() throws -> ...` — nein, das gehört ins Dateisystem, nicht in den
  Store. Stattdessen: `func clearSegmentText(olderThan:kind:) throws -> Int` und
  `func deleteChatMessages(olderThan:) throws -> Int`. Beide melden die Anzahl.

Aufruf: einmal beim Start in `AppDelegate` — **nach** der Spool-Crash-Recovery, nie
davor (sonst kann der Runner theoretisch ein gerade wiederhergestelltes Verzeichnis
wegräumen) — und danach alle 24 h per Timer. Nie während einer laufenden Aufnahme:
`MeetingController.isRecording` ⇒ Lauf wird übersprungen.

## 5. UI (Einstellungen → neuer Abschnitt „Speicherplatz")

- Zeile mit **gemessener** Belegung je Klasse („Meeting-Audio: 9,8 GB · 15 Sitzungen"),
  berechnet beim Öffnen des Tabs, nicht laufend.
- Je Klasse ein Picker (Aus / 7 / 30 / 90 / 365 Tage) und für Audio zusätzlich das
  Budget (Aus / 5 / 10 / 20 / 50 GB).
- **„Jetzt aufräumen"** zeigt zuerst den Plan („12 Sitzungen, 8,1 GB werden gelöscht")
  und löscht erst nach Bestätigung. Kein stiller Ein-Klick-Löscher.
- Ein Satz, der sagt, was **nicht** passiert: Markdown-Notizen und Statistik bleiben.

## 6. Tests

`RetentionPlannerTests` (pure):
- leerer Ordner ⇒ leerer Plan
- Alter-Regel: exakt an der Grenze wird **nicht** gelöscht (`>`, nicht `>=`)
- Budget-Regel: löscht älteste zuerst, hört auf, sobald unter Budget
- Alter + Budget kombiniert ⇒ Vereinigung, jeder Eintrag genau einmal
- Policy komplett aus ⇒ leerer Plan (der „ich habe nichts eingestellt"-Fall löscht nie)

`RecordingStoreTests`:
- `clearSegmentText` leert Text, lässt `recordings.word_count` und die Zeile stehen
- `usageRows` liefert nach dem Leeren **identische** Zahlen wie davor ← die eigentliche
  Regressionsangst
- `llm_usage` bleibt unberührt

## 7. Abnahme

- [x] Statistik zeigt vorher und nachher dieselben Werte (`usageRows` Zeile für Zeile
      verglichen — geleert wird Text, nie eine Zeile)
- [x] `llm_usage` bleibt unberührt, inklusive `billed`
- [x] Der Notiz-Ordner ist unverändert — kein Codepfad im `RetentionRunner` führt dorthin
- [x] Während einer laufenden Meeting-Aufnahme läuft kein Cleanup
- [x] Jede Löschung steht mit Grund im Log (`Logger`, Kategorie `retention`)
- [x] `spool-archive` ist unter 20 GB — **erledigt am 2026-09-01**: die 6,4-GB-Sitzung
      vom 22. Juli ist gelöscht, 9,8 GB → 3,4 GB. Ursache laut Owner: „Beenden" wurde
      vergessen, die Aufnahme lief knapp 15 Stunden weiter. Das Transkript des Meetings
      liegt unverändert in der Inbox; verloren ist nur das Rohaudio.

**Eine Abweichung von der Spec:** Automatisches Aufräumen ist **aus**, bis es
eingeschaltet wird. Die Fristen (30 Tage / 20 GB) liegen als Default bereit, aber
ungefragt und unumkehrbar beim ersten Start nach einem Update zu löschen ist die eine
Kombination, die einen Schalter verdient.


---

## #3 — Spec 17 — Notch-Recorder: Aufnahme-HUD an der Notch

Status: CLOSED · erstellt 2026-09-01T06:01:33Z · geschlossen 2026-09-01T13:27:37Z

> **✅ Umgesetzt am 2026-09-01.** Was beim Bauen anders entschieden wurde, steht in den Kommentaren; die Abnahme unten ist auf den tatsächlichen Stand gesetzt.

> **Spec 17** der Feature-Welle in `Specs/` · **Vorbild:** VoiceInk (`NotchRecorderPanel`, `NotchShape`, `NotchWindowManager`) · **Aufwand: S–M**

## 1. Ausgangslage

`DictationOverlayController` (`Sources/Notable/Dictation/DictationOverlay.swift`) ist
heute eine Kapsel **unten mittig**, 80 px über der `visibleFrame`-Unterkante
(`:93–100`). Das funktioniert, hat aber zwei praktische Schwächen: unten mittig liegt
genau dort, wo in Vollbild-Apps und Videocalls die Steuerleisten sitzen, und der Blick
ist beim Diktieren oben (Textfeld, Menüleiste, Uhr).

Die Notch ist der ruhigste Platz des Bildschirms — sie ist ohnehin tote Fläche.

## 2. Was **nicht** angetastet wird (harte Grenzen)

Aus `CLAUDE.md`: das Overlay-Panel **darf nie key werden**, sonst bricht der
Paste-ins-fokussierte-Feld-Mechanismus. Alles Folgende bleibt daher wie es ist:

- `styleMask: [.borderless, .nonactivatingPanel]`, `orderFrontRegardless()`, **nie**
  `makeKey` (`DictationOverlay.swift:32–40, 74–91`)
- `ignoresMouseEvents = true` — der Notch-Recorder wird bewusst **nicht** klickbar.
  VoiceInk macht daraus eine Bedienfläche; wir nicht: ein klickbares Panel im Diktatpfad
  ist genau die Klasse Fehler, die diese Regel verhindert. Anzeige, sonst nichts.
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `level = .statusBar`
- `Model`/`OverlayState` bleiben unverändert ⇒ `DictationController` muss **gar nicht**
  angefasst werden.

Die Änderung ist also rein: (a) eine zweite View, (b) eine Positionierungsstrategie.

## 3. Umsetzung

### 3.1 `NotchGeometry` — pure, testbar (neu)

```swift
enum NotchGeometry {
    struct Screen { let frame: CGRect; let safeAreaTop: CGFloat; let auxLeft: CGRect?; let auxRight: CGRect? }
    enum Placement { case aroundNotch(left: CGRect, right: CGRect); case pillUnderMenuBar(CGRect); case bottomCenter(CGRect) }
    static func placement(for screen: Screen, size: CGSize, style: OverlayStyle) -> Placement
}
```

- **Notch vorhanden** (`safeAreaTop > 0`, macOS 12+; die Hilfsflächen liefern
  `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`): Panel spannt sich über die
  volle Breite oben, die Inhalte sitzen **links und rechts neben** der Aussparung —
  links der Pegel, rechts der Status. Die Notch selbst bleibt frei, das ist der Effekt.
- **Kein Notch** (externer Monitor, ältere MacBooks): eine Pille direkt **unter** der
  Menüleiste, mittig — dieselbe View, nur ohne Aussparung. Kein Zweiklassen-Ergebnis.
- **`bottomCenter`**: das heutige Verhalten, unverändert erreichbar.

Die Funktion ist rein rechnend (Frames rein, Frames raus) ⇒ vollständig unit-testbar,
inklusive der Fälle, die im echten Leben wehtun: Menüleiste ausgeblendet, zwei
Bildschirme mit unterschiedlichem `backingScaleFactor`, Notch-Screen nicht `NSScreen.main`.

### 3.2 Bildschirmwahl

`position(_:)` benutzt heute `NSScreen.main` (`:94`). `NSScreen.main` ist der Screen mit
der **Key-Window** — und unser Panel wird nie key, das Ziel der Eingabe liegt in einer
fremden App. Richtig ist: der Screen, auf dem der **Mauszeiger** steht
(`NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }`), mit
`NSScreen.main` als Fallback. Das ist auch für das heutige Bottom-Overlay eine
Verbesserung und wird gleich mitgenommen.

### 3.3 View

`NotchOverlayView` neben dem bestehenden `DictationOverlayView`:
- Materialhintergrund in der Notch-Form (oben eckig, unten abgerundet) — eine
  `Shape`-Implementierung analog zu VoiceInks `NotchShape`, ~30 Zeilen `Path`.
- Zustände 1:1 wie heute: `.recording` (Pegel + „Esc verwirft" / Lock-Text),
  `.transcribing`, `.loadingModel`, `.error`, plus Partial-Text, wenn vorhanden.
- Der `LevelMeterView` (`:154–171`) wird wiederverwendet; auf der Notch-Variante
  gespiegelt links/rechts. `accessibilityDisplayShouldReduceMotion` weiterhin beachten.
- Bei sehr langem Fehlertext: Pille wächst nach unten, nie über die Notch-Höhe hinaus
  in die Menüleiste hinein.

### 3.4 Einstellung

Diktat-Tab, ein Picker: **Overlay-Position — Unten (Standard) · Notch/Oben · Aus.**
`Aus` ist bewusst dabei: wer nur den Ton als Rückmeldung will, soll das haben können.
Der Wert liegt in `UserDefaults` (`overlayStyle`), `DictationOverlayController` liest ihn
beim `show()`, sodass ein Wechsel sofort greift und kein Neustart nötig ist.

## 4. Tests

`NotchGeometryTests` (pure):
- Screen mit `safeAreaTop = 32` ⇒ `.aroundNotch`, beide Rechtecke berühren die Aussparung nicht
- Screen ohne Notch, Stil `notch` ⇒ `.pillUnderMenuBar`, vollständig innerhalb `visibleFrame`
- Externer 1080p-Screen, Panelbreite > Screenbreite ⇒ Panel wird geklemmt, nie negativ positioniert
- Stil `bottom` ⇒ exakt die heutige Position (Regression gegen `DictationOverlay.swift:93–100`)

Manuell: Aufnahme im Zoom-Vollbild (Panel sichtbar, Call bleibt vorn), auf dem externen
Monitor, mit versteckter Menüleiste.

## 5. Abnahme

- [x] `DictationController` ist unverändert — der Diff berührt nur Overlay, Geometrie
      und Einstellungen
- [x] Umschalten wirkt beim nächsten Diktat ohne Neustart
- [x] Externer Monitor / versteckte Menüleiste / Screen außerhalb des Ursprungs: als
      reine Frame-Rechnung getestet (`NotchGeometryTests`)

**Zwei Abweichungen:** ein Panel über die volle Breite mit durchsichtiger Mitte statt
zwei Fenstern (sonst verdoppelt sich die „darf nie key werden"-Fläche ohne sichtbaren
Gegenwert), und `NSScreen.main` ist raus — positioniert wird auf dem Bildschirm unter dem
Mauszeiger, was auch das bestehende Bottom-Overlay am zweiten Monitor korrigiert.

### Bleibt manuell zu prüfen (nach der Installation)
- Panel wird nie key; Diktat landet weiterhin im fokussierten Feld (Slack/Xcode/Mail)
- Auf dem internen Display sitzt die Anzeige links und rechts der Notch
- Auf dem externen Display erscheint die Pille unter der Menüleiste, nicht abgeschnitten


---

## #4 — Spec 18 — Smart Replace: Textbausteine & Abkürzungen

Status: CLOSED · erstellt 2026-09-01T06:01:35Z · geschlossen 2026-09-01T13:27:39Z

> **✅ Umgesetzt am 2026-09-01.** Was beim Bauen anders entschieden wurde, steht in den Kommentaren; die Abnahme unten ist auf den tatsächlichen Stand gesetzt.

> **Spec 18** der Feature-Welle in `Specs/` · **Vorbild:** VoiceInk (`WordReplacementService`, „Smart Replace") · **Aufwand: S**

## 1. Abgrenzung zum bestehenden Wörterbuch — der eigentliche Entwurf

Wir haben schon eine Ersetzung: `PersonalDictionary` (`TextPolisher.swift:167–246`),
angewandt exakt (längster Schlüssel zuerst, `polish` :73–75) und danach **fuzzy**
(`FuzzyDictionary.apply`, :76–78).

Das ist eine **Korrektur**-Tabelle: „was das ASR falsch gehört hat" → „was ich gesagt
habe". Sie darf fuzzy sein, weil beide Seiten dasselbe Wort meinen.

Smart Replace ist etwas anderes: eine **Expansion**. Ein bewusst gesprochenes Kürzel wird
zu beliebigem, auch mehrzeiligem Text („meine Adresse" → drei Zeilen Anschrift, „Grußformel"
→ „Viele Grüße\nJonas"). Daraus folgt die zentrale Regel dieser Spec:

> **Expansionen laufen nie durch `FuzzyDictionary`.**

Eine unscharf getroffene Korrektur kostet ein Wort. Eine unscharf getroffene Expansion
schreibt einen Absatz an eine Stelle, an der nur ein ähnlich klingendes Wort stand. Die
beiden Tabellen bleiben deshalb **getrennt** — auch wenn sie sich in der UI ähneln.

## 2. Datenmodell

Neu in `TextPolisher.swift` (neben `PersonalDictionary`):

```swift
struct SmartReplacement: Codable, Identifiable, Sendable {
    var id: UUID
    var trigger: String        // gesprochene Phrase, 1..n Wörter
    var replacement: String    // beliebiger Text, darf \n enthalten
    var caseSensitive: Bool    // Default false
    var enabled: Bool          // Default true
}

enum SmartReplace {
    static let defaultsKey = "smartReplacements"   // [SmartReplacement], JSON in UserDefaults
    static func load() -> [SmartReplacement]
    static func save(_ items: [SmartReplacement])
    static func apply(_ items: [SmartReplacement], to text: String) -> String   // pure
}
```

**Array, kein Dictionary** (anders als `PersonalDictionary`): die Reihenfolge ist Teil der
Semantik, und ein Eintrag soll ein- und ausschaltbar sein, ohne ihn zu löschen.

### Matching-Regeln (`apply`, pure)
1. Nur **aktive** Einträge, sortiert nach `trigger.count` **absteigend** — der längste
   Treffer gewinnt („neue Adresse" schlägt „Adresse").
2. Wortgrenzen wie `replacingWord` (`:106–116`): Unicode-sichere Lookarounds
   `(?<![\p{L}\p{N}])…(?![\p{L}\p{N}])`, nicht `\b` (Umlaute).
3. Case-insensitiv per Default (`(?iu)`), `caseSensitive` schaltet auf `(?u)`.
4. **Ein Durchlauf, keine Rekursion.** Das Ergebnis einer Expansion wird nie erneut auf
   Trigger geprüft — sonst baut sich der Nutzer eine Endlosschleife.
5. Der Ersetzungstext wird als Literal eingesetzt
   (`NSRegularExpression.escapedTemplate`), damit `$1` oder `\n` im Nutzertext nicht
   als Regex-Template wirken. Ein echtes `\n` gibt der Nutzer als Zeilenumbruch im
   Editor ein, nicht als Escape-Sequenz.

### Platzhalter (Stufe 2, optional)
`{datum}`, `{uhrzeit}`, `{wochentag}` — ausgewertet über `Date.FormatStyle` mit der
aktuellen Locale. Bewusst eine kleine, geschlossene Liste; keine Formatsprache.

## 3. Einbau in `polish()`

Neue Option `replacements: [SmartReplacement] = []` in `TextPolisher.Options`, befüllt in
`Options.fromDefaults()` (`:29`).

Position im Ablauf — **nach** Füllwörtern/ITN, **vor** dem exakten Wörterbuch:

```
Füllwörter → ITN → *** SmartReplace *** → Wörterbuch exakt → Wörterbuch fuzzy → tidy
```

Begründung: Füllwörter zuerst, damit ein „ähm" mitten im Trigger nicht die Phrase
zerreißt. Vor dem Wörterbuch, damit eine Korrekturregel noch auf den **expandierten**
Text wirken kann (Name in der Signatur), aber die Fuzzy-Stufe die Trigger selbst nie
zu sehen bekommt — die sind zu diesem Zeitpunkt schon verschwunden.

**Verbatim (`AppCategory.code`)**: Expansionen laufen **auch dort** — anders als
Füllwortentfernung sind sie eine ausdrückliche Nutzerabsicht, und im Terminal ist ein
Kürzel für einen langen Pfad genau der Gewinn. Das ist eine bewusste Abweichung von der
„verbatim heißt verbatim"-Linie und steht deshalb hier explizit.

## 4. UI (Einstellungen → Wörterbuch-Tab, zweiter Abschnitt „Textbausteine")

- Tabelle: Trigger · Vorschau der Ersetzung (einzeilig gekürzt) · Schalter · Löschen
- Sheet zum Anlegen/Bearbeiten mit **mehrzeiligem** Ersetzungsfeld und Live-Vorschau
  („Wenn du sagst … erscheint …")
- Kollisionswarnung: Trigger, der auch im `PersonalDictionary` steht, wird markiert —
  sonst korrigiert die eine Tabelle, was die andere gerade eingesetzt hat.
- Export/Import als JSON-Datei (dieselbe Codable-Form) — billig und rettet die Liste beim
  Neuaufsetzen.

## 5. Tests (`TextPolisherTests` / neu `SmartReplaceTests`, pure)

- Mehrwort-Trigger wird ersetzt, Teiltreffer nicht („Adressbuch" bleibt unangetastet)
- Längster Treffer gewinnt bei überlappenden Triggern
- Mehrzeilige Ersetzung überlebt `tidy()` **nicht** — deshalb: Test, der belegt, dass
  `tidy` Zeilenumbrüche aus Expansionen **erhält**. ⚠️ `tidy` kollabiert heute `\s+`
  (`:118`); für mehrzeilige Bausteine muss es Zeilenumbrüche schützen. Das ist die eine
  Stelle, an der diese Spec eine bestehende Funktion ändert — und sie überschneidet sich
  mit der Absatzformatierung aus Spec 15 §1. Wer zuerst kommt, baut es; der zweite erbt.
- Deaktivierter Eintrag wirkt nicht
- Keine Rekursion: Ersetzung, die einen anderen Trigger enthält, wird nicht weiter expandiert
- Umlaut-Trigger („Grüße") matcht an Wortgrenzen korrekt
- Leere/Whitespace-Trigger werden beim Speichern abgelehnt, nie angewandt

## 6. Abnahme

- [x] Mehrzeilige Ersetzung überlebt `polish()` — `tidy` kollabiert seit dieser Änderung
      nur noch horizontalen Whitespace
- [x] Wörterbuch-Fuzzy fasst keinen Textbaustein an (Test belegt beide Richtungen: ohne
      Baustein greift die Fuzzy-Regel, mit Baustein ist der Trigger vorher weg)
- [x] Bestehende `TextPolisherTests` unverändert grün
- [x] Leere Bausteinliste ⇒ `polish()` identisch zu vorher

**Ein Fall, den keine der beiden Specs hatte:** `ParagraphFormatter` kapitalisierte den
ersten Wortanfang nach jedem Umbruch — richtig bei einem gesprochenen Kommando, falsch
bei einem Umbruch, den der Baustein selbst mitbrachte. Eine Mailadresse in eigener Zeile
wäre als „Jonas.gehring@…" im Zielfeld gelandet.

### Bleibt manuell zu prüfen (nach der Installation)
- „meine Adresse" diktiert ⇒ mehrzeilige Anschrift im echten Zielfeld


---

## #5 — Spec 19 — Statistik-Ausbau: Peak Hours, Modellnutzung, Modell-Leistung, Ziel-Apps

Status: CLOSED · erstellt 2026-09-01T06:01:37Z · geschlossen 2026-09-01T13:27:42Z

> **✅ Umgesetzt am 2026-09-01.** Was beim Bauen anders entschieden wurde, steht in den Kommentaren; die Abnahme unten ist auf den tatsächlichen Stand gesetzt.

> **Spec 19** der Feature-Welle in `Specs/` · **Vorbild:** VoiceInk (`Features/Dashboard/`: Peak-Hours, Model-Usage, Model-Performance, Produktivitäts-Trend) · **Aufwand: M** · baut auf `Specs/01-nutzungsstatistiken.md`

## 1. Ausgangslage

`StatsView` zeigt heute: Hero (gesparte Zeit), Kacheln, zwei Balkendiagramme (Wörter,
Meetings), Tippgeschwindigkeits-Regler, KI-Token-Kachel. Gerechnet wird alles pure in
`UsageMetrics` aus zwei Zeilentypen (`UsageRow`, `LLMUsageRow`) — die Trennung ist gut
und bleibt: **jede neue Auswertung ist eine pure Funktion in `UsageMetrics` plus eine
View, nie Logik in der View.**

Was fehlt, ist nicht Darstellung, sondern **Datenerfassung**. `recordings` hat heute
(`RecordingStore.swift:653–667`) keine Spalte für Engine, Latenz oder Ziel-App. Ohne die
sind drei der vier VoiceInk-Karten schlicht nicht rechenbar.

## 2. Schema-Erweiterung (Voraussetzung)

Über den vorhandenen, idempotenten Helfer `migrateAddColumn` (`:725`) — läuft bei jedem
Open, ist metadata-only:

| Spalte | Typ | Inhalt | gesetzt von |
|---|---|---|---|
| `engine` | TEXT | `parakeet-v3` / `unified-en` / `whisper-<size>` | `saveDictation` |
| `latency_ms` | INTEGER | Release → eingefügt | `saveDictation` |
| `source_app` | TEXT | Ziel-App des Pastes (Bundle-ID) | `saveDictation` |

Der Name `source_app` ist **nicht neu erfunden**: `Specs/README.md` führt die Spalte
bereits als für Spec 03 vorgesehen, gebaut wurde sie nie. Eine Spalte, ein Name.
| `enhanced` | INTEGER | 1, wenn Spec 15 Stufe 2 gelaufen ist | `saveDictation` |

Alle **nullable**. Jede Auswertung muss `NULL` als „unbekannt" behandeln und darf alte
Zeilen nicht verfälschen — die 6 Wochen Bestandsdaten haben diese Werte nie gehabt.
Kein Backfill, keine Schätzung.

`RecordingStore.saveDictation` (`:107`) bekommt die Parameter mit Defaults, damit
bestehende Aufrufer/Tests unverändert bleiben. Die Werte liegen im `DictationController`
bereits vor: `lastLatencyMs` (`:25`), der gewählte Engine-Zweig (`:341–346`), die
Ziel-App (`targetBundleID`, heute schon für `AppCategory` ermittelt, `:357`).

**Datenschutz:** Die Bundle-ID bleibt lokal in SQLite und geht nie in einen Prompt oder
eine Anfrage. Sie ist bereits Teil des Diktatpfads (`AppCategory`), also keine neue
Datenklasse — nur eine, die jetzt persistiert wird. Ein Schalter „App-Statistik
erfassen" (Default an) gehört trotzdem in die Einstellungen, plus ein Knopf, der die
Spalte leert.

## 3. Neue Auswertungen (alle pure in `UsageMetrics`)

### 3.1 Peak Hours — wann diktierst du?
```swift
static func hourHistogram(_ rows: [UsageRow], calendar: Calendar) -> [Int: UsageTotals]      // 0…23
static func weekdayHourMatrix(_ rows: [UsageRow], calendar: Calendar) -> [[UsageTotals]]     // 7 × 24
```
Darstellung: Heatmap 7 × 24 (`Chart` + `RectangleMark`), eine Farbe, Intensität = Wörter.
Beschriftet werden nur die Spitzenzelle und die Achsenenden — mehr wird unlesbar.
`Calendar.current.firstWeekday` respektieren (Montag).

### 3.2 Modellnutzung — womit diktierst du?
```swift
static func engineTotals(_ rows: [UsageRow]) -> [(engine: String, totals: UsageTotals)]
```
Kachel mit Anteil je Engine (Wörter und Anzahl). Zeilen ohne `engine` laufen unter
„Unbekannt" und werden **ausgewiesen**, nicht verteilt.

### 3.3 Modell-Leistung — wie schnell ist welche Engine?
```swift
struct LatencyStats: Sendable { var p50: Double; var p95: Double; var count: Int }
static func latency(_ rows: [UsageRow], by engine: String) -> LatencyStats?
static func wordsPerMinute(_ rows: [UsageRow]) -> Double     // gesprochene Wörter/Minute Aufnahme
```
Median + p95, **nie** der Mittelwert — ein einzelner Kaltstart (Modell laden) verzerrt
den Mittelwert um Sekunden. Zeilen mit `NULL` fließen nicht ein; steht weniger als 10
Messungen zur Verfügung, zeigt die Karte „zu wenig Daten" statt einer Zahl.

### 3.4 Ziel-Apps — wohin diktierst du?
```swift
static func appTotals(_ rows: [UsageRow], limit: Int = 5) -> [(sourceApp: String, totals: UsageTotals)]
```
Top 5 mit App-Icon (`NSWorkspace.urlForApplication(withBundleIdentifier:)`) und
Klartextnamen; Rest als „Weitere".

### 3.5 Trend / Streak
```swift
static func streak(_ buckets: [UsageBucket], today: Date) -> Int      // Tage in Folge mit Aktivität
```
Eine Zeile im Hero („7 Tage in Folge"), kein eigenes Diagramm. `contiguous` (`:193`)
liefert die lückenlose Reihe dafür bereits.

## 4. Was unverändert bleibt

- **`UsageSummary`** (die Menüzeile) wird **nicht** erweitert. Sie ist eine Zeile, sie
  wird gepusht (`.menu`-MenuBarExtra hat kein brauchbares `onAppear`, siehe `CLAUDE.md`),
  und jede Zusatzzahl macht sie schlechter.
- **Die `billed`-Regel.** Die KI-Kachel trennt weiterhin echte API-Kosten von der
  Schattenrechnung des Max-Plans (`SummarizationUsage.billed`). Kommt Spec 15 Stufe 2
  dazu (lokales Modell, `billed = 0`, `cost_usd = 0`), erscheinen dessen Läufe in der
  **Anzahl**, nie in einer Summe. Beide Zahlen werden nie addiert — bis ins Label.
- Bestehende Kacheln, Charts und ihre Tests.

## 5. Aufbau der View

`StatsView` ist bereits 650 Zeilen. Die neuen Karten kommen **nicht** dazu, sondern in
einen zweiten Abschnitt „Details", eingeklappt, und jede Karte in eine eigene Datei
(`Sources/Notable/Stats/Cards/…`) — sonst ist die Datei in einem Jahr unwartbar.
`StatsModel.recompute` (`:56`) bekommt die neuen Ableitungen; es hält die Zeilen ohnehin
schon im Speicher, es fällt **kein** zusätzlicher SQLite-Roundtrip an.

Leerzustände sind Pflicht: jede Karte, deren Datenbasis `NULL` ist (also alle
Bestandsdaten), sagt „ab jetzt wird gemessen" statt eine leere Fläche zu zeigen.

## 6. Tests (`UsageMetricsTests`)

- `hourHistogram`: Zeile um 23:50 mit 20 min Dauer zählt in die **Startstunde** (Regel
  festlegen und testen, nicht implizit lassen)
- `weekdayHourMatrix`: Wochenbeginn Montag, 7 × 24 immer voll besetzt
- `latency`: p50/p95 gegen bekannte Reihen; < 10 Messungen ⇒ `nil`
- `engineTotals` / `appTotals`: `NULL` landet in „Unbekannt", nichts geht verloren
  (Summe der Gruppen == Gesamtsumme)
- `streak`: heute ohne Aktivität bricht die Serie nicht (bis Mitternacht), gestern ohne schon
- Regression: `totals`, `buckets`, `menuLine` liefern mit erweiterten Zeilen identische Werte

## 7. Abnahme

- [x] Diktate ab dem Update tragen Engine, Latenz und Ziel-App; alte Zeilen bleiben gültig
      (alle Spalten nullable, kein Backfill — Bestandsdaten laufen als „Unbekannt" in
      einer eigenen Zeile, statt der aktuellen Engine zugeschlagen zu werden)
- [x] Heatmap, Modellnutzung, Modell-Leistung, Top-Apps und Streak in „Details"
- [x] Menüzeile und bestehende Kacheln unverändert (`menuLine` liefert für eine Zeile mit
      und ohne die neuen Felder identischen Text)
- [x] Keine der neuen Karten rechnet in der View
- [x] Kein zusätzlicher SQLite-Roundtrip — alles aus den Zeilen, die ohnehin im Speicher
      liegen

**Zwei Formsachen:** `usageRows` liefert eine Struktur statt eines Tupels (mit vier
weiteren Feldern wäre es ein Acht-Element-Tupel geworden), und die Spalte `enhanced`
existiert wie spezifiziert — sie wird seit #1 Stufe 2 auch gesetzt.

Latenz wird als Median und p95 ausgewiesen, nie als Mittelwert: neun schnelle Läufe plus
ein Kaltstart ergäben einen Mittelwert von ~600 ms, der keinen einzigen davon beschreibt.


