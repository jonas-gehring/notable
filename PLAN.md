# Notable — Umsetzungsplan

> **Status 2026-07-12: vollständig umgesetzt** — alle Phasen inkl. Phase 8,
> 35 Tests, App installiert unter `/Applications/Notable.app`. Dieses Dokument
> bleibt als Bauplan-Historie stehen; der Ist-Stand steht in `CLAUDE.md`.

Stand: 2026-07-10. Dieses Dokument ist der konkrete Bauplan für v1. Es setzt die
Entscheidungen aus `CLAUDE.md` um (Personal Tool, Swift/SwiftUI, lokal signiert,
Audio bleibt auf dem Gerät) und ordnet die Arbeit in Phasen mit klaren
Abnahmekriterien. Reihenfolge ist bewusst: **Diktat zuerst** — Latenz ist das
Produkt; Meeting-Transkription baut auf demselben Kern auf.

---

## Phase 0 — Scaffold & Fundament (½–1 Tag)

**Ziel:** Eine startbare Menü-Bar-App, in der alle weiteren Phasen landen.

- Xcode-Projekt `Notable`, SwiftUI, Apple Silicon only.
- Deployment Target **macOS 14.4** (Annahme aus CLAUDE.md: erlaubt CoreAudio
  Process Taps, kein ScreenCaptureKit-Fallback nötig — *vor Phase 4 final
  bestätigen*).
- `MenuBarExtra` als App-Einstieg, `LSUIElement = YES` (kein Dock-Icon).
- Settings-Fenster (SwiftUI `Settings`-Scene) mit leeren Sektionen:
  Allgemein, Diktat, Meetings, Zusammenfassung, Berechtigungen.
- `KeychainStore`: dünner Wrapper um Security.framework für den API-Key.
- Lokales Signing-Setup dokumentieren (Personal Team reicht; Hardened Runtime
  aus, damit Event Tap & Co. nicht kämpfen).

**Fertig, wenn:** App startet, Icon in der Menüleiste, Settings öffnen sich.

---

## Phase 1 — Berechtigungs-Framework (1 Tag)

Notable braucht fünf Berechtigungen, jede mit eigenem Fehlermodus. Das wird
zentral gebaut, nicht ad-hoc pro Feature.

- `PermissionsManager` mit Status pro Berechtigung:
  Mikrofon, Bildschirmaufnahme (für System-Audio!), Input Monitoring,
  Bedienungshilfen (Accessibility), Kalender.
- Settings-Sektion „Berechtigungen": Live-Status, Button je Eintrag der direkt
  in die richtige Systemeinstellungs-Pane deeplinkt
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_…`).
- **Kein Feature darf still versagen.** Diktat ohne Accessibility zeigt einen
  Hinweis im Overlay, statt nichts zu tun (explizite Vorgabe aus CLAUDE.md).

**Fertig, wenn:** Alle fünf Status korrekt erkannt und verweigerte Zustände
sichtbar gemacht werden.

---

## Phase 2 — Diktat (Kernprodukt, 1–2 Wochen)

**Ziel:** Hotkey halten → sprechen → loslassen → Text landet im fokussierten
Feld, Ziel < 200 ms von Loslassen bis Paste.

### 2.1 Globaler Hotkey
- `CGEventTap` (Session-Level, listen-only) für Push-to-talk mit
  Modifier-Kombination; braucht Input Monitoring.
- Zustandsmaschine: idle → recording (key down) → transcribing (key up) →
  pasting → idle. Abbruchpfad (Esc / zu kurze Aufnahme).

### 2.2 Audio + VAD
- `AVAudioEngine` Mikrofon-Capture, 16 kHz mono Ring-Buffer.
- **Silero VAD** als CoreML-Modell, streaming/event-getrieben: Stille wird
  verworfen, bevor sie das ASR-Modell erreicht — das ist der größte
  Latenz-Hebel.

### 2.3 ASR
- **Parakeet TDT** via CoreML auf der Neural Engine als Default.
- `ASRModel`-Protokoll, damit Whisper-Varianten/Qwen3-ASR später als
  Setting nachrüstbar sind (alle drei Referenz-Apps behandeln das als
  First-Class-Setting).
- Modell beim App-Start warm laden, nicht beim ersten Hotkey.

### 2.4 Paste-Mechanik
- Pasteboard-Swap: alten Inhalt sichern → Transkript setzen → Cmd-V via
  `CGEvent` synthetisieren → alten Inhalt wiederherstellen. Braucht
  Accessibility.
- Overlay: **nicht-aktivierendes `NSPanel`** (`.nonactivatingPanel`),
  Aufnahme-/Transkriptions-Status. Darf nie den Fokus stehlen — sonst ist die
  Paste-Mechanik kaputt.

### 2.5 Menü-Bar-Status
- Icon trägt den Zustand (idle / recording / transcribing). Das ist die
  primäre UI, kein Beiwerk.

**Fertig, wenn:** Diktat in TextEdit, Safari-Formular und Slack funktioniert;
Latenz Loslassen→Paste unter 200 ms bei kurzen Äußerungen; verweigerte
Accessibility wird sichtbar gemeldet.

---

## Phase 3 — Speicher (2–3 Tage)

- SQLite in WAL-Mode (via `SQLite.swift` oder dünnem eigenen Wrapper):
  Aufnahmen-Metadaten, Transkript-Segmente, Speaker-Zuordnung, Meeting-Bezug.
- Markdown-Dateien in einen **vom Nutzer gewählten Ordner** als
  Projektion: eine Datei pro Meeting (Transkript + später Summary).
  Der Ordner ist die Produktoberfläche, kein Export.
- *Offene Entscheidung aus CLAUDE.md* (nur Markdown vs. SQLite+Projektion):
  Der Plan setzt auf SQLite+Projektion, weil Diarization-Segmente und
  Meeting-Verknüpfung relational sind — **vor Umsetzung bestätigen.**

**Fertig, wenn:** Eine Diktat-/Meeting-Session persistiert wird und die
Markdown-Datei im Zielordner erscheint.

---

## Phase 4 — Meeting-Transkription (2–3 Wochen)

### 4.1 System-Audio-Capture
- **CoreAudio Process Taps** (macOS 14.4+), Aufnahme der anderen Teilnehmer.
  Kein ScreenCaptureKit-Fallback, sofern das 14.4-Target bestätigt ist.
- Zwei Spuren: Mikrofon (ich) + System-Audio (die anderen) — getrennt
  aufzeichnen, das macht Diarization/Attribution massiv einfacher.
- Braucht Bildschirmaufnahme-Berechtigung; der überraschende Prompt wird in
  der Berechtigungs-UI vorab erklärt.

### 4.2 Meeting-Erkennung (Signal-Fusion, kein Prozess-Check)
- Bundle-IDs (`us.zoom.xos`, `com.microsoft.teams2`) **plus** Mikrofon-
  und Kamera-Aktivsignale; Browser-Meetings (`meet.google.com`) über einen
  separaten Collector.
- Auto-Stop als eigenes Problem behandeln (`MeetingAutoStopPolicy`).
- Manueller Start/Stop-Button im Menü als erste Ausbaustufe, Auto-Detection
  als zweite.

### 4.3 Diarization
- pyannote via CoreML, nur im Meeting-Modus (Diktat nie).
- Läuft nach der Aufnahme bzw. in Chunks während des Meetings — nicht
  gleichzeitig mit einem lokalen LLM (Speicher, siehe CLAUDE.md).

**Fertig, wenn:** Ein Zoom- und ein Meet-Call erkannt, aufgezeichnet,
transkribiert und mit Sprechern attribuiert im Markdown-Ordner landen.

---

## Phase 5 — Kalender (2–3 Tage)

- EventKit, read-only, gegen den lokalen Kalender-Store
  (*Annahme aus CLAUDE.md — bestätigen*).
- Beim Meeting-Start: laufendes/nächstes Event matchen (Zeitfenster +
  Titel-Heuristik), Aufnahme daran hängen; Meeting-Titel wird Dateiname/
  Frontmatter der Markdown-Datei.

---

## Phase 6 — Zusammenfassung: **zwei Provider, verpflichtend**

**Kernanforderung:** Es muss **beide** Wege geben, zwischen denen in den
Settings umgeschaltet wird. Nur Transkript-Text verlässt das Gerät, nie Audio
— das gilt für beide Provider gleichermaßen.

### Architektur

```swift
protocol SummarizationProvider {
    var id: String { get }                 // "anthropic-api" | "claude-code-cli"
    func isAvailable() async -> ProviderAvailability
    func summarize(transcript: String, meeting: MeetingContext) async throws -> Summary
}
```

Ein `SummarizationService` wählt den in den Settings aktiven Provider,
prüft Verfügbarkeit und schreibt das Ergebnis als Markdown-Abschnitt in die
Meeting-Datei. Prompt-Template ist provider-unabhängig (System-Prompt +
Transkript, Ausgabe: Zusammenfassung, Entscheidungen, Action Items).

### Option 1 — Anthropic API (API-Key)

- **Modell: `claude-sonnet-5`** (Entscheidung aus CLAUDE.md, Qualität auf der
  Long-Context-Achse). Preis aktuell $3/$15 pro MTok (Intro $2/$10 bis
  31.08.2026) — ein 1-h-Meeting ≈ $0.04, Kosten sind irrelevant.
- Es gibt **kein offizielles Swift-SDK** → direkter HTTP-Call via
  `URLSession`: `POST https://api.anthropic.com/v1/messages`, Header
  `x-api-key` (aus dem Keychain), `anthropic-version: 2023-06-01`.
- Sonnet-5-Besonderheiten beachten:
  - **Keine Sampling-Parameter senden** (`temperature`/`top_p`/`top_k`
    → 400). Steuerung nur über den Prompt.
  - Adaptive Thinking ist per Default an; für Summaries ok. Alternativ
    `output_config: {"effort": "low"}` für schnellere Antworten.
  - `max_tokens` ≈ 4096 reicht (Summary ~1k Tokens), non-streaming ist ok;
    Streaming optional für Fortschrittsanzeige.
  - `stop_reason` prüfen (`refusal`, `max_tokens`) statt blind
    `content[0].text` zu lesen.
- Kein Prompt Caching (Transkripte sind unique, kein wiederverwendbares
  Prefix — bestätigt).
- Key-Eingabe einmalig in den Settings, Validierung per Test-Request,
  Speicherung ausschließlich im Keychain.

### Option 2 — Claude Code CLI (headless)

**Ehrliche Einordnung zuerst:** Diese Option nutzt die **lokal installierte,
eingeloggte Claude Code CLI im Headless-Modus** — keinen API-Vertrag, sondern
ein Kommandozeilenwerkzeug, dessen Ausgabeformat sich ändern kann. Sie existiert,
weil sie ohne eigenen API-Schlüssel auskommt. Wichtig zur Klarstellung: die CLI
ist **nicht lokal** — `claude -p` ist ein lokal gestarteter Prozess, der Text an
den Anbieter schickt.

- Implementierung: `Process` spawnt
  `claude -p --output-format json` , Transkript+Prompt via stdin,
  JSON-Antwort parsen (`result`-Feld).
- Verfügbarkeitscheck: `claude` im PATH auffindbar (`/usr/local/bin`,
  `~/.local/bin`, Homebrew-Pfade absuchen — GUI-Apps erben kein Shell-PATH)
  und eingeloggt (Probe-Aufruf beim Aktivieren des Providers, Ergebnis
  cachen).
- Risiken, die die UI transparent machen muss:
  - **Kein API-Vertrag:** CLI-Flags/Output-Format können sich mit Updates
    ändern → Parser defensiv bauen, Fehler mit klarer Meldung
    („Claude Code CLI antwortet unerwartet — Update?").
  - **Geteiltes Kontingent:** Aufrufe zählen auf dieselben Limits wie
    interaktive Sessions desselben Werkzeugs. Bei Rate-Limit: Meldung +
    Angebot, auf den API-Provider auszuweichen.
  - Modellwahl liegt beim CLI/Plan (Opus/Sonnet je nach Verfügbarkeit),
    nicht bei uns — `--model` wird gesetzt, aber nicht garantiert.
- Latenz ist egal: Summarization läuft nach dem Meeting, nicht interaktiv.

### Settings & Fallback

- Picker „Zusammenfassung über": **Anthropic API (empfohlen, robust)** /
  **Claude Code CLI**. Empfehlung API als Default, weil stabiler Vertrag; die
  CLI als Alternative ohne eigenen API-Schlüssel.
- Ist der gewählte Provider nicht verfügbar (kein Key / CLI fehlt), zeigt die
  UI das an und bietet den anderen an. Kein stiller Fallback — der Nutzer
  entscheidet.
- **Ollama** bleibt Roadmap (nur Privacy-Fall), wird als dritter Provider
  hinter demselben Protokoll nachrüstbar, aber nicht in v1 gebaut.

**Fertig, wenn:** Ein reales Meeting-Transkript über beide Provider
zusammengefasst wird und das Ergebnis in der Markdown-Datei landet; beide
Fehlerpfade (fehlender Key, fehlende/ausgeloggte CLI) sauber sichtbar sind.

---

## Phase 7 — Design-Politur & Zugänglichkeit (laufend + 1 Woche am Ende)

- Native Controls & System-Materialien; Dynamic Type, Increase Contrast,
  Reduce Motion, Light/Dark — von Anfang an, kein Endspurt.
- VoiceOver-Labels auf jedem interaktiven Element, volle Tastatur-Navigation.
- Menü-Bar-Icon-Zustände final gestalten (idle/recording/transcribing).

---

## Reihenfolge & Meilensteine

| # | Meilenstein | Phasen | Nutzbar ab |
|---|---|---|---|
| M1 | Diktat steht | 0, 1, 2 | Diktat im Alltag |
| M2 | Persistenz | 3 | Verlauf im Markdown-Ordner |
| M3 | Meetings manuell | 4.1, 4.3 | Button-gestartete Aufnahme + Transkript |
| M4 | Meetings auto + Kalender | 4.2, 5 | Auto-Detection, Event-Zuordnung |
| M5 | Summaries (beide Provider) | 6 | Fertige Meeting-Notizen |
| M6 | Politur | 7 | v1 |

## Vor Baubeginn zu bestätigen (offene Entscheidungen aus CLAUDE.md)

1. **Deployment Target 14.4+** → erlaubt Streichung des
   ScreenCaptureKit-Fallbacks (Empfehlung: ja).
2. **Kalender = EventKit lokal auf macOS** (Empfehlung: ja).
3. **Transkript-Speicher**: SQLite + Markdown-Projektion wie in Phase 3
   geplant (Empfehlung: ja).

---

## Phase 8 — Diktatqualität

Gute Diktatqualität zerfällt in vier messbare Achsen; jede bekommt eine eigene
Ausbaustufe. Wichtigster technischer Befund vorab:
FluidAudios echtes Streaming-Modell (Parakeet **Unified**) ist **englisch-only**
(WER 2,2 %, 66-ms-Fenster); für Deutsch bleibt TDT v3 (batch, multilingual).
Latenz für Deutsch kommt daher aus inkrementellem Decoding, nicht aus dem
Streaming-Modell.

### 8.1 Textqualität (zuerst — sofortiger Gewinn, risikoarm)

- **`TextPolisher`**, eine pure, testbare Nachbearbeitungs-Pipeline:
  1. **Füllwort-Entfernung**, sprachbewusst: universelle Liste (ähm, äh, mhm …)
     immer; englische Füllwörter (um, uh, er …) nur bei erkannt englischem
     Text — „um" und „er" sind deutsche Wörter und dürfen nie entfernt werden.
  2. **ITN** (FluidAudio `TextNormalizer`: "two hundred fifty" → "250") — nur
     bei englischem Text, die Regeln sind englisch.
  3. **Persönliches Wörterbuch**: Ersetzungen (falsch → richtig) für Namen und
     Fachbegriffe, wortgrenzen-sicher, case-insensitiv gematcht.
  4. Whitespace-/Interpunktions-Feinschliff, Satzanfang groß.
- Settings-UI: Toggles für 1+2, editierbare Wörterbuch-Tabelle.

### 8.2 Latenz (Ziel: < 200 ms Release→Paste, erst messen, dann optimieren)

- **Instrumentierung zuerst**: keyUp→Paste-Dauer messen (ContinuousClock),
  letzte Messung sichtbar in Settings → Diktat. Warm läuft v3 mit RTF ~120x —
  bei typischen Diktaten (< 20 s) ist Ganzclip evtl. schon nahe am Ziel.
- **Inkrementelles Decoding**: während der Aufnahme alle ~2 s neue Chunks mit
  mitgeführtem `TdtDecoderState` dekodieren; beim Loslassen nur den Rest-Tail
  (< 500 ms Audio) → Latenz ≈ Tail-Inferenz. Liefert nebenbei Partial-Text
  fürs Overlay.
- **Parakeet Unified** als wählbare Engine für rein englisches Diktat
  (echtes Streaming).

### 8.3 UX-Feedback

- **Live-Pegel im Overlay** (RMS aus dem Audio-Callback) — „sie hört mich".
- **Partial-Text im Overlay** (fällt aus 8.2 ab).
- **Esc bricht ab** (Tap um keyDown erweitert; Esc wird nur während gehaltener
  Aufnahme geschluckt).
- **Lock-Modus**: Doppel-Tap = freihändige Aufnahme, erneuter Tap beendet.

### 8.4 Robustheit

- Paste-Fallback per Unicode-Typing-Injection für Apps, die ⌘V schlucken
  (Einfügemethode als Setting).
- Audio-Gerätewechsel während der Aufnahme abfangen.
- Lokales Latenz-Log (letzte N Messungen) zur Regression-Kontrolle.

**Reihenfolge:** 8.1 → Messung aus 8.2 → 8.3 (Pegel/Esc) → 8.2 inkrementell
(größter Umbau) → Lock-Modus → 8.4.
