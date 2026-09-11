# Spec 24 — Sprechererkennung: der Call zeigt, wer spricht

> **Aufwand: Stufe 0 = S (½ Tag Messung), Stufe 1 = S, Stufe 2 = S–M, Stufe 3 = M für
> die erste App + S je weitere, Stufe 4 = M.** **Hängt an Spec 23.**
>
> Heute rät ein Sprachmodell aus dem Gesprächstext, wer wer ist — und braucht dafür,
> dass jemand einen Namen ausspricht. Der Call selbst zeigt beides die ganze Zeit an:
> **wer teilnimmt** (Namen an den Kacheln) und **wer gerade spricht** (Hervorhebung).
> Diese Spec liest das lokal vom Bildschirm und legt es über die Zeitachse der
> Diarisierung. Das Sprachmodell bleibt Rückfallebene, die Korrektur von Hand die
> letzte Instanz.

## 1. Ausgangslage (Fakten aus SQLite und dem Code)

### 1.1 Wie es heute läuft

VAD verdichtet die Systemspur auf Sprache → pyannote-Diarisierung (FluidAudio) →
Labels `Sprecher n` (`MeetingPipeline.swift:36`, die einzige Stelle, die sie prägt) →
`SpeakerNameResolver` fragt den Zusammenfassungs-Anbieter nach einer strikten
Zuordnung und wendet nur an, was die Validierung überlebt. `Ich` ist immer die
Mikrofonspur.

### 1.2 Gemessen an den 25 Meetings in SQLite (2026-09-11)

- **Seit dem 12.08. lief die Benennung kein einziges Mal.** `produceNote` überspringt
  sie, wenn das Mikrofon stumm war (`MeetingController.swift:761`), und stumm war es
  in jedem Call (Spec 23). Das Überspringen ist richtig: ein einseitiges Transkript
  belegt meist nur den Namen, der dem Nutzer *zugerufen* wird.
- **Davor fünf Namen in zehn Meetings:** „Lukas", „Dietmar Fuchs" — und dreimal der
  eigene Name des Nutzers auf einem *entfernten* Sprecher („Gering", „Jonas",
  „Herr Gehring", 13.–27.08., alle mit stummem Mikrofon). Genau diese Umkehrung blockt
  `ownerNameTokens` inzwischen. Der Textweg liefert also selbst im guten Fall wenig.
- **`recordings.attendees` ist in keinem der 25 Meetings gefüllt**, auch nicht in denen
  nach v1.1.0, die die Spalte schon schreiben. Die Kandidatenliste ist immer leer, und
  `expectedRemoteSpeakers` liefert nie eine Zahl — die Diarisierung rät die
  Sprecheranzahl immer selbst. Ob EventKit für diese Termine keine Teilnehmer liefert
  oder der Filter (`CalendarMonitor.swift:108-125`) alle verwirft, ist **unbelegt**.
  „Jonas Gehring and Maria Wendler" trägt die zweite Person sogar im Titel.
- **Zu viele Sprecher.** „Interview with Payhawk" (54 min), laut Inhalt ein bis zwei
  Personen auf der Gegenseite:

  | Label | Beiträge | Sprechzeit | Inhalt |
  |---|---|---|---|
  | Sprecher 1 | 118 | 1178 s | Hauptgesprächspartner |
  | Sprecher 5 | 26 | 254 s | zweite Stimme |
  | Sprecher 3 | 6 | 42 s | setzt mitten im Gedanken fort, was Sprecher 5 sagt |
  | Sprecher 4 | 4 | 5 s | „Mm-hmm." … und „Thanks a lot for your time today." |
  | Sprecher 2 | 2 | 1 s | „Mm.", „And" |

- **Die Embeddings sind da und werden weggeworfen.** `TimedSpeakerSegment` trägt
  `embedding: [Float]` und `qualityScore` (FluidAudio `DiarizerTypes.swift:191-197`);
  `MeetingPipeline.process` behält nur Label und Zeiten (`:197-203`).
- **Keine Korrektur möglich.** Keine Oberfläche, keine Tabelle (grep `speaker_names`:
  nichts). Wer „Sprecher 3" von Hand im Markdown umbenennt, verliert das bei der
  nächsten Projektion aus SQLite.

### 1.3 Was für den Bildschirm-Weg schon da ist

- **Genutzte Apps** (`meetingConsentByApp`): Microsoft Teams (`com.microsoft.teams2`),
  Zoom (`us.zoom.xos`), Google Meet im Browser (`web:google-meet`).
- **Der Call-Prozess ist bekannt.** `MeetingDetector` rastet auf einen Kandidaten ein
  (`activeCandidate`, Bundle-IDs der Prozesse); das Fenster dazu ist über die PID
  auffindbar.
- **Bedienungshilfen sind bereits erteilt** — `Paster` braucht sie für das
  synthetisierte ⌘V. Das Auslesen fremder Oberflächen über `AXUIElement` kostet also
  **keine neue Berechtigung**.
- **Bildschirmaufnahme ist optional in Gebrauch**: `MeetingDetector` liest damit
  Fenstertitel (`webServiceInWindowTitles`); ohne sie trägt das still nichts bei.
- **Zwei Zeitachsen, die zusammenpassen:** die Systemspur ist wanduhrtreu
  (`padGapToWallClock` nach Gerätewechsel und Schlaf), `meta.json` trägt `startedAt`.
  Eine Beobachtung „um 10:03:14 ist Anna hervorgehoben" lässt sich also genau auf
  Sekunde 194 der Aufnahme legen.

## 2. Ziel

Jeder entfernte Sprecher trägt nach dem Meeting den Namen, den der Call selbst
angezeigt hat — **ohne** dass jemand ihn aussprechen musste. Weniger Labels, und die
richtigen. Eine Korrektur, die der Nutzer **einmal** macht, hält.

Die Haltung aus `speaker-naming.md` gilt unverändert: **ein falscher Name ist schlimmer
als `Sprecher n`.** Jede Regel unten ist so gebaut, dass sie im Zweifel anonym lässt.

## 3. Datengrenze für den Bildschirm

Gilt für alle Stufen, als Regel, nicht als Absicht:

- **Kein Bild wird gespeichert, keines verlässt das Gerät.** Ausgewertet wird im
  Arbeitsspeicher, verworfen wird sofort danach.
- Gespeichert werden **nur Namen und Zeitpunkte** (`screen.jsonl`, 3.4). Namen gehen,
  wie heute, höchstens als Teil des Transkripts an den Anbieter.
- Beobachtet wird **nur** das Fenster des erkannten Call-Prozesses und **nur**, solange
  eine Aufnahme läuft, der der Nutzer bereits zugestimmt hat.

## 4. Konzept

### 4.1 Stufe 0 — messen, bevor gebaut wird

**Welcher Weg trägt, ist je App unbekannt.** Ein halber Tag, je ein echter Call in
Teams, Zoom und Meet, mit einem Diagnose-Werkzeug (Debug-Menüpunkt, schreibt nach
`~/Library/Logs/Notable/screen-probe/`, nur Text):

| Frage | Weg A: Bedienungshilfen (`AXUIElement`) | Weg B: Texterkennung (ScreenCaptureKit + Vision) |
|---|---|---|
| Teilnehmernamen lesbar? | AX-Baum nach Kachel-Beschriftungen durchsuchen | OCR über das Fensterbild |
| „spricht gerade" erkennbar? | Attribut/Beschriftung wie „… spricht", Rolle, Wert | Rahmen/Ring in Akzentfarbe um eine Kachel, Name der großen Kachel in der Sprecheransicht |
| Kosten je Abfrage? | Baumgröße, Dauer (Budget 50 ms) | Dauer von Aufnahme + OCR (Budget 100 ms) |
| Berechtigung | vorhanden | Bildschirmaufnahme (neu, s. Risiken) |

Für Chromium und WebKit (Meet) ist der AX-Baum der Webinhalte oft erst vorhanden, wenn
eine App ihn anfordert (`AXManualAccessibility` / `AXEnhancedUserInterface` am
Browser-Prozess) — ob das ohne Nebenwirkungen im Browser geht, ist Teil der Messung.

**Ergebnis der Stufe:** eine Tabelle je App (Weg, Zuverlässigkeit, Kosten, Layouts, in
denen es nicht geht), nachgetragen in diese Spec. Zeigt keine App eine auslesbare
Hervorhebung, entfällt Stufe 3 und Stufe 2 steht allein.

Dazu die zwei Voraussetzungen von vorher:

- **Spec 23.** Ohne Mikrofonspur keine Benennung; das bleibt so. (Und ohne sie fehlt
  die Selbstprüfung aus 4.4.)
- **Kalender-Teilnehmer messen:** je Meeting ein Log-Eintrag — rohe `EKParticipant`s,
  verworfen je Grund. Das klärt §1.2, auch wenn der Bildschirm den Kalender als
  Namensquelle weitgehend ablöst.

### 4.2 Stufe 1 — Splitter auflösen (pure `SpeakerClusterCleanup`)

Unabhängig vom Bildschirm und Voraussetzung für eine saubere Zuordnung. Nach der
Diarisierung, vor `mapToOriginal`:

1. Je Cluster: Gesamtdauer und Schwerpunkt (Mittel der L2-normierten
   Segment-Embeddings, gewichtet mit `qualityScore`).
2. **Klein** ist ein Cluster, der **beides** unterschreitet: 8 s *und* 3 % der
   entfernten Sprechzeit — damit ein stiller, echter Teilnehmer nicht verschwindet.
3. Jedes Segment eines kleinen Clusters geht an den **nächsten großen** Cluster
   (Kosinus-Distanz zum Schwerpunkt), sofern die Distanz unter einer Schwelle liegt;
   sonst behält es sein Label.
4. **Zwei große Cluster werden hier nie zusammengelegt** — eine fälschlich
   verschmolzene Stimme lässt sich nicht mehr trennen (Kommentar an `diarizerConfig`).
   Zusammenlegen darf nur unabhängige Evidenz: der Bildschirm (4.4) oder der Nutzer
   (4.5).
5. Neu durchnummerieren nach erstem Auftreten.

**Die Schwellen werden gemessen:** ein standardmäßig übersprungener Test spielt
archivierte Sitzungen (`spool-archive/*/system.m4a`) durch die Pipeline und gibt die
Label-Statistik vorher/nachher aus. Payhawk ist der erste Prüffall.

### 4.3 Stufe 2 — Teilnehmer vom Bildschirm

`CallScreenObserver` läuft während der Aufnahme, sobald ein Call-Prozess bekannt ist,
auf einer eigenen Queue mit niedriger Priorität, **nie** im Aufnahmepfad. Je App ein
`CallScreenAdapter` (Teams, Zoom, Meet), der aus AX-Baum oder Fensterbild eine
`ScreenObservation` macht:

```swift
struct ScreenObservation: Codable {
    var at: Date
    var source: Source            // .accessibility, .ocr
    var roster: [String]          // sichtbare Teilnehmer
    var activeSpeakers: [String]  // Stufe 3; leer, wenn unbekannt
}
```

Abtastung 1 Hz, mit Budget: überschreitet eine Abfrage es dreimal in Folge, halbiert
sich die Rate. Bildschirmfreigabe, minimiertes Fenster, geänderte Oberfläche → leere
Beobachtung, kein Fehler.

**Was die Teilnehmerliste allein schon bringt:**

- **Kandidaten** für den `SpeakerNameResolver` — richtig geschrieben, nicht aus dem
  (leeren) Kalender.
- **Sprecheranzahl** für die Diarisierung: `expectedRemoteSpeakers` = höchste Zahl
  gleichzeitig sichtbarer Teilnehmer minus eins (der Nutzer), vor dem Kalender.
- **Der 1:1-Fall ohne Zeitachse:** War über das ganze Meeting **genau eine** entfernte
  Person zu sehen und bleibt nach Stufe 1 **genau ein** großer Cluster, bekommt er
  deren Namen (`source = 'screen'`). Interviews und Zweiergespräche — ein großer Teil
  der gemessenen Meetings — sind damit erledigt.
- `recordings.participants TEXT` (neue Spalte, nullable) und im Markdown unter
  „Teilnehmer" — getrennt von `attendees`, weil „eingeladen" und „dabei gewesen"
  verschiedene Aussagen sind.

### 4.4 Stufe 3 — wer spricht, auf der Zeitachse

Die Adapter liefern zusätzlich `activeSpeakers`. Daraus wird eine Zeitachse von
Intervallen mit **genau einem** hervorgehobenen Namen; Intervalle mit null oder
mehreren werden nicht gewertet.

**Zuordnung (pure `ScreenSpeakerAssignment`), je Cluster:**

1. Überlappung jedes Segments mit den Intervallen, verschoben um die geschätzte
   Anzeige-Verzögerung.
2. Name *N* gewinnt, wenn er ≥ 60 % der abgedeckten Zeit hält **und** die abgedeckte
   Zeit ≥ 10 s oder ≥ 30 % der Clusterzeit ist. Sonst: kein Name aus dem Bildschirm.
3. Der eigene Name des Nutzers ist nie Ziel (wie `ownerNameTokens`).
4. **Zwei Cluster → derselbe Name** heißt hier nicht „geraten", sondern „die
   Diarisierung hat eine Person gespalten" — das ist unabhängige Evidenz, und die
   beiden Cluster werden zusammengeführt. (Payhawk: Sprecher 3 und 5.)
5. **Ein Cluster → zwei Namen** mit je ≥ 30 %: die Diarisierung hat zwei Personen
   verschmolzen. Dann werden Segmente **einzeln** benannt, aber nur solche, die zu
   ≥ 80 % unter einem Namen liegen; der Rest bleibt `Sprecher n`.

**Selbstprüfung über die eigene Stimme.** Wenn der Nutzer spricht (VAD auf der
Mikrofonspur), muss der Call **ihn** hervorheben. Daraus wird je Meeting geschätzt:

- **die Verzögerung** der Anzeige (Mittel der Abstände zwischen Sprachbeginn auf dem
  Mikrofon und Hervorhebung des eigenen Namens) — statt einer geratenen Konstante;
- **ob der Adapter überhaupt stimmt:** Folgt die eigene Hervorhebung der eigenen
  Stimme nicht (Übereinstimmung < 70 %), ist die Oberfläche anders als erwartet, und
  **Stufe 3 wird für dieses Meeting nicht angewendet** — protokolliert, nicht geraten.

Das ist der zweite Grund, warum Spec 23 zuerst kommt.

**Reihenfolge der Quellen:** `user` > `screen` > `llm`. Der Resolver benennt nur noch
Labels, die der Bildschirm offenlässt, und bekommt die Teilnehmerliste als Kandidaten.

**Absturzsicher:** Beobachtungen werden als `screen.jsonl` in den Spool geschrieben
(entprellt, wie `notes.md`). Die Wiederherstellung kann die Zuordnung dann nachholen.
Das Archiv behält die Datei — sie ist klein und enthält nur Namen und Zeiten.

### 4.5 Stufe 4 — Korrigieren, und die Korrektur hält

Für alles, was der Bildschirm nicht lösen konnte (Telefonate, Treffen vor Ort,
Bildschirmfreigabe über das ganze Meeting), und als Grundwahrheit, an der Stufe 3
gemessen wird.

**Oberfläche** — im Notizen-Fenster je Meeting ein Abschnitt „Sprecher":

```
Anna Weber   118 Beiträge · 19:38   [ Anna Weber    ]  vom Bildschirm   [Zusammenführen ▾]
Sprecher 2    26 Beiträge ·  4:14   [ Name …        ]                   [Zusammenführen ▾]
Ich          212 Beiträge · 22:05   (fest)
```

- Umbenennen mit Vorschlägen aus Teilnehmerliste und Kalender; Herkunft sichtbar
  („vom Bildschirm", „aus dem Gespräch", „von dir").
- Zusammenführen: zwei Labels, ein Name — für den Nutzer erlaubt.
- `Ich` bleibt fest.
- Danach: „Zusammenfassung ist noch auf dem alten Stand — [Neu zusammenfassen]". Kein
  automatischer Aufruf; das kostet beim API-Anbieter Geld.

**Daten** — Migration 5 unter `PRAGMA user_version`:

```sql
ALTER TABLE segments   ADD COLUMN cluster TEXT;       -- geprägtes Label, "Sprecher 3"
ALTER TABLE recordings ADD COLUMN participants TEXT;  -- vom Bildschirm, "\n"-getrennt
CREATE TABLE speaker_labels (
    recording_id TEXT NOT NULL,
    cluster      TEXT NOT NULL,
    name         TEXT,                                -- NULL = anonym
    source       TEXT NOT NULL CHECK (source IN ('llm','screen','user')),
    PRIMARY KEY (recording_id, cluster)
);
```

- `segments.speaker` hält weiter den **angezeigten** Namen; FTS, Suche, Chat und
  `MarkdownProjector` bleiben unverändert. `segments.cluster` hält, was die
  Diarisierung geprägt hat — ohne sie wüsste nach einer Umbenennung niemand, welche
  Segmente zusammengehören.
- Bestandszeilen: `cluster`/`participants` bleiben `NULL`, nichts wird geschätzt.
- Umbenennen ist **eine** Transaktion; danach projiziert `NoteManager` neu wie beim
  Titel (`NoteManager.swift:75`); FTS folgt über die Trigger.
- **`user` schlägt alles**; kein späterer Lauf überschreibt es.

## 5. Integration

- **`MeetingPipeline`** — Embeddings behalten, `SpeakerClusterCleanup`, `cluster` in
  `MeetingTranscriptSegment`, Zuordnung aus 4.4 nach der Transkription.
- **Neu:** `Meeting/SpeakerClusterCleanup.swift`, `Meeting/ScreenSpeakerAssignment.swift`
  (beide pure), `Meeting/CallScreenObserver.swift`,
  `Meeting/CallScreenAdapters/{Teams,Zoom,Meet}.swift`.
- **`MeetingDetector`** — gibt Prozess/PID des eingerasteten Calls heraus.
- **`MeetingController`** — Observer mit der Aufnahme starten/stoppen; Teilnehmerzahl
  vor der Diarisierung; `screen.jsonl` in der Wiederherstellung.
- **`SpoolStore`** — `screen.jsonl` schreiben, lesen, archivieren.
- **`SpeakerNameResolver`** — respektiert `screen`/`user`, bekommt die Teilnehmerliste.
- **`CalendarMonitor`** — Diagnose-Log.
- **`RecordingStore`** — Migration 5, `renameSpeaker`, `mergeSpeaker`, `speakerLabels`.
- **`NoteManager` / `NoteListView`** — Sprecher-Abschnitt.
- **`MeetingsSettingsView`** — Schalter „Sprecher am Bildschirm erkennen", Hinweis zur
  Berechtigung, falls Weg B nötig ist. `en.lproj` für alle neuen Texte.

## 6. Risiken

- **Die Oberflächen ändern sich mit jedem App-Update.** Ein Adapter kann über Nacht
  nichts mehr finden — oder schlimmer, das Falsche. Gegenmittel: die Selbstprüfung in
  4.4 schaltet Stufe 3 je Meeting ab, wenn die eigene Hervorhebung nicht zur eigenen
  Stimme passt; und ein Adapter, der drei Meetings in Folge nichts liefert, meldet das
  in den Einstellungen („Teams: Sprecheranzeige nicht mehr lesbar").
- **Bildschirmaufnahme (nur Weg B)** fordert eine neue Berechtigung. macOS fragt seit
  Version 15 für Bildschirmaufnahmen regelmäßig erneut nach und zeigt während der
  Aufnahme ein Symbol in der Menüleiste. Deshalb hat Weg A Vorrang, wo er trägt, und
  Weg B wird je App nur eingeschaltet, wenn Stufe 0 zeigt, dass es ohne nicht geht.
- **Fremde Oberflächen auslesen greift nach außen.** Nur lesend, nur lokal, nur das
  Call-Fenster, nur während einer bestätigten Aufnahme — trotzdem offene Entscheidung
  (§8), ob der Schalter an oder aus beginnt.
- **Rechenlast während des Calls.** Budget je Abfrage, Halbierung bei Überschreitung,
  niedrige Priorität. Ziel: im Mittel unter 5 % eines Kerns. In Stufe 0 gemessen.
- **Die Neuzuordnung in Stufe 1 verschiebt ein echtes Wort zum falschen Menschen.**
  Nur kleine Cluster, nur unter einer Distanzschwelle; umkehrbar in Stufe 4.
- **Treffen vor Ort und Telefonate haben keinen Bildschirm.** Dort bleibt es beim
  Textweg und bei der Korrektur.

## 7. Abnahme

- Stufe 0: Messtabelle für Teams, Zoom, Meet ist in dieser Spec nachgetragen.
- Payhawk-Replay (Stufe 1): höchstens drei Labels.
- `MeetingConversationTests` trennt weiterhin zwei Sprecher.
- 1:1-Call in jeder der drei Apps: der entfernte Sprecher trägt den angezeigten Namen,
  ohne dass ein Name gesprochen wurde.
- Call mit drei Personen: jeder benannte Cluster stimmt mit der Hand-Korrektur
  überein (Präzision ≥ 95 %; die Abdeckung wird berichtet, nicht vorgeschrieben —
  lieber anonym als falsch).
- Selbstprüfung: mit absichtlich falschem Adapter (Hervorhebung verschoben) wird
  Stufe 3 für das Meeting nicht angewendet.
- Kein Bild auf der Platte: nach einem Meeting enthält weder Spool noch Archiv noch
  `~/Library` eine Bilddatei von Notable.
- Umbenennen ändert Markdown, Suche und Chat-Kontext; kein späterer Lauf
  überschreibt es. Bestandsmeetings (`cluster IS NULL`) lassen sich umbenennen.

## 8. Offene Entscheidungen

1. **Schalter „Sprecher am Bildschirm erkennen": an oder aus zu Beginn?** Empfehlung:
   an für Weg A (keine neue Berechtigung, nur lesend, nur während einer bestätigten
   Aufnahme); Weg B fragt beim ersten Bedarf ausdrücklich.
2. **Stimmprofile** (Stimmen über Meetings hinweg wiedererkennen, gespeicherte
   Embeddings) — in der ersten Fassung dieser Spec Stufe 3, jetzt zurückgestellt: der
   Bildschirm liefert die Namen in jedem Call frisch, ohne einen biometrischen Speicher.
   Wieder aufnehmen nur, falls Treffen vor Ort und Telefonate zum Hauptfall werden.
3. **Kurze Hörprobe je Sprecher** in Stufe 4 (5 s aus dem Archiv) — hilft beim
   Erkennen, geht aber nur, solange das Archiv existiert.
