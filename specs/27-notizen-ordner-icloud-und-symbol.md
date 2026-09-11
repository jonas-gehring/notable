# Spec 27 — Notizen-Ordner: eigenes Symbol, iCloud Drive als Vorgabe

> **Aufwand: Stufe 1 = S, Stufe 2 = S (optional).** Der Notizen-Ordner soll im Finder
> sofort als Notables Ordner erkennbar sein, und bei einer neuen Einrichtung in iCloud
> Drive liegen. Für bestehende Installationen darf sich dabei **nichts** bewegen.

## 1. Ausgangslage (Fakten aus dem Code und von der Platte)

- **Vorgabe heute: `~/Documents/Notable`** (`NotesFolder.swift:14-20`), als Pfad in
  `notesFolderPath`; Ändern über `NSOpenPanel`.
- **Auf diesem Rechner ist der Ordner bereits in iCloud Drive** — von Hand gewählt:
  `iCloud Drive/Codus/Meetings`, mit `Inbox/` und sechs Notizen, die jüngste vom
  10.09. Das belegt: die nicht gesandboxte App schreibt ohne jedes Entitlement nach
  `~/Library/Mobile Documents/com~apple~CloudDocs/`.
- Der Elternordner trägt `com.apple.macl` — die Spur der Auswahl im `NSOpenPanel`,
  mit der macOS den Zugriff gewährt hat. **Eine Vorgabe ohne Open-Panel hat diese Spur
  nicht** (siehe Risiken).
- Kein eigenes Symbol (kein `Icon\r` im Ordner).
- „Schreibtisch & Dokumente" wird hier ebenfalls über iCloud synchronisiert
  (`CloudDocs/Documents → ~/Documents`). Auf diesem Mac lag also schon die alte
  Vorgabe in der Cloud — aber nur wegen einer Systemeinstellung, die viele nicht
  eingeschaltet haben.
- **Struktur:** Wurzel + `Inbox/` + eine flache Ebene Projektordner
  (`NoteManager.swift:9-60`); die Suche nach Projektordnern überspringt versteckte
  Dateien und nimmt nur Verzeichnisse.
- **Notable liest kein Markdown zurück** (grep `String(contentsOf`: nur die Spool-Notizen,
  `SpoolStore.swift:148`). SQLite ist die Wahrheit, Markdown die Projektion. Dass
  „Mac-Speicher optimieren" Dateien auslagert, stört Notable also nicht: es schreibt,
  benennt um und verschiebt nur.
- **Fehler beim Anlegen verschwinden:** alle drei Aufrufe von `ensureExists` sind
  `try?` (`NotableApp.swift:503`, `MeetingController.swift:468`, `:529`).
- Das Onboarding hat keinen Ordner-Schritt. Die Einstellungen zeigen den rohen Pfad
  (`GeneralSettingsView.swift:42`) — hier
  `/Users/jonas/Library/Mobile Documents/com~apple~CloudDocs/Codus/Meetings`.

## 2. Ziel

Neu eingerichtet landen Notizen in **iCloud Drive/Notable**; der Ordner trägt ein
Notable-Symbol; die Einstellungen zeigen, wo er liegt und ob er synchronisiert wird.
Bestehende Installationen schreiben weiter genau dorthin, wo ihre Notizen schon liegen.

## 3. Konzept

### 3.1 Stufe 1a — die Vorgabe (pure `NotesFolderDefault`)

```
resolve(iCloudDriveRoot: URL?, documents: URL) -> URL
  iCloud-Drive-Wurzel existiert und ist beschreibbar → <iCloud Drive>/Notable
  sonst                                              → ~/Documents/Notable (wie heute)
```

Die Wurzel ist `~/Library/Mobile Documents/com~apple~CloudDocs`.
`url(forUbiquityContainerIdentifier:)` hilft hier nicht — es verlangt ein
iCloud-Entitlement und liefert den App-Container, nicht iCloud Drive.

### 3.2 Stufe 1b — Migration: nichts bewegt sich

Beim ersten Start der neuen Version, **nur wenn `notesFolderPath` fehlt**:

- `~/Documents/Notable` existiert → dieser Pfad wird in `notesFolderPath`
  **festgeschrieben**. Neue Notizen landen weiter neben den alten.
- existiert nicht → es gilt die neue Vorgabe.

Wer einen Ordner gewählt hat (wie hier), merkt nichts. Ein stilles Umziehen von
Notizen — oder, schlimmer, neue Notizen an einem anderen Ort als die alten — gibt es
nicht. Test mit allen drei Ausgangslagen.

### 3.3 Stufe 1c — der Ordner bekommt sein Symbol

- **Zur Laufzeit zusammengesetzt**, nicht als fertiges Bild mitgeliefert: das aktuelle
  System-Ordnersymbol (`NSWorkspace.shared.icon(for: .folder)`) mit Notables Zeichen
  (Wellenform aus dem App-Symbol) auf der Vorderseite, gerendert in 16…1024 px. Das
  Ordner-Aussehen ändert sich zwischen macOS-Versionen; ein eingebackener Ordner einer
  älteren Version sähe im Finder fremd aus.
- Gesetzt mit `NSWorkspace.shared.setIcon(_:forFile:options:)` — **nur auf der
  Wurzel**. `Inbox` und Projektordner gehören dem Nutzer.
- **Wann:** in `ensureExists`, beim Start und nach einem Ordnerwechsel; idempotent über
  einen Marker `notesFolderIconPath` + das Vorhandensein von `Icon\r`.
- **Nie ein fremdes Symbol überschreiben:** Liegt schon ein `Icon\r` im Ordner und der
  Marker zeigt nicht auf diesen Pfad, hat der Nutzer (oder Finders „Ordner anpassen")
  ihn gestaltet — dann bleibt er, wie er ist.
- **Beim Ordnerwechsel** wird das Symbol vom alten Ordner nur entfernt
  (`setIcon(nil, …)`), wenn der Marker sagt, dass Notable es gesetzt hat.
- Schalter „Symbol am Notizen-Ordner" (Default an). Aus → entfernt es, nach derselben
  Marker-Regel.
- `Icon\r` ist versteckt: `scanProjectFolders` und `uniqueFileName` sehen es nicht.

### 3.4 Stufe 1d — Fehler sichtbar, erster Zugriff im Vordergrund

- `ensureExists` wirft weiter, aber die Aufrufer **zeigen** den Fehler: Statuszeile im
  Menü, rote Zeile in den Einstellungen. Eine Notiz, deren Datei nicht geschrieben
  werden konnte, liegt trotzdem in SQLite (die Wahrheit) und wird nach der Behebung
  neu projiziert.
- **iCloud Drive ausgeschaltet** — die Wurzel fehlt, der konfigurierte Pfad lag darin:
  **nicht** neu anlegen. `createDirectory(withIntermediateDirectories: true)` würde
  sonst still `Mobile Documents/com~apple~CloudDocs/…` als lokales, nie
  synchronisiertes Verzeichnis wiedererschaffen. Stattdessen: „iCloud Drive ist aus —
  Notizen-Ordner nicht erreichbar", mit Knopf zum Wählen.
- **Onboarding** bekommt einen kurzen Ordner-Schritt: Pfad anzeigen, „Ändern…", und
  der Ordner wird *dort* angelegt. Falls macOS für den Zugriff auf iCloud Drive oder
  Dokumente fragt, fragt es jetzt, im Zusammenhang — und nicht, während nach einem
  Meeting die erste Notiz geschrieben wird.

### 3.5 Stufe 1e — Einstellungen zeigen, wo der Ordner liegt

- Zeile mit Ordnersymbol (`NSWorkspace.icon(forFile:)`), lesbarem Pfad
  „iCloud Drive › Codus › Meetings" (aus den lokalisierten Namen der Komponenten, nicht
  der rohe Pfad), „Im Finder zeigen", „Ändern…".
- Darunter: „Wird über iCloud synchronisiert" bzw. „Nur auf diesem Mac".

### 3.6 Stufe 2 — in iCloud Drive umziehen (optional, offene Entscheidung)

Für „Nur auf diesem Mac": ein Knopf „In iCloud Drive verschieben…" mit Plan vorher
(„42 Notizen, 3 Ordner → iCloud Drive/Notable"), wie beim Aufräumen. Verschiebt die
Dateien und schreibt `recordings.markdown_path` je Notiz in einer Transaktion um.
Angeboten, nie automatisch.

## 4. Integration

- **`NotesFolder.swift`** — `NotesFolderDefault`, Migration, Symbol setzen/entfernen,
  `ensureExists` mit iCloud-Wächter.
- **Neu `Storage/FolderIcon.swift`** — Zusammensetzen und Setzen (AppKit, dünn).
- **`MeetingController`, `NotableApp`** — Fehler von `ensureExists` anzeigen statt
  `try?`.
- **`OnboardingView`** — Ordner-Schritt.
- **`GeneralSettingsView`** — Ordnerzeile, Synchronisierungs-Hinweis, Schalter.
- **`en.lproj`** — neue Texte.

## 5. Risiken

- **TCC beim ersten Zugriff ohne Open-Panel.** Ob macOS eine nicht gesandboxte App beim
  ersten Schreiben nach iCloud Drive fragt, ist **nicht belegt** — hier wurde der Ordner
  per Open-Panel gewählt, das den Zugriff mitbringt. Vor dem Bau auf einem frischen
  Benutzerkonto prüfen. Fragt es, ist 3.4 (erster Zugriff im Onboarding) Pflicht, nicht
  Kür.
- **Das Symbol synchronisiert nicht zuverlässig.** Eigene Ordnersymbole liegen als
  verstecktes `Icon\r` plus Finder-Info-Flag im Ordner; ob iCloud Drive das auf andere
  Geräte trägt, ist unzuverlässig. Garantiert ist das Symbol auf diesem Mac, und es
  wird beim Start neu gesetzt, wenn es verloren ging. Andere Macs und iOS zeigen einen
  normalen Ordner. Ausgesprochen, nicht gelöst.
- **Konflikte in iCloud.** Ein Schreiber (Notable), Dateinamen mit Startzeit —
  kollisionsfrei. Wer dieselbe Notiz auf zwei Geräten gleichzeitig bearbeitet, bekommt
  iCloud-Konfliktkopien; das ist kein neues Risiko dieser Spec.

## 6. Abnahme

- Neue Installation mit iCloud Drive: Notizen landen in `iCloud Drive/Notable`, der
  Ordner trägt das Symbol.
- Neue Installation ohne iCloud Drive: `~/Documents/Notable`, wie bisher.
- Bestehende Installation mit `~/Documents/Notable` und ungesetztem Schlüssel: schreibt
  nach dem Update weiter dorthin.
- Gewählter Ordner (wie hier): unverändert, bekommt das Symbol; ein bereits
  gestaltetes Symbol bleibt.
- iCloud Drive aus: klare Meldung, kein lokal wiedererschaffenes `Mobile Documents`.
- Ordnerwechsel entfernt Notables Symbol vom alten Ordner und nur dieses.

## 7. Offene Entscheidungen

1. **Stufe 2 (Umziehen) bauen?** Empfehlung: nein, solange niemand danach fragt —
   wer umziehen will, kann den Ordner im Finder verschieben und neu wählen, sobald 3.2
   den Pfad sauber festhält. Aber dann müssten die gespeicherten `markdown_path` folgen;
   ohne Stufe 2 zeigen sie ins Leere. Deshalb ist es eine Entscheidung, keine Kür.
2. **Symbol auch an einem selbst gewählten Ordner** (Default an) — oder nur am
   Vorgabe-Ordner, weil ein gewählter Ordner dem Nutzer gehört?

## 8. Stand des Baus (2026-09-11)

Stufe 1 (a–e) und Stufe 2 sind gebaut. Entschieden am 2026-09-11: Stufe 2 wird gebaut,
und das Symbol kommt auch an einen selbst gewählten Ordner.

**Gemessen auf diesem Mac:**

- `FileManager.componentsToDisplay` liefert für den iCloud-Pfad
  „… › Library › Mobile Documents › iCloud Drive › Codus › Meetings". Der lesbare Pfad
  wird deshalb an der Wurzel geschnitten, deren Anzeige mit dem Pfad beginnt
  (`NotesFolderDisplay`), nicht aus den rohen Komponenten gebaut.
- `isUbiquitousItem` ist für `~/Documents` wahr („Schreibtisch & Dokumente" ist hier
  eingeschaltet). „Wird über iCloud synchronisiert" stützt sich deshalb auf beides:
  auf die Lage unter iCloud Drive *und* auf dieses Flag.
- `notesFolderPath` ist hier gesetzt — die Migration fasst diesen Mac nicht an.

**Abweichungen:**

- **§3.4 behauptet, eine Notiz, deren Datei nicht geschrieben werden konnte, liege
  trotzdem in SQLite. Das stimmt nicht.** `produceNote` schreibt die Markdown-Datei
  mit `try` *vor* der Datenbank; scheitert das, bleibt die Aufnahme als Spool in
  `spool-failed` und die Statuszeile nennt den Fehler. Den Kernpfad dafür umzubauen
  (erst SQLite, dann projizieren, später nachprojizieren) ist eine eigene Änderung
  und hier nicht gemacht. Gebaut ist, dass der Ordnerfehler **vorher** benannt wird.
- **Auch die neue Vorgabe wird festgeschrieben**, nicht nur der alte Ordner: sonst
  wanderte der Ordner, sobald iCloud Drive später ein- oder ausgeschaltet wird, und
  neue Notizen lägen an einem anderen Ort als die alten.
- **Umziehen verschiebt den ganzen Ordner mit einem `moveItem`** (iCloud Drive liegt
  auf demselben Volume) und schreibt die Pfade danach in einer Transaktion um;
  scheitert die Datenbank, zieht der Ordner zurück. Das Ziel ist nie ein bestehender
  Ordner („Notable 2", …). Während eines Meetings oder einer Notiz in Arbeit wird
  nichts verschoben.

**Offen:**

- **TCC beim ersten Zugriff ohne Open-Panel** (Risiko aus §5) ist nicht geprüft — das
  braucht ein frisches Benutzerkonto. Der Ordner-Schritt im Onboarding legt den Ordner
  in jedem Fall dort an, sodass eine Rückfrage im Zusammenhang käme.
- **Das Symbol ist nicht im Finder angesehen.** Es wird beim ersten Start einer App mit
  diesem Stand auf den gewählten Ordner gesetzt (`iCloud Drive/Codus/Meetings` hat
  kein eigenes Symbol) — dort ist es zu prüfen.
