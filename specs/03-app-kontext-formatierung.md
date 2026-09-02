# Spec 03 — App-kontextabhängige Formatierung

> **Aufwand: M.** Erkennt die fokussierte App und passt Ton und Format an — knappe
> Chat-Nachricht vs. formelle Mail vs. Code-Kommentar.
> Greift am Ende des Diktatpfads an (`DictationController.finishRecording`), **nach** der
> ASR, um die Latenz der Transkription nicht anzufassen.
>
> **Datengrenze: Diktattext verlässt das Gerät nicht automatisch.**
> Deshalb ist diese Spec **rein offline/regelbasiert**. Die ursprünglich erwogene
> „Stufe B" (KI-Reformatierung über Anthropic/CLI) ist **gestrichen**, weil sie diktierten
> Text an einen Anbieter senden würde. Ein späterer LLM-Feinschliff wäre nur mit einem
> **lokalen** Modell (Ollama, Someday-Roadmap) denkbar — dann als separate Spec.

## 1. Ziel

Der eingefügte Text passt sich der **Ziel-App** an — **komplett lokal, latenzfrei**:

- **Slack / Messages / WhatsApp:** knapp, locker, Kleinschreibung ok, keine Anrede-Floskeln.
- **Mail / Outlook:** vollständige Sätze, saubere Groß-/Kleinschreibung, Satzendpunkt.
- **Code-Editoren (Xcode, VS Code, Terminal):** wörtlich, keine „Verschönerung", keine
  Auto-Interpunktion, Fachbegriffe unangetastet.
- **Notizen/Dokumente (Notes, Word, Pages):** Standard-Prosa (heutiges Verhalten).
- **Unbekannt:** heutiges Standard-Polishing.

Heute ist das Polishing uniform (`TextPolisher.polish(text, options: .fromDefaults())`,
`DictationController.swift:323`). Diese Spec macht es **kontextabhängig** — durch andere
Parameter derselben `TextPolisher`-Pipeline, ohne Netzwerk, ohne Zusatzlatenz.

## 2. Kernmechanik: Polishing-Profile

Pro App-Kategorie ein **Polishing-Profil**, das die bestehenden `TextPolisher`-Optionen und
ein paar neue Schalter setzt. Kein LLM, kein Netzwerk, keine Zusatzlatenz.

```swift
struct PolishProfile {
    var removeFillers: Bool
    var applyITN: Bool
    var capitalizeSentences: Bool
    var enforceFinalPunctuation: Bool   // Satzpunkt ergänzen (Mail) / nie (Code)
    var lowercaseStart: Bool            // Chat: kleinschreiben erlauben
    var verbatim: Bool                  // Code/Terminal: nur Wörterbuch, sonst roh
}
```

Zuordnung Kategorie → Profil in einer **puren, getesteten** Tabelle. Die Kategorie kommt
aus der Bundle-ID der fokussierten App (§3). Wichtig: Das **Default-Profil (`unknown`) muss
byte-genau dem heutigen Polishing-Verhalten entsprechen**, damit nichts regressiert.

## 3. Fokussierte App ermitteln

`NSWorkspace.shared.frontmostApplication?.bundleIdentifier` — **zum Zeitpunkt des
Diktat-Endes** (in `finishRecording`, bevor die Task startet), nicht beim Einfügen. Das
Overlay ist non-activating, der Fokus bleibt beim Zielprogramm; den Wert trotzdem früh
einfrieren, damit ein zwischenzeitlicher App-Wechsel nichts verfälscht.

Kategorisierung als pure Funktion `AppCategory.of(bundleID:)`:

```swift
enum AppCategory { case chat, mail, code, prose, unknown }
```

Start-Mapping (erweiterbar, wie die Meeting-Bundle-Liste in `MeetingDetector`):

- **chat:** `com.tinyspeck.slackmacgap`, `com.apple.MobileSMS`, `net.whatsapp.WhatsApp`,
  `com.hnc.Discord`, `org.telegram.desktop`.
- **mail:** `com.apple.mail`, `com.microsoft.Outlook`, `com.readdle.smartemail-Mac` (Spark).
- **code:** `com.apple.dt.Xcode`, `com.microsoft.VSCode`, `com.googlecode.iterm2`,
  `com.apple.Terminal`, JetBrains-IDs.
- **prose:** `com.apple.Notes`, `com.microsoft.Word`, `com.apple.iWork.Pages`, Obsidian, Bear.
- **unknown:** alles andere → heutiges Standard-Profil.

Die Liste ist **nutzer-einsehbar und ergänzbar** (siehe §5).

## 4. Integration in den Diktatpfad

In `finishRecording` (`DictationController.swift:317–355`), minimal-invasiv und **ohne**
zusätzlichen await/Netzwerk:

```swift
let targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier   // früh einfrieren
…
let text = try await rawTranscript(samples: samples, sampleRate: sampleRate)
let category = AppCategory.of(bundleID: targetBundleID)
let profile = PolishProfile.for(category)
let polished = TextPolisher.polish(text, options: profile.asPolishOptions())     // rein lokal
```

- `source_app` (Bundle-ID) kann bei `saveDictation` mitgespeichert werden
  (`recordings.source_app TEXT`, gleiche Migration wie Spec 01) — ermöglicht später
  „Wörter pro App"-Statistik quasi geschenkt. Der Bundle-Identifier ist ein lokaler
  Metadatenwert, verlässt das Gerät nicht.
- Latenz bleibt praktisch unverändert (die Profile schalten nur Regeln der bestehenden
  Pipeline um).

## 5. UI

Settings → Diktat, neuer Abschnitt **„App-Anpassung"**:

- Toggle **„Text an die Ziel-App anpassen"** (Default AN — offline & schnell).
- Tabelle **Kategorie → App** (wie das persönliche Wörterbuch): vorbelegte Zuordnungen,
  Nutzer kann Apps hinzufügen/umkategorisieren. Bundle-ID einer laufenden App per Picker
  wählbar (aus `NSWorkspace.shared.runningApplications`), damit niemand Bundle-IDs tippen muss.
- Pro-Kategorie-Vorschau, was das Profil tut (z. B. „Code: wörtlich, keine Interpunktion").

## 6. Edge Cases

- **Kein Frontmost / Notable selbst im Fokus:** `unknown` → Standardprofil.
- **Browser:** Bundle-ID ist der Browser, nicht die Web-App — v2 behandelt Browser als
  `prose`/`unknown`. (Feiner: aktive Tab-URL wie in `MeetingDetector` lesen — bewusst
  **out of scope** für v2.)
- **Verbatim-Modus (Code):** überschreibt Füllwort-Entfernung/ITN — der Nutzer will genau
  das, was er sagt. Wörterbuch bleibt aktiv (Namen/Fachbegriffe).
- **Default-Profil == heutiges Verhalten:** hart per Test abgesichert (§7).

## 7. Tests

- `AppCategory.of(bundleID:)`: bekannte IDs → richtige Kategorie; unbekannt → `unknown`;
  Nutzer-Override greift.
- `PolishProfile.for(_:)` + `asPolishOptions()`: Code-Profil deaktiviert ITN/Filler und
  setzt `verbatim`; Mail-Profil setzt Endpunkt; Chat-Profil erlaubt Kleinstart.
- `TextPolisher` mit Profil-Optionen: verbatim lässt Zahlwörter stehen; Mail ergänzt Punkt;
  **bestehende Polishing-Tests bleiben grün** (Default-Profil == heutiges Verhalten).

## 8. Umsetzungsschritte

1. `AppCategory` + Mapping (pur) + Tests.
2. `PolishProfile` + `TextPolisher.Options`-Erweiterung (verbatim, enforceFinalPunctuation,
   lowercaseStart) + Tests; sicherstellen: Default-Profil == heutiges Verhalten.
3. `finishRecording`: Frontmost früh einfrieren, Profil anwenden. `source_app` speichern.
4. Settings-UI (Toggle + Kategorie-Tabelle mit App-Picker).

## 9. Nicht-Ziele

- **Keine KI-Reformatierung von Diktat-Text** — gestrichen durch die Scope-Entscheidung
  (Diktat-Text bleibt lokal). Ein lokales-LLM-Variante wäre eine separate, spätere Spec.
- Keine Web-App-Erkennung per Tab-URL in v2 (Browser = eine Kategorie).
- Keine frei definierbaren Prompts pro App.
