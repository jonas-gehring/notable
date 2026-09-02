# Notable — Ausbaustufen

Kurze Chronik dessen, was nach v1 gebaut wurde, und was offen ist. Die Detail-Entwürfe
liegen als nummerierte Specs daneben (`README.md` ist der Index); `PLAN.md` ist die
v1-Bauhistorie.

## Stufe 1 — Notizverwaltung, Erkennung, Sprecher, Auslieferung

**Datenbank als Quelle der Wahrheit.** `recordings` trägt seitdem `summary`, `subtitle`,
`folder` und `title_is_auto` (idempotente `ALTER TABLE`-Migration). Eine Notiz ist
vollständig aus SQLite neu renderbar — `meeting(id:)`, `segments(for:)`,
`recentMeetings()` zum Lesen, `setSummary`/`updateTitle`/`updateLocation` zum Ändern.
`produceNote` fasst deshalb zusammen, *bevor* die eine SQLite-Zeile geschrieben wird, so
dass die Zusammenfassung im Datensatz landet. Das war die Voraussetzung für alles
Folgende: Umbenennen, Verschieben und Neu-Erzeugen laufen alle über den Store.

- **Notizverwaltung** (`note-management-ui.md`) — Notizliste im Menü, Titel bearbeiten
  (benennt die `.md` um und aktualisiert SQLite), automatischer Titel + einzeilige
  Zusammenfassung, Inbox → Projektordner, Symbolauswahl für die Menüleiste, überarbeiteter
  Summary-Prompt mit `SummaryParser`.
- **Automatische Call-Erkennung** (`auto-detect-consent.md`) — erkennt Zoom/Teams/Meet und
  zeigt einen nicht-aktivierenden Hinweis „Meeting erkannt" mit **Aufnehmen** / **Später**
  und „Für diese App merken". Aufgenommen wird nur nach ausdrücklichem Tippen oder bei
  gemerktem `.always`; das Panel wird nie key (Diktat-Paste-Garantie).
- **Sprecher-Benennung** (`speaker-naming.md`) — `SpeakerNameResolver` bildet diarisierte
  „Sprecher n" über die Kalender-Teilnehmer auf echte Namen ab, ist standardmäßig an,
  lässt Unzuordenbares in Ruhe und benennt „Ich" nie um.
- **Signierung, Versionierung, Auto-Update** (`release-and-signing.md`) — stabile
  Entwickleridentität statt Ad-hoc-Signatur (sonst behandelt TCC jeden Build als neue App),
  `scripts/release.sh` / `install.sh`, und ein leichtgewichtiges Selbst-Update:
  `UpdateChecker` fragt beim Start `releases/latest` ab (24 h gedrosselt),
  `UpdateInstaller` lädt das Release-Zip, entpackt mit `ditto` und ersetzt das laufende
  Bundle über ein abgekoppeltes Skript (Beiseiteschieben + Rollback) mit Neustart.

Ebenfalls in dieser Stufe: eigene Notizen im Meeting (verbatim `## Eigene Notizen`, in die
Zusammenfassung eingewoben), Whisper als zusätzliche Engine (WhisperKit), Transkript-
Übersicht der letzten 24 h, Diktat-Historie, echtes ITN in reinem Swift, unscharfes
Wörterbuch, Aufbewahrung des Meeting-Audios in `spool-archive/`.

## Stufe 2 — Ergonomie und Auswertung

Specs 01–08: Nutzungsstatistiken, Chat mit dem Transkript, app-kontextabhängige
Formatierung (rein offline), Live-Partial-Text, Wörterbuch-Auto-Learn, Onboarding und die
kleinen Gewinne. Spec 04 (Voice-Commands) blieb zurückgestellt — sie schickt markierten
Fremdtext raus.

## Stufe 3 — Textverbesserung, Aufbewahrung, Notch, Bausteine, Statistik

Fünf abgeschlossene Bauaufträge:

1. **Textverbesserung und Formatierung für Diktate** — Stufe 1 offline (`ParagraphFormatter`:
   Absätze, gesprochene Struktur-Kommandos), Stufe 2 per LLM **nur auf Abruf**
   (`DictationEnhancer`, `EnhancementGuard`).
2. **Aufbewahrung und Auto-Cleanup** (`RetentionPolicy`, `RetentionPlanner`,
   `RetentionRunner`) — zwei Achsen (Frist *und* Budget), gelöscht wird Text, nie eine
   Zeile, damit die Statistik nicht rückwirkend schrumpft. Automatisches Aufräumen ist
   aus, bis es eingeschaltet wird.
3. **Notch-Recorder** (`NotchGeometry`, `NotchOverlayView`) — ein Panel über die volle
   Breite mit durchsichtiger Mitte, positioniert auf dem Bildschirm unter dem Mauszeiger.
4. **Smart Replace** (`SmartReplace`) — gesprochene Kürzel expandieren zu beliebigem,
   auch mehrzeiligem Text. Bewusst **nicht** durch die unscharfe Wörterbuchsuche.
5. **Statistik-Ausbau** (`UsageMetrics` + `Stats/Cards/`) — Tageszeiten, Modellnutzung,
   Modell-Leistung, Ziel-Apps, Serien. Braucht die nullable Schema-Spalten; Bestandsdaten
   bleiben dauerhaft „unbekannt", geschätzt wird nichts.

Dazu die Nachzügler: Vorschalt-Modell und unterbrechungsfreier Modellwechsel (Spec 10),
Modell-Ergonomie am Picker und Sprachprofil (Spec 11), Medien pausieren (Spec 08 B), sowie
Gemini CLI und Codex CLI als zusätzliche Anbieter.

## Offen

- **Ein Release schneiden.** Es gibt derzeit **keins**: das alte wurde zusammen mit der
  alten Historie entfernt. Der komplette Auto-Update-Pfad ist gebaut — Prüfung beim Start
  (24 h gedrosselt), „Nach Updates suchen" in den Einstellungen und im Menü, Download,
  Austausch des laufenden Bundles, Neustart — und findet bis zum ersten Release nichts.
  Solange das Repository privat ist, findet er auch danach nichts: GitHub antwortet auf
  eine unauthentifizierte Anfrage an ein privates Repository mit 404, was von „noch nichts
  veröffentlicht" nicht zu unterscheiden ist (`UpdateChecker`, Fall 404).
- **Echter Call-Test gegen die 0-Segment-Aufnahme.** Echte Calls können null
  Transkript-Segmente liefern, während eine Solo-Aufnahme funktioniert; Hauptverdächtiger
  ist die Echo-Unterdrückung (VPIO) auf dem Mikrofon im Konflikt mit der Meeting-App. Der
  einzige offene Punkt, den kein Testlauf erreicht — er braucht einen echten Anruf.
  `TrackSilence` sagt eine stumme Spur inzwischen laut an, statt sie zu verschweigen.
- **`Paster` für Electron-Apps härten** (Teams/Zoom/Meet) — das Einfügen ins fokussierte
  Feld ist gebaut, aber in genau diesen Apps nicht systematisch verifiziert.
