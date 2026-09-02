# Spec 04 — Voice-Commands & Text-per-Stimme bearbeiten

> **Aufwand: L.** Ein Kommando-Modus: markierten Text per Stimme umschreiben —
> „mach das förmlicher", „übersetze ins Englische", „als Bulletliste".
> Das anspruchsvollste Feature — es greift in den heißen Diktatpfad ein und liest die
> aktuelle Selektion der Ziel-App. Deshalb strikt additiv und hinter einem eigenen Modus.

> ## ⛔ BLOCKIERT durch die Datengrenze
>
> Dieser Modus schickt **markierten Text und den Sprachbefehl an einen LLM-Anbieter**
> (Anthropic/CLI). Das ist genau das, was die Festlegung „**Diktat-/eingegebener
> Text darf das Gerät nicht verlassen**" untersagt — hier verließe sogar *fremder,
> markierter* Text die Maschine. **In der Cloud-Form wird diese Spec nicht gebaut.**
>
> Der einzige zulässige Weg wäre ein **lokales LLM** (Ollama, Someday-Roadmap): dann läuft
> die Reformulierung on-device und nichts verlässt das Gerät. Bis ein lokales Modell
> existiert, ist Spec 04 **zurückgestellt**. Der übrige Entwurf (Selektion lesen/ersetzen,
> Hotkey-Modus, Zustandsmaschine) bleibt als Bauplan gültig und ist dann sofort
> wiederverwendbar — nur der Provider-Aufruf wird durch das lokale Modell ersetzt.
>
> **Status: DEFERRED — wartet auf lokales LLM.** Nicht in dieser Welle umsetzen.

## 1. Ziel

Ein zweiter Diktat-Modus **„Befehl"** neben dem normalen Diktat:

- **Selektion umschreiben:** Nutzer markiert Text in einer beliebigen App, hält die
  **Befehl-Taste**, sagt „mach das kürzer" / „formeller" / „ins Englische" / „als
  Aufzählung" → die Markierung wird durch das Ergebnis ersetzt.
- **Freies Kommando ohne Selektion:** „schreibe eine Absage an den Termin" → generierter
  Text wird an der Cursorposition eingefügt.

Heute fügt Diktat nur transkribierten Text ein; es gibt keine Kommando-Grammatik und kein
Lesen der Selektion.

## 2. Architektur-Kern: Selektion lesen & ersetzen

Der knifflige Teil ist **nicht** das LLM, sondern das robuste Lesen/Ersetzen der Auswahl
in einer fremden App. Zwei Wege, in dieser Reihenfolge versuchen:

### Weg A — Accessibility API (bevorzugt, verlustfrei)
Notable hat bereits Accessibility (für die Paste-Mechanik). Über `AXUIElement`:

1. `AXUIElementCreateSystemWide()` → fokussiertes Element (`kAXFocusedUIElementAttribute`).
2. `kAXSelectedTextAttribute` lesen → die Markierung als String.
3. Nach LLM: `kAXSelectedTextAttribute` **setzen** ersetzt die Auswahl direkt — sauber,
   ohne Zwischenablage-Tricks.

Funktioniert in den meisten nativen Textfeldern. **Scheitert** bei Electron/Web-Views, die
AX unvollständig implementieren.

### Weg B — Clipboard-Fallback (wie die bestehende Paste-Mechanik)
Wenn AX keine Selektion liefert:

1. Alten Clipboard-Inhalt sichern (wie `Paster` es tut).
2. Synthetisiertes **⌘C** → Selektion in die Zwischenablage.
3. Text lesen; nach LLM synthetisiertes **⌘V** zum Ersetzen; alten Inhalt wiederherstellen.

Das ist genau das Muster, das `Paster` schon beherrscht (Save/Restore + synthetisches ⌘V,
600 ms Restore-Delay für Electron) — wiederverwenden, nicht neu bauen. `Paster` um ein
`copySelection() -> String?` und ein `replaceSelection(with:)` erweitern.

**Wenn beide Wege keine Selektion finden** → als *freies Kommando ohne Selektion* behandeln
(§1, Fall 2) oder sichtbar melden „Keine Auswahl gefunden". Nie stumm nichts tun.

## 3. Kommando erkennen

Kein starres Grammatik-Parsing. Der Ablauf:

1. Befehl-Taste gehalten → aufnehmen → ASR → **Kommando-Text** (z. B. „mach das förmlicher").
2. Kommando-Text + (falls vorhanden) Selektion → `SummarizationProvider.complete(system:user:)`.

System-Prompt (pur, getestet, in `CommandPrompt`):

```
Du bist ein Text-Editor-Assistent. Der Nutzer gibt einen kurzen Sprachbefehl und (optional)
einen markierten Text. Führe den Befehl aus und gib AUSSCHLIESSLICH den neuen Text zurück —
keine Erklärung, keine Anführungszeichen, kein Vorwort. Behalte die Sprache des Textes bei,
außer der Befehl verlangt eine Übersetzung. Wenn kein Text markiert ist, erzeuge den vom
Befehl gewünschten Text.
```

`user` = „Befehl: <kommando>\n\nMarkierter Text:\n<selektion>" (oder „(kein markierter
Text)"). Die reine Roundtrip-Antwort ersetzt die Selektion.

**Warum LLM statt fester Kommandos:** offene Sprache („mach das freundlicher, aber behalte
die Zahlen") ist mit Regeln nicht abzudecken; der Provider ist schon da. Ein paar häufige
Kommandos könnten regelbasiert abgekürzt werden (z. B. reine Groß/Kleinschreibung) — v2
macht das **nicht**, hält es einheitlich über den Provider.

## 4. Hotkey / Modus

Der Befehl-Modus braucht eine **eigene Auslösung**, sonst kollidiert er mit normalem Diktat.
Optionen:

- **Empfohlen:** zweite konfigurierbare Taste („Befehl-Taste"), analog zur bestehenden
  Push-to-talk-Taste (`HotkeySpec`, `HotkeyMonitor`). Default z. B. rechte ⌘-Taste, wenn
  Diktat auf rechter ⌥ liegt.
- Alternativ: Modifier-Kombi auf derselben Taste (⌥ = Diktat, ⌥⇧ = Befehl) — feiner, aber
  im listen-only-Tap schwerer sauber zu erkennen. In v2 die separate Taste nehmen.

`HotkeySpec` um Befehl-Varianten erweitern; `HotkeyMonitor` kann bereits mehrere
Taps/Keys — ein zweiter Modus-Callback (`onCommandKeyDown/Up`) parallel zum Diktat.
Das Overlay bekommt einen **Befehl-Zustand** (anderes Icon/Text: „Befehl aufnehmen…",
„Bearbeite Auswahl…").

## 5. Ablauf (Zustandsmaschine)

```
idle → (Befehl-Taste down) recordingCommand → (up) transcribingCommand
     → readingSelection → llmEditing → replacing → idle
```

- Selektion **vor** dem LLM-Call lesen (Weg A/B), damit der Fokus noch stimmt.
- Während `llmEditing` Overlay „Bearbeite Auswahl…"; kein Fokusklau (Overlay bleibt
  non-activating, sonst bricht das Ersetzen).
- Ersetzen über AX-Set oder ⌘V-Fallback.
- Abbruch (Esc) in jedem Zustand möglich; bei Fehler/Timeout **Selektion unangetastet
  lassen** und sichtbar melden — niemals halb ersetzen.

Dieser Modus lebt sinnvoll in einem eigenen `CommandController` (analog
`DictationController`), der Recorder/ASR mit dem Diktatpfad teilt, aber die
Selektions-/Ersetzungslogik kapselt.

## 6. Edge Cases (hier besonders wichtig — es verändert fremden Text)

- **Keine Selektion:** freies Kommando **oder** klare Meldung — konfigurierbar, Default
  „freies Kommando einfügen".
- **AX read/set schlägt fehl:** Clipboard-Fallback; scheitert auch der → Meldung, nichts
  ersetzen.
- **Sehr große Selektion:** Kontextgrenze prüfen; über Schwelle warnen statt abschneiden.
- **LLM antwortet leer / mit Erklärung statt Text:** Antwort trimmen; wenn verdächtig
  (enthält „Hier ist…") → nicht ersetzen, melden. Der Prompt beugt vor, die Prüfung
  sichert ab.
- **Provider nicht verfügbar:** Modus meldet „Befehl braucht einen Zusammenfassungs-Anbieter
  (Settings)". Kein stiller Fallback.
- **Ersetzen in Passwortfeldern / gesperrten Feldern:** AX meldet nicht-editierbar → nicht
  ersetzen.
- **Timing/Restore:** den 600-ms-Electron-Restore-Delay aus `Paster` respektieren.

## 7. Datenschutz

Wie Spec 03 Stufe B: Beim Befehl-Modus verlässt **diktierter/markierter Text** das Gerät
(zum Provider). Das ist eine bewusste Erweiterung gegenüber „nur Meeting-Summaries". In der
Onboarding-/Settings-UI klar sagen. Audio bleibt lokal.

## 8. Tests

- `CommandPrompt` (pur): mit/ohne Selektion; Sprache-behalten-Regel im Prompt.
- Antwort-Sanitizing (pur): trimmt Anführungszeichen/Vorworte; erkennt „leer"/„Erklärung".
- `Paster.copySelection/replaceSelection`: Save/Restore-Clipboard-Invarianten (wie
  bestehende Paster-Logik testbar mit Fake-Pasteboard).
- `CommandController`-State-Flow mit Fake-Provider & Fake-Selektionsquelle: Fehler lässt
  Selektion unangetastet; Abbruch in jedem Zustand.
- AX-Wege sind schwer unit-testbar → hinter ein `SelectionAccess`-Protokoll (real +
  fake) legen; manuell in TextEdit/Mail/Slack/Xcode verifizieren (verify-Skill / echte Apps).

## 9. Umsetzungsschritte

1. `SelectionAccess`-Protokoll: AX-Read/Set + Clipboard-Fallback; `Paster`-Erweiterung.
2. `CommandPrompt` + Antwort-Sanitizing (pur) + Tests.
3. Zweiter Hotkey (`HotkeySpec`/`HotkeyMonitor`-Callbacks) + Overlay-Befehl-Zustand.
4. `CommandController` (Zustandsmaschine, teilt Recorder/ASR).
5. Ende-zu-Ende in echten Apps verifizieren (nativer AX-Pfad **und** Electron-Fallback).
6. Settings: Befehl-Taste, Datenschutz-Hinweis, „keine Auswahl"-Verhalten.

## 10. Nicht-Ziele

- Keine Undo-Integration in die Ziel-App (macOS bietet keinen verlässlichen Hook — wie bei
  Diktat-Undo bewusst nicht vorgetäuscht; der Nutzer hat ⌘Z der App).
- Keine Multi-Step-Agenten („und dann verschicke es") — ein Kommando, eine Ersetzung.
- Keine App-spezifischen Kommando-Grammatiken.
