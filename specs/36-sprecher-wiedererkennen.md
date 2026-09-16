# Spec 36 — Sprecher wiedererkennen

> **Aufwand: ½ h + S + S–M + M (gestuft, die letzte Stufe hinter einer Messung).**
> Spec 24 hat die Sprechererkennung zu Ende gebaut und Spec 35 hat sie vermessen: **1 von
> 23** Gegenseiten-Labels trug einen Namen. Beide Specs haben die Regeln bewusst nicht
> gelockert — „ein falscher Name ist schlimmer als `Sprecher n`" gilt weiter. Diese Spec
> lockert ebenfalls nichts. Sie holt die zwei Quellen nach, die es bisher nur auf dem
> Papier gibt (Bildschirm, Stimme), und beseitigt einen Fehler, der das erste erfolgreich
> benannte 1:1-Meeting verlieren würde.

## 1. Ausgangslage (Fakten aus Code und Datenbank, 2026-09-16)

- **Quellen heute.** Reihenfolge in `MeetingController.swift:1169-1217`: Bildschirm
  (`ScreenNaming.apply`) → Kalender (`OneToOneNaming`, seit 2026-09-16) → Modell
  (`SpeakerNameResolver`, nur wörtlich genannte Namen). Der Nutzer korrigiert in
  `SpeakerEditorView` (`Notes/SpeakerEditorView.swift`); eine `user`-Zeile in
  `speaker_labels` wird nie überschrieben.
- **Der Bildschirm liefert nichts.** `CallScreenAdapters.all == []`
  (`CallScreenObserver.swift:19`), absichtlich: erst messen, welche App was in ihrem
  AX-Baum zeigt. Die Messung ist das Werkzeug „Call-Fenster jetzt auslesen"
  (`ScreenProbe`, `:110-201`) — **es wurde nie ausgeführt**:
  `~/Library/Logs/Notable/screen-probe/` existiert nicht, `~/Library/Logs/Notable/`
  ebenfalls nicht. Damit sind Stufe 2 und 3 von Spec 24 (Kandidaten vom Bildschirm,
  aktiver Sprecher je Segment, Selbstprüfung an der eigenen Stimme) gebaut, getestet
  und folgenlos: `screen.jsonl` wird nie geschrieben, `ScreenNaming.apply` nimmt immer
  den frühen Ausgang (`ScreenSpeakers.swift:270`).
- **Die Stimme wird nicht wiedererkannt.** Embeddings leben für die Dauer einer
  Diarisierung im Speicher (`MeetingPipeline.swift:252-262`, `SpeakerClusterCleanup`)
  und werden nirgends geschrieben — kein Feld, keine Tabelle, keine Datei. Spec 24 §8.2
  hat Stimmprofile zurückgestellt: „wieder aufnehmen nur, falls Treffen vor Ort und
  Telefonate zum Hauptfall werden". Der Grund war, dass Namen in Calls vom Bildschirm
  kommen — der bis heute nicht gelesen wird.
- **Der Kalender fehlt meistens.** 13 von 18 Meetings ohne Ereignis (Spec 35 §1); die
  Kalender, in denen die Einladungen liegen, kennt EventKit nicht. Der Fenstertitel der
  Call-App trägt den Meeting-Titel — und wird nirgends gelesen.
- **Ein latenter Fehler.** `speaker_labels.source` ist `CHECK (source IN ('llm',
  'screen', 'user'))` — im Code (`SQLiteConnection.swift:482`) **und** in der
  installierten Datenbank (`sqlite_master`, geprüft). `SpeakerLabel.Source` hat seit
  Spec 35 den Fall `.calendar` (`RecordingStore.swift:105`), und `OneToOneNaming`
  schreibt ihn (`MeetingController.swift:1197`). `recordSpeakerLabels` läuft **in der
  Transaktion von `insertMeeting`** (`RecordingStore.swift:311-320`). Das erste
  1:1-Meeting, das tatsächlich einen Namen findet, endet also in `SQLITE_CONSTRAINT`
  und rollt die gesamte Aufnahme-Zeile zurück — Segmente, Zusammenfassung, Titel. Es
  ist bisher nicht aufgetreten, weil das Meeting vom 15.09. noch vor der Regel lief.
  Kein Test deckt `.calendar` (`grep "\.calendar" Tests/` — leer).
- **Bestand.** `speaker_labels`: 0 Zeilen. `recordings.participants`: 0 belegt.
  `segments.cluster`: 121 Zeilen aus genau einem Meeting („Ich" 71, „Sprecher 1" 49,
  „Sprecher ?" 1). 33 Meetings insgesamt, Archiv mit `mic.m4a` + `system.m4a` je
  Meeting.
- **Korrektur ohne Ohr.** Der Sprecher-Dialog zeigt Name, Beiträge, Dauer, Herkunft —
  aber niemand kann hören, *wer* „Sprecher 2" ist. Spec 24 §8.3 (Hörprobe) ist offen.
  Ohne Hörprobe korrigiert nur, wer sich ans Meeting erinnert.

## 2. Ziel

Nach dieser Spec hat ein Meeting mit einem Kollegen, der schon einmal in einem Meeting
benannt wurde — vom Bildschirm, aus dem Kalender oder von Hand —, dessen Namen **beim
zweiten Mal von selbst**, ohne Kalender, ohne dass er genannt wird, ohne dass Text das
Gerät verlässt. Wer korrigiert, hört vorher fünf Sekunden. Und die Bildschirm-Messung,
die seit dem 11.09. auf einen Handgriff wartet, passiert beim nächsten Call von selbst.

Was **nicht** Ziel ist: Namen aus dem Gesprächskontext ohne wörtliche Nennung (Spec 35
§4 — bleibt zurückgestellt, bis die Messung aus Spec 35 Zahlen liefert), und eine
Lockerung irgendeiner Schwelle aus Spec 24 §9.2.

## 3. Konzept

### 3.0 Der Fehler zuerst (½ h)

Migration 7: `speaker_labels` neu anlegen — SQLite kann einen `CHECK` nicht ändern —
mit `source IN ('llm', 'screen', 'calendar', 'voice', 'user')`, Zeilen kopieren,
umbenennen. `voice` schon jetzt, damit Stufe 3 keine achte Migration braucht.
Dazu ein Test, der jeden Fall von `SpeakerLabel.Source` einmal durch
`recordSpeakerLabels` schreibt — die Lücke zwischen Enum und `CHECK` darf nicht wieder
entstehen. Das ist kein Teil der Stufen, das gehört in den nächsten Commit.

### 3.1 Stufe 1 — Die Messung passiert von selbst (S)

Die Stufe-0-Messung aus Spec 24 scheitert nicht an Technik, sondern daran, dass sie
mitten in einem Call einen Knopf in den Einstellungen verlangt. Also:

- `CallScreenObserver` schreibt, wenn er für die Bundle-ID **keinen Adapter** findet
  (`:57`), **einmal je Bundle-ID und App-Version** den AX-Baum als Probe nach
  `~/Library/Logs/Notable/screen-probe/` — dieselbe Datei, die der Knopf heute
  schreibt, zum selben Zeitpunkt, an dem der Adapter gebraucht würde: 60 s nach
  Call-Beginn, wenn die Teilnehmerliste steht. Marker in `UserDefaults`
  (`screenProbeTaken.<bundle>.<version>`), damit es genau einmal passiert.
- Der Knopf „Call-Fenster jetzt auslesen" verschwindet aus „Erweitert" (Spec 38 räumt
  ihn ohnehin); an seine Stelle tritt eine Zeile „Bildschirm-Messungen: n Dateien" mit
  „Im Finder zeigen".
- **Datenschutz:** die Probe enthält Namen aus dem Call-Fenster. Sie liegt in `Logs`,
  lokal, unterliegt keinem Retention-Lauf (die kennt nur `spool-*`). Deshalb: Probe-
  Dateien älter als 30 Tage löscht `CallScreenObserver` beim nächsten Schreiben, und
  die Zeile in den Einstellungen sagt, was drinsteht.
- Die Meldung aus Spec 24 §4 („Adapter liefert seit drei Meetings nichts") wird hier
  gebaut, weil sie ab dem ersten Adapter gebraucht wird: `NoteDiagnosis` bekommt
  `bildschirmOhneDaten: n Meetings`, und ab 3 sagt die Notiz-Benachrichtigung es.

**Adapter (je S, nach der Messung).** Ein Adapter pro App ist eine Datei mit drei
Funktionen — Teilnehmerliste, hervorgehobener Sprecher, Fenstertitel — und einem
Fixture: die Probe-Datei, aus der er gebaut wurde, unter
`Tests/Fixtures/screen-probe/`. Der Test läuft gegen die Fixture, nicht gegen die App;
ändert Teams sein UI, bricht der Adapter sichtbar im Diagnose-Code, nicht still. Ein
Adapter, der in der Fixture einen Sprecher hervorhebt, der nicht in der
Teilnehmerliste steht, ist kein Adapter. Reihenfolge: Teams (der gemessene Hauptfall),
dann Zoom, dann Meet.

**Fenstertitel als Titelquelle (im selben Zug).** Zwischen `kalender` und `modell` in
`NoteDiagnosis.title` tritt `fenster`: der Adapter liefert den Titel des Call-Fensters,
bereinigt um App-Namen und Status („Microsoft Teams", „| Meeting", „(1)"). Nur wenn
mindestens drei Wörter übrig bleiben — „Besprechung" allein ist kein Titel.

### 3.2 Stufe 2 — Hören vor dem Korrigieren (S–M)

`SpeakerEditorView` bekommt pro Sprecher einen ▶-Knopf: die **lauteste** Passage
dieses Clusters, maximal 5 s, aus `system.m4a` bzw. `mic.m4a` im Archiv, gefunden über
`segments.start/end` des Clusters und den RMS der Spur. Ohne Archiv (Retention hat
gelöscht, oder das Meeting ist älter als das Archiv) ist der Knopf inaktiv mit
`.help("Audio nicht mehr vorhanden")` — kein stilles Fehlen.

Und die Korrektur wird erreichbar, wo sie gebraucht wird: die Benachrichtigung „Notiz
fertig" bekommt, wenn `NoteDiagnosis.naming` kein `benannt:` trägt und mehr als eine
Gegenseite existiert, eine zweite Aktion **„Sprecher benennen…"**, die den Dialog
öffnet. Heute muss man ihn in der Notizliste suchen.

### 3.3 Stufe 3 — Stimmprofile: die Korrektur, die hält (M, nach Messung)

Der eigentliche Hebel. Jede bestätigte Zuordnung — `user` aus dem Dialog, `screen`
mit Selbstprüfung ≥ 70 %, `calendar` aus dem 1:1-Fall — wird zu einem **Stimmprofil**:
Name, gemittelte Embedding-Zentroide (dieselbe Rechnung wie
`SpeakerClusterCleanup.centroid`, `:137-147`), Anzahl Meetings, Datum. Beim nächsten
Meeting bekommt jeder **große** Cluster (Spec 24-Sinn: ≥ 8 s und ≥ 3 %) den Namen des
nächsten Profils, wenn

- der Cosinus-Abstand unter **einer noch zu messenden Schwelle** liegt (§3.4),
- **kein zweites Profil** näher als Schwelle + 0,1 liegt (sonst ist es ein Münzwurf,
  und die Regel aus Spec 24 §9.2 gilt: lieber Nummer als Rate),
- und der Name nicht schon einem anderen Cluster dieses Meetings zugeordnet ist.

Quelle `voice`, Rang zwischen `screen` und `calendar`: user > screen > **voice** >
calendar > llm. Ein `voice`-Treffer, den der Nutzer im Dialog korrigiert, **zieht das
Profil zurück**: das falsche Profil verliert diesen Cluster, der richtige Name bekommt
ihn — die Korrektur ist der Trainingsdatensatz, wie beim Wörterbuch (Spec 06).

**Was das Profil ist und wo es liegt.** Ein Embedding ist aus Audio gerechnet, aber es
ist kein Audio: nichts lässt sich daraus zurückspielen. Es ist trotzdem ein
**biometrisches Merkmal einer anderen Person**, gespeichert auf diesem Rechner. Deshalb:

- Tabelle `voice_profiles (id, name, embedding BLOB, dimension, meetings, created_at,
  updated_at)` in SQLite — verlässt das Gerät nie, liegt in derselben Datei wie die
  Transkripte, die ohnehin die Wörter dieser Person enthalten.
- **Ein Schalter**, aus in der Vorgabe (§7): „Stimmen wiedererkennen". Der Footer sagt
  den einen Satz: *„Notable merkt sich, wie benannte Sprecher klingen, um sie im
  nächsten Meeting zu erkennen. Bleibt auf diesem Mac."*
- Profile sind **sichtbar und löschbar**: eine Liste unter Meetings → Sprecher mit
  Name, Anzahl Meetings, „Vergessen". Löschen eines Profils lässt bestehende
  `speaker_labels` unberührt — die Notiz bleibt, wie sie war.
- Kein Profil für „Ich": die Mikrofonspur ist per Konstruktion der Nutzer.

### 3.4 Die Messung vor Stufe 3 (½ Tag, mit `MeetingReplayTests`)

Die Frage ist nicht, ob Embeddings Stimmen trennen — das tut die Diarisierung schon —,
sondern ob dieselbe Stimme **über Meetings hinweg** näher bei sich bleibt als bei
anderen: anderes Headset, anderer Codec, Teams heute und Zoom morgen. Spec 24 §9.1 hat
für Splitter *innerhalb* eines Meetings 0,58–1,04 gemessen; für Zentroide großer
Cluster über Meetings gibt es keine Zahl.

Ablauf: `MeetingReplayTests` rechnet für alle archivierten Meetings die Zentroide der
großen Cluster; der Owner labelt in einer kleinen Tabelle (`Tests/Fixtures/voices.csv`:
Meeting-ID, Cluster, Name) etwa 15 Cluster mit den 3–4 Kollegen, die am häufigsten
vorkommen — die Hörprobe aus Stufe 2 ist dafür da. Der Test druckt zwei Verteilungen:
Abstand gleiche Person / verschiedene Personen. **Gebaut wird Stufe 3 nur, wenn die
Verteilungen sich bei einer Schwelle mit ≤ 5 % falschen Treffern trennen** — und die
Schwelle ist dann die gemessene, mit Sicherheitsabstand, keine runde Zahl.

## 4. Integration

| Stelle | Änderung |
|---|---|
| `Storage/SQLiteConnection.swift` | Migration 7: `speaker_labels` mit erweitertem `CHECK`; `voice_profiles` |
| `Storage/RecordingStore.swift` | `SpeakerLabel.Source.voice`; `voiceProfiles()`, `upsertVoiceProfile`, `forgetVoiceProfile` |
| `Meeting/CallScreenObserver.swift` | Auto-Probe einmal je Bundle/Version; Probe-Aufräumen 30 Tage |
| `Meeting/CallScreenAdapters/Teams.swift` (neu, dann Zoom, Meet) | je Adapter + Fixture unter `Tests/Fixtures/screen-probe/` |
| `Meeting/NoteDiagnosis.swift` | `bildschirmOhneDaten`, Titelquelle `fenster`, Namensquelle `stimme: n` |
| `Meeting/VoiceProfiles.swift` (neu, pur) | Zentroid, Zuordnung mit Abstandsregel, Rückzug bei Korrektur |
| `Meeting/MeetingController.swift` | `voice` in die Quellenreihenfolge; Profil-Update nach `insertMeeting` und nach jeder Korrektur |
| `Notes/SpeakerEditorView.swift` | ▶ Hörprobe; `voice` als Herkunft („an der Stimme erkannt") |
| `Meeting/SpeakerSample.swift` (neu) | lauteste Passage eines Clusters aus dem Archiv, `AVAudioPlayer` |
| `Support/NotificationCenterService.swift` | Aktion „Sprecher benennen…" |
| `Settings/MeetingsSettingsView.swift` | Schalter + Profil-Liste (nach Spec 38 unter „Sprecher") |
| `Tests/MeetingReplayTests.swift` | §3.4 Verteilungen; `voices.csv` |
| `Tests/RecordingStoreTests.swift` | jeder `Source`-Fall durch `recordSpeakerLabels` |

Kein Defaults-Key wird umbenannt. `screenSpeakerRecognition` bleibt der Schalter für
den Bildschirmweg; neu kommt `voiceProfilesEnabled` (Vorgabe `false`, §7).

## 5. Risiken

- **Migration 7 fasst eine Tabelle an, in der 0 Zeilen stehen.** Das ist der beste
  Zeitpunkt; trotzdem läuft sie in einer Transaktion und der Test spielt sie auf einer
  Datenbank mit Bestandszeilen durch.
- **Adapter lesen fremde Oberflächen.** Spec 24 §5 gilt: Fixture-Tests statt Live-Tests,
  Selbstprüfung an der eigenen Stimme bleibt die Sperre. Ein Adapter darf nach einem
  App-Update in `bildschirmOhneDaten` enden, aber nie in einem falschen Namen.
- **Stimmprofile treffen die falsche Person.** Die Zwei-Profile-Regel (§3.3) und die
  gemessene Schwelle sind die Sperren; die Hörprobe macht den Fehler auffindbar; die
  Korrektur zieht das Profil zurück. Ein Fehltreffer kostet eine Korrektur, nicht ein
  Meeting — anders als eine falsche Zusammenführung zweier Cluster, die Spec 24 deshalb
  verbietet und diese Spec auch.
- **Biometrie.** Ein Stimmprofil eines Kollegen liegt auf dem Rechner des Nutzers. Das
  Transkript mit dessen Worten liegt schon dort, und die Notiz mit dessen Namen. Das
  Profil fügt ein Merkmal hinzu, aus dem sich nichts rekonstruieren lässt, das das Gerät
  nie verlässt und das mit einem Klick verschwindet. Trotzdem: aus in der Vorgabe, ein
  Satz, der sagt, was passiert — und die Entscheidung liegt beim Owner (§7).
- **Hörprobe braucht das Archiv.** Retention löscht es nach Frist; dann hört man
  nichts. Der inaktive Knopf sagt das. Spec 38 macht die Frist zur einen sichtbaren
  Aufbewahrungs-Einstellung, sodass der Zusammenhang erkennbar ist.

## 6. Abnahme

1. Ein 1:1-Meeting mit genau einem Gast im Kalender speichert Zeile, Segmente **und**
   ein `speaker_labels`-Label mit `source = 'calendar'` (Test auf frischer *und* auf
   Bestands-Datenbank).
2. Nach dem nächsten Teams-Call liegt genau eine Datei in `screen-probe/`, ohne dass
   jemand einen Knopf gedrückt hat; ein zweiter Call derselben Version schreibt keine.
3. Teams-Adapter: gegen die Fixture Teilnehmerliste, aktiver Sprecher, Fenstertitel;
   im echten Call ≥ 70 % Selbstprüfung (`ScreenSelfCheck`), sonst wird nichts benutzt
   und `meta.json` sagt warum.
4. Sprecher-Dialog: ▶ spielt 5 s des gewählten Sprechers; ohne Archiv inaktiv mit
   Hinweis. Die Benachrichtigung einer unbenannten Notiz öffnet den Dialog.
5. §3.4 gelaufen, Verteilungen im Test-Log, Schwelle festgehalten in dieser Spec (§8).
6. Stufe 3: ein Kollege, im Meeting A von Hand benannt, trägt in Meeting B seinen Namen
   mit Herkunft „an der Stimme erkannt"; Korrektur in B ändert das Profil; „Vergessen"
   entfernt es und lässt A und B unverändert. Gegenprobe: zwei Profile innerhalb 0,1
   Abstand ⇒ Nummer, kein Name.
7. `NoteDiagnosis` nennt `stimme: n` bzw. `bildschirmOhneDaten`, und die Zahlen aus
   Spec 35 §1 werden nach zehn Meetings mit 1.4 neu erhoben: Ziel ≥ 60 % der großen
   Gegenseiten-Cluster benannt, **0 falsche Namen**.

## 7. Offene Entscheidungen

- **Stimmprofile überhaupt** (§3.3, §5). Spec 24 §8.2 hat sie zurückgestellt; der
  Grund (Bildschirm liefert die Namen) ist nach fünf Wochen ohne Adapter nicht
  eingetreten. Vorschlag: bauen, aus in der Vorgabe, nach bestandener Messung §3.4.
- **Vorgabe des Schalters**, falls ja: aus (Vorschlag — eine neue Datenklasse verdient
  ein bewusstes Einschalten) oder an (es ist die Funktion, die die meisten Namen
  bringt).
- **Auto-Probe ohne Rückfrage**: die Datei enthält die Namen im Call-Fenster. Lokal,
  30 Tage, im Logs-Ordner. Vorschlag: ja, weil die Alternative die Messung ist, die
  seit fünf Wochen nicht stattfindet.
- **Fenstertitel als Titelquelle**: vor oder nach `modell`? Vorschlag: davor — der Titel
  im Fenster ist der, den der Einladende gewählt hat.

## 8. Handtests und Messwerte

*Noch nicht gelaufen.* Hier landen: die Verteilungen aus §3.4 mit der daraus gewählten
Schwelle, das Datum der ersten Auto-Probe je App und die Zahlen aus Abnahme 7.

## 9. Stand des Baus (2026-09-16)

Entschieden am 2026-09-16, alle vier offenen Punkte aus §7 nach dem Vorschlag:
Stimmprofile werden **gebaut, aber aus in der Vorgabe**; die Auto-Probe läuft **ohne
Rückfrage**; der Fenstertitel steht **vor** dem Modell.

**Gebaut:**

- **Stufe 1 — die Messung passiert von selbst.** `ScreenProbe.automaticProbe` hängt an
  jedem Aufnahmestart: findet sich für die Bundle-ID kein Adapter, schreibt es 60 s
  später den AX-Baum nach `~/Library/Logs/Notable/screen-probe/` — einmal je Bundle-ID
  *und App-Version* (`ScreenProbeRule`, Marker in `UserDefaults`), am selben Schalter
  wie der Beobachter (`screenSpeakerRecognition`), und markiert erst, **nachdem** eine
  Datei entstanden ist. Endet die Aufnahme vorher, wird die Aufgabe abgebrochen. Vor
  jedem Schreiben fallen Proben älter als 30 Tage weg. Der Knopf „Call-Fenster jetzt
  auslesen" ist aus „Erweitert" verschwunden; an seiner Stelle steht „Bildschirm-
  Messungen: n Dateien" mit „Im Finder zeigen" und dem Satz, was drinsteht und wie
  lange. (`ScreenProbe.probeRunningCall` bleibt — der ⌥-Eintrag im Menü ruft es.)
- **`bildschirmOhneDaten`** (`ScreenDataWatch`, pur): ein Meeting **mit** Adapter und
  ohne eine einzige Beobachtung zählt hoch, eine Beobachtung setzt zurück, ein Meeting
  ohne Adapter zählt gar nicht. Ab 3 sagt es die Notiz-Benachrichtigung und die
  Statuszeile. `meta.json` trägt neu `screen` (`keinAdapter` / `gelesen: n
  Beobachtungen` / `bildschirmOhneDaten: n Meetings`), lenient dekodiert wie alles
  daneben.
- **Fenstertitel als Titelquelle** (`CallWindowTitle`, pur): `ScreenObservation` trägt
  optional `windowTitle`, der Titel wird um App-Namen und Status bereinigt, der
  häufigste des Meetings gewinnt, und er rangiert zwischen Kalender und Modell —
  `NoteDiagnosis.title` kennt `fenster`, und das Modell darf den Titel dann nicht mehr
  überschreiben.
- **Stufe 2 — Hörprobe.** `SpeakerSample` (pur: lauteste Passage ≤ 5 s, und welche
  Archiv-Sitzung zu einer Notiz gehört) plus `SpeakerSamplePlayer`. Im Sprecher-Dialog
  steht vor jedem Namen ein ▶ — auch vor „Ich" und „Sprecher ?", denn Zuhören ist keine
  Benennung. Ohne Archiv ist der Knopf inaktiv und sagt „Audio nicht mehr vorhanden".
  Die Benachrichtigung einer Notiz ohne Namen bekommt „Sprecher benennen…"
  (`NoteDiagnosis.offersSpeakerNaming`: kein `benannt:` **und** mehr als eine
  Gegenseite).
- **Stufe 3 — Stimmprofile.** Migration 8 mit `voice_profiles` und `meeting_voices`;
  `VoiceProfiles` (pur) mit der Zuordnungsregel (Abstand < Schwelle, **kein** zweites
  Profil innerhalb Schwelle + 0,1, Name im Meeting noch frei, der nähere Cluster
  gewinnt), dem Lernen und dem Zurückziehen. Quelle `voice` steht zwischen `screen` und
  `calendar`; `validated` prüft weiterhin Kollision und eigenen Namen. Gelernt wird nur
  aus **bestätigten** Zuordnungen: `user`, `calendar` und `screen` *mit* bestandener
  Selbstprüfung — nie aus dem Modell und nie aus einem Stimmtreffer selbst. Die Liste
  mit „Vergessen" steht unter Einstellungen → Meetings → Stimmen, aus in der Vorgabe,
  mit dem einen Satz als Fußnote.
- **Der Nebenbau:** `MeetingPipeline.processDetailed` reicht die Zentroide der großen
  Cluster aus der Pipeline heraus (`process` bleibt als Hülle), und
  `SpeakerClusterCleanup.centroids` ist dieselbe Rechnung wie bisher, nur benannt.

**Abweichungen, mit Grund:**

1. **Eine zweite Tabelle, `meeting_voices`.** §4 nennt nur `voice_profiles`, aber §3.3
   verlangt, dass eine Korrektur das falsche Profil *zurückzieht* — und die Embeddings
   leben nur für die Dauer einer Diarisierung. Ohne den gespeicherten Zentroid des
   Meetings hätte eine Korrektur Tage später nichts, womit sie rechnen könnte. Die
   Spalte `learned_for` hält fest, **welchem** Profil dieser Cluster tatsächlich
   zugeschlagen wurde: ein `voice`-Treffer lernt nichts, und von einem Profil etwas
   abzuziehen, das nie dazukam, würde es von der Person wegbiegen, der es gehört.
2. **`embedding` ist die Summe, nicht der Mittelwert.** Mit Summe und Meeting-Zahl ist
   das Herausrechnen eines Meetings eine exakte Subtraktion; ein gespeicherter
   Mittelwert hätte den Divisor verloren, und die Rücknahme wäre eine Schätzung.
3. **Der Dialog bekommt ein eigenes Fenster** (`SpeakerEditorWindow`). Er ist ein Sheet
   der Notizliste, und genau in dem Moment, in dem die Benachrichtigung ihn anbietet,
   ist diese Liste zu. `SpeakerEditorView` hat dafür ein optionales `onClose` — im Sheet
   bleibt `dismiss` zuständig.
4. **Eine wiederhergestellte Aufnahme zählt nie gegen einen Adapter.** Sie kann nicht
   wissen, ob einer lief; `screenAdapter` ist dort „es gibt Beobachtungen".
5. **`mergeSpeaker` fasst keine Profile an.** §3.3 spricht von der Korrektur des
   Namens; zwei Cluster zusammenzuführen ist eine Aussage über die Diarisierung, nicht
   über die Stimme. Der Zentroid zweier verschmolzener Cluster wäre außerdem kein
   gemessener, sondern ein gerechneter.
6. **Die Drei-Wörter-Regel für den Fenstertitel verwirft echte Titel.**
   „Forschungszulage Review" — der einzige Titel, den Spec 35 tatsächlich gemessen hat —
   hat zwei Wörter und fällt durch. Die Regel steht so in §3.1 und bleibt deshalb; der
   Preis ist eine Notiz, die auf „Microsoft Teams · 10:03" zurückfällt, nicht ein
   falscher Titel. **Wert einer Entscheidung** (§7 sinngemäß): auf zwei Wörter senken?

**Nicht gebaut, und warum:**

- **Die Adapter für Teams, Zoom und Meet.** `CallScreenAdapters.all` ist weiter leer.
  Auf dieser Maschine existiert keine einzige Probe-Datei, aus der ein Adapter gebaut
  werden könnte — das ist der ganze Sinn von Stufe 1. Ein geratener AX-Pfad liest die
  falsche Kachel und schreibt einen selbstsicheren falschen Namen. `Tests/Fixtures/
  screen-probe/` entsteht mit dem ersten Adapter, nicht vorher.
- **Die gemessene Schwelle.** `VoiceProfiles.matchDistance` ist **0,35 — ein Startwert,
  ausdrücklich ungemessen**, in der Art, in der Spec 34 seine RMS-Schwellen hält.
  Bewusst eng: ein verpasster Treffer kostet „Sprecher 1", ein falscher schreibt den
  Namen eines Kollegen auf eine fremde Stimme. §3.4 ist gebaut
  (`MeetingReplayTests.testVoiceDistancesAcrossMeetings` + `Tests/Fixtures/voices.csv`),
  aber nicht gelaufen: es braucht die Labels des Owners. Der Test druckt beide
  Verteilungen und die größte Schwelle mit ≤ 5 % Falschtreffern. Die
  Einstellungs-Fußnote sagt genau das: *„Wie zuverlässig das trifft, ist noch nicht
  vermessen."*

**Tests (2026-09-16):** die Freigabeliste — 29 Suiten, darunter alle Sprecher-, Spool-,
Storage-, Retention- und Localization-Suiten — **171 Tests, 0 Fehler**;
`MeetingEndToEndTests` gesondert grün. Neu: `VoiceProfilesTests` (Abstand, die
Zwei-Profile-Regel, ein Name je Meeting, Lernen/Zurückziehen als exakte Umkehrungen),
`VoiceProfileStoreTests` (Profil wächst, Korrektur zieht zurück und schreibt gut, ein
nie gelernter Treffer wird nicht abgezogen, Schalter aus lernt nichts, „Vergessen" lässt
die Notiz unberührt), `CallWindowTitleTests`, `ScreenProbeRuleTests`/
`ScreenDataWatchTests`, `SpeakerSampleTests`; dazu die neuen Fälle in
`NoteDiagnosisTests`. `MeetingReplayTests` kompiliert, wurde nicht ausgeführt.

**Was der Owner noch tun muss:** einen echten Call führen (die Probe schreibt sich von
selbst), aus der Datei den ersten Adapter bauen lassen, und für §3.4 rund 15 Cluster in
`Tests/Fixtures/voices.csv` labeln — die Hörprobe aus Stufe 2 ist dafür da. Erst danach
ist die Schwelle mehr als ein Startwert.
