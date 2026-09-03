# Notable

Lokale Diktat- und Meeting-Transkription für macOS. Menüleisten-App, Apple Silicon,
macOS 14.4+.

<p align="center">
  <img src="docs/images/dictation.gif" width="640" alt="Die Diktat-Anzeige: eine kleine dunkle Kapsel mit laufender Wellenform, danach „Transkribiere…“">
</p>

**Audio verlässt das Gerät nie.** Das ist Architektur, kein Schalter: Erkennung,
Segmentierung und Diarisierung laufen vollständig auf der Neural Engine. Nach außen geht
ausschließlich Text, und auch das nur an den Stellen, die unten benannt sind.

> In English: [README.md](README.md)

Die Oberfläche gibt es auf Deutsch und Englisch; sie folgt der Systemsprache und
lässt sich in den Einstellungen fest auf eine der beiden stellen.

## Zwei Modi, ein Kern

**Diktat.** Hotkey halten, sprechen, loslassen — der polierte Text landet im fokussierten
Feld. Kurz antippen schaltet freihändig, der nächste Tipp beendet. Warm gemessen: 5 s
Audio → ~119 ms, 60 s → ~397 ms; lange Diktate dekodieren inkrementell mit, so dass beim
Loslassen nur noch der Rest zu tun ist.

- Parakeet TDT v3 (mehrsprachig, Standard) oder Parakeet Unified (Englisch, echtes
  Streaming); Whisper als Vergleichsoption
- Regelbasierte Nachbearbeitung: Füllwörter, Zahlen und Daten, persönliches Wörterbuch,
  Absätze und gesprochene Struktur-Kommandos („neue Zeile", „Stichpunkt", „erstens…")
- **Textbausteine**: gesprochene Kürzel expandieren zu beliebigem, auch mehrzeiligem Text
- Aufnahme-Anzeige an der Notch, als Pille unter der Menüleiste, unten mittig — oder aus

**Meetings.** Mikrofon und System-Audio getrennt aufgezeichnet (CoreAudio Process Tap),
Sprecher getrennt, dem Kalendertermin zugeordnet, als Markdown-Notiz in einem Ordner
abgelegt, der dir gehört.

- Automatische Erkennung von Zoom, Teams, FaceTime, Webex, Slack und Browser-Calls —
  aufgezeichnet wird erst nach ausdrücklicher Bestätigung
- Live-Notizen während des Calls in einem schwebenden Fenster (WYSIWYG-Markdown), die
  wörtlich in die Notiz übernommen und in die Zusammenfassung eingewoben werden
- Sprecher-Benennung aus den Kalender-Teilnehmern
- Zusammenfassung, Chat mit dem Transkript und lokale Volltextsuche

## File over app

Jedes Meeting wird eine Markdown-Datei in einem Ordner, den **du** aussuchst — reiner Text
mit YAML-Frontmatter, eine Datei pro Notiz. Es gibt keine Datenbank, aus der man erst
exportieren müsste, und kein eigenes Format, in dem etwas festsitzt. Notable läuft ohne
Sandkasten, der Ordner darf also ein Obsidian-Vault sein, ein Git-Repository, ein
synchronisierter Ordner — was immer du ohnehin benutzt.

Die Notizen überleben die App. Das automatische Aufräumen fasst ausschließlich Notables
eigenen Audio-Spool an und löscht nie eine Notiz. Wirf Notable weg, und jede Notiz liegt
weiter da, lesbar in jedem Editor auf jedem Rechner.

Eine Richtung, klar gesagt: Notable *schreibt* diese Dateien, es liest deine Änderungen
daran nicht zurück. Für Suche, Chat und das Neu-Erzeugen einer Notiz bleibt die eigene
Datenbank die Quelle — die Markdown-Datei ist das Exemplar, das dir gehört, nicht ein
zweiter Eingang.

## Was das Gerät verlässt

| Daten | Verlassen das Gerät |
|---|---|
| Audio | **nie** |
| Meeting-Transkripte | für Zusammenfassung, Sprecher-Benennung und Chat |
| Diktattext | **nur auf ausdrücklichen Abruf** — eigener Hotkey oder Menüpunkt |

Die automatische Nachbearbeitung nach jedem Diktat ist offline und regelbasiert. Die
LLM-Verbesserung ist ein eigenes, standardmäßig ausgeschaltetes Feature; solange der
Schalter aus ist, wird der zweite Hotkey nicht einmal installiert. Jeder Lauf wird
mitgezählt, damit nachvollziehbar bleibt, wie oft Diktattext das Gerät verlassen hat.

Als Anbieter stehen die Anthropic API (Schlüssel im Schlüsselbund) und die lokal
installierten CLIs Claude Code, Gemini CLI und Codex CLI zur Auswahl. Für den Diktatpfad
sind ausschließlich die CLIs zugelassen. Zur Klarstellung: eine CLI ist **nicht lokal** —
sie ist ein lokal gestarteter Prozess, der Text an ihren Anbieter schickt.

## Berechtigungen

Notable fragt genau das ab, was es braucht, und erklärt jede Anfrage vorher in der
Einführung:

| Recht | Wofür |
|---|---|
| Mikrofon | Diktat und die eigene Spur im Meeting |
| System-Audio-Aufnahme | die andere Seite des Calls (eigenes TCC-Recht, nicht Bildschirmaufnahme) |
| Kalender (lesend) | Aufnahmen dem passenden Termin zuordnen |
| Bedienungshilfen + Eingabeüberwachung | globaler Hotkey und Einfügen ins fokussierte Feld |

## Bauen und installieren

Voraussetzung: Xcode und [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). Das Xcode-Projekt wird generiert und ist nicht eingecheckt.

```sh
xcodegen generate
scripts/install.sh          # Release bauen und nach /Applications installieren
```

Zum Signieren `Signing/Local.xcconfig.example` nach `Signing/Local.xcconfig`
kopieren und die eigene Apple Team ID eintragen (die Datei ist gitignored).

Für einen Entwicklungslauf:

```sh
DD="$TMPDIR/notable"
xcodebuild -project Notable.xcodeproj -scheme Notable -configuration Debug \
  -derivedDataPath "$DD" build
open "$DD/Build/Products/Debug/Notable.app"
```

Tests — sie brauchen das App-Modul im selben Ableitungspfad, also erst bauen:

```sh
xcodebuild -project Notable.xcodeproj -scheme Notable -configuration Debug \
  -derivedDataPath "$DD" test
```

Ein Teil der Tests lädt beim ersten Lauf echte Modelle von HuggingFace (danach
zwischengespeichert); der komplette Durchlauf dauert rund neun Minuten.

**Nicht in den Repo-Ordner bauen**, wenn er synchronisiert wird (iCloud Drive,
Dropbox): der File Provider hängt dem Build-Produkt erweiterte Attribute an, und
`codesign` bricht dann mit `resource fork, Finder information, or similar detritus
not allowed` ab — ein Fehler, der wie alles aussieht, nur nicht wie seine Ursache.

**Installiert wird nach `/Applications`**, weil macOS die erteilten Rechte an den
Bundle-Pfad *und* an die Signatur bindet. Ein Wechsel der Signier-Identität setzt alle
Rechte still zurück — der Haken in den Systemeinstellungen sieht danach weiter gesetzt
aus, protokolliert wird nichts. `project.yml` trägt das Symptom und das Gegenmittel
direkt an der Einstellung.

## Aufbau

- `Sources/Notable/Dictation/` — der latenzkritische Pfad: Hotkeys, Aufnahme, ASR,
  Nachbearbeitung, Overlay, Einfügen
- `Sources/Notable/Meeting/` — System-Audio-Tap, Call-Erkennung, Pipeline, Live-Notizen
- `Sources/Notable/Storage/` — SQLite (WAL) als Quelle der Wahrheit, Markdown als
  Projektion, Aufbewahrungsregeln
- `Sources/Notable/Summarization/` — Anbieter-Protokoll, API- und CLI-Anbieter
- `Sources/Notable/Stats/` — Auswertung der eigenen Nutzung
- `specs/` — die Entwurfsdokumente hinter den Features ([Index](specs/README.md))
- `docs/RELEASING.md` — Versionierung, Signierung, Notarisierung, Auslieferung
- `CLAUDE.md` — Arbeitsanweisungen für die Arbeit am Code

## Umfang

Notable ist für einen einzelnen Nutzer auf einer eigenen Maschine gebaut. Das ist keine
Bescheidenheitsfloskel, sondern trägt Entscheidungen: lokal gebaut und signiert statt App
Store, kein Sandkasten, keine Mehrbenutzer-Verwaltung, keine Synchronisierung.

## Lizenz

MIT — siehe [LICENSE](LICENSE).
