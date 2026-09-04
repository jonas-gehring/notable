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

## Stufe 4 — Veröffentlichung, Onboarding, Zweisprachigkeit

Das Repository ist öffentlich, `v1.0.0` ist geschnitten (Developer-ID-signiert, **nicht**
notarisiert — die Release-Notes sagen das und nennen beide Auswege). Damit funktioniert
auch der Auto-Update-Pfad zum ersten Mal wirklich.

- **Onboarding fragte die falsche Berechtigung ab.** Der Meeting-Tap braucht
  „Systemaudio-Aufnahme"; geprüft und verlinkt wurde die Bildschirmaufnahme. Details und
  warum der Status bewusst als *nicht auslesbar* angezeigt wird, stehen in `CLAUDE.md`
  unter `Permissions/`. Dazu: Überspringen-Knopf, klickbare Seitenpunkte, die
  Mitteilungen-Berechtigung wird erfragt, und die Provider-Seite warb nicht mehr mit
  einem Abo-Namen, den es so nicht mehr gibt.
- **Update-Pfad**: Release-Notes werden gerendert statt roh angezeigt (`ReleaseNotes` —
  Blockebene selbst, Inline-Ebene dem Parser, weil beide Bordmittel allein falsch sind),
  Download mit Prozentanzeige, eine gefundene Version wird einmal gemeldet statt nur im
  Menü zu warten, einzelne Versionen lassen sich überspringen, die Automatik abschalten.
- **Zweisprachig (de/en) mit Umschalter.** Die deutschen Literale sind die Schlüssel;
  `en.lproj` übersetzt sie. Die beiden Fallen — nur `LocalizedStringKey` wird
  nachgeschlagen, und interpolierte Schlüssel tragen `%lld` statt `%@` — stehen in
  `CLAUDE.md`. `LocalizationTests` ist der Wächter, weil eine fehlende Übersetzung
  nichts meldet, sondern einfach deutsch bleibt.

### Stufe 5 — Code-Review vom 3. September 2026 umgesetzt

Grundlage ist `docs/code-review-2026-09-03.md` (fünf Bereiche, rund 95 Befunde). Die
Punkte, deren Fehlermodus still war — die also niemand gemeldet hätte:

- **Datenschutz.** `claude -p` schrieb jedes Transkript zusätzlich nach
  `~/.claude/projects/`; `--no-session-persistence` beendet das. System- und
  Nutzer-Turn sind getrennt (`--system-prompt` bzw. beschriftete Blöcke), und beide
  System-Prompts sagen jetzt ausdrücklich, dass Transkript-Inhalt Material ist und
  niemals Anweisung.
- **Updater.** Der Download wird gegen die Team-ID der laufenden App geprüft, bevor
  irgendetwas ausgetauscht wird; das Swap-Skript bricht ab statt eine laufende App
  auszuweiden; ⌘Q und die Update-Installation beenden ein laufendes Meeting sauber,
  statt es der Absturz-Wiederherstellung zu überlassen. Neu: Updates installieren
  sich selbst, wenn nichts dabei verloren geht (kein Meeting, kein offenes Fenster).
- **Echtzeit-Audio.** Der CoreAudio-IO-Proc konvertierte, sperrte und schrieb auf die
  Platte — auf dem Thread mit Puffer-Deadline. Jetzt kopiert er nur noch in einen
  vorallokierten Ring; alles andere läuft auf einem eigenen Consumer-Thread. Verworfene
  Puffer werden gezählt und gemeldet statt still zu verschwinden.
- **Aufnahme neben Verarbeitung.** `processing` blockierte die nächste Aufnahme, und das
  einmalige `.started` des Detektors für den Folge-Call verpuffte. Capture und
  Verarbeitung sind getrennte Zustände.
- **Speicher.** `SQLiteConnection` mit nummerierten Migrationen, Transaktionen für die
  Schreibpaare, echte Fehler statt kurzer Listen bei `SQLITE_BUSY` — und FTS5, womit
  „über" endlich „Über" findet und ein Titel-Treffer einen Treffer ergibt statt einen
  pro Segment.
- **Sprache.** Der Scanner sieht jetzt auch Enum-Labels; rund 190 deutsche Literale, die
  im englischen Fenster deutsch geblieben wären, sind übersetzt. Zusammenfassungen und
  Chat-Antworten folgen der Sprache der *Aufnahme*, nicht der der Oberfläche.
- **Notiz.** `## Teilnehmer` steht jetzt in der Datei (eingeladen laut Kalender, gehört
  laut Transkript), und die Teilnehmerliste liegt in SQLite, damit ein Umbenennen sie
  nicht wieder verliert.

## Offen

- **Sprecher-Erkennung an einem echten Call messen.** Die Diarisierung ist
  nachgeschärft (Trennschwelle 0,62 statt 0,7 auf der VAD-kompaktierten Spur,
  Mindestdauer 0,4 s, erwartete Sprecherzahl aus der Einladung) und die Namensprüfung
  ist strenger *und* großzügiger zugleich: belegt wird über den Vornamen statt über
  irgendein Token, und ein Kollege, der den Vornamen des Nutzers teilt, ist nicht
  länger dauerhaft unbenennbar. Ob das reicht, sagt erst ein echter Call.
- **Echter Call-Test gegen die 0-Segment-Aufnahme.** Echte Calls können null
  Transkript-Segmente liefern, während eine Solo-Aufnahme funktioniert; Hauptverdächtiger
  ist die Echo-Unterdrückung (VPIO) auf dem Mikrofon im Konflikt mit der Meeting-App. Der
  einzige offene Punkt, den kein Testlauf erreicht — er braucht einen echten Anruf.
  `TrackSilence` sagt eine stumme Spur inzwischen laut an, statt sie zu verschweigen.
- **`Paster` für Electron-Apps härten** (Teams/Zoom/Meet) — das Einfügen ins fokussierte
  Feld ist gebaut, aber in genau diesen Apps nicht systematisch verifiziert.
