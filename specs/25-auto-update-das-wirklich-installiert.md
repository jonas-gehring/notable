# Spec 25 — Updates, die sich tatsächlich selbst installieren

> **Aufwand: M.** Die Funktion existiert — `installUnattended`, Default an, Prüfung beim
> Start und alle sechs Stunden. Nur: sie ist auf echter Hardware nie nachweislich
> gelaufen, ihre wichtigste Bedingung tritt im Alltag selten ein, zwei Zustände, in
> denen ein Neustart Arbeit vernichtet, prüft sie nicht, und hinterher sagt nichts,
> ob sie etwas getan hat. Diese Spec macht aus „wäre möglich" ein „passiert".

## 1. Ausgangslage (Fakten aus dem Code und von der Platte)

### 1.1 Was gebaut ist

- `UpdateChecker` fragt `releases/latest` ab; beim Start höchstens alle 24 h
  (`UpdateChecker.swift:243-254`), danach alle 6 h per Timer
  (`NotableApp.swift:117-124`).
- `UpdateInstaller.installUnattended` (`UpdateInstaller.swift:89-106`): Download,
  `ditto`, **Signaturprüfung gegen die Team-ID der installierten App**, Tausch-Skript,
  Neustart. Default an (`:62-66`). Bedingungen: Schalter an, nicht beschäftigt, **keine
  Meeting-Aufnahme**, Asset ist `.zip`, **kein sichtbares Notable-Fenster mit Titel**.
- Tests decken das Tausch-Skript (Warten, Rollback, Pfade mit Leerzeichen) und das
  Parsen der Team-ID ab (`UpdateInstallerTests`).
- Das Repository ist öffentlich; v1.1.1 hat ein Asset `Notable-1.1.1.zip` (11 MB).

### 1.2 Warum man davon nichts merkt

- **Auf diesem Rechner lief der Pfad nie.** `/Applications/Notable.app` trägt
  13:32:26, das Release v1.1.1 wurde um 13:32:57 veröffentlicht — installiert hat
  `scripts/install.sh`, 31 Sekunden bevor der Updater etwas hätte finden können. Auf
  dem Build-Rechner ist das bei jedem Release so. (Die Log-Einträge `Auto-Update
  übersprungen` ließen sich aus dieser Sitzung nicht lesen: `log show` lieferte für das
  Subsystem null Zeilen.)
- **Die Fenster-Bedingung ist der Normalfall, nicht die Ausnahme** (`:101`). Notizen-,
  Statistik- und Einstellungsfenster sind zum Offenlassen gebaut (`NSWindow Frame
  notes` steht in den Defaults). Solange eines offen ist, wartet das Update — beim
  nächsten Versuch in sechs Stunden wieder, still, nur mit `log.notice`.
- **Zwei Zustände, in denen ein Neustart Arbeit vernichtet, prüft niemand:**
  - **Ein Diktat läuft** (Aufnahme, Transkription, Verbesserung, Einfügen). Der
    Installer bekommt nur `meeting.state.isRecording` (`NotableApp.swift:25`).
  - **Eine Notiz wird produziert** (`processingCount > 0`: Transkription, Benennung,
    Zusammenfassung — bei einem einstündigen Meeting mehrere Minuten). Auch
    `applicationShouldTerminate` wartet nur auf die Aufnahme (`NotableApp.swift:184`).
    Die Wiederherstellung holt die Notiz beim nächsten Start aus dem Spool nach — mit
    Minuten doppelter Arbeit, und eine API-Zusammenfassung, die schon lief, wird ein
    zweites Mal bezahlt.
- **Ein Fehlschlag lässt Notable verschwunden zurück.** Im Tausch-Skript endet der
  Zweig „`mv` fehlgeschlagen" mit `exit 1` **ohne** `open` (`UpdateInstaller.swift:355`).
  Die App hat sich zu dem Zeitpunkt schon beendet. Unbeaufsichtigt heißt das: kein
  Menüleisten-Symbol, kein Diktat, bis es jemand merkt.
- **Ein gefundenes Update wird vergessen.** `available` ist nicht persistiert
  (`UpdateChecker.swift:178`); nach einem Neustart innerhalb von 24 h kehrt
  `checkOnLaunch` früh zurück (`:245-251`) und weiß von nichts, bis zum nächsten
  6-h-Takt.
- **Hinterher sagt nichts etwas.** Nach einem erfolgreichen Tausch gibt es keine
  Meldung „auf 1.2.0 aktualisiert", in den Einstellungen keine Zeile „zuletzt
  automatisch aktualisiert", und kein sichtbarer Grund, warum ein Update wartet. Ob die
  Funktion arbeitet, ist von außen nicht zu erkennen — darum wirkt sie, als gäbe es
  sie nicht.

## 2. Ziel

Ein veröffentlichtes Release läuft **innerhalb weniger Stunden** auf diesem Mac, ohne
Klick, **nie** auf Kosten eines Diktats, eines Meetings, einer Notiz in Arbeit oder
eines ungespeicherten Entwurfs — und hinterher steht da, dass es passiert ist.

## 3. Konzept

### 3.1 `UpdateWindow` — wann ist ein ruhiger Moment (pure)

Eingaben: Aufnahme-Zustand, `processingCount`, Diktat-Zustand, ungespeicherter Entwurf
(„Eigene Notizen" im Notizen-Fenster in Bearbeitung), HID-Leerlauf in Sekunden
(`CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)`, braucht keine
Berechtigung), Bildschirm gesperrt, sichtbare Fenster.

| Bedingung | Entscheidung |
|---|---|
| Aufnahme, Verarbeitung, Diktat ≠ idle, Entwurf offen | **warten** (harte Sperre) |
| sonst: kein Fenster sichtbar | **jetzt** |
| sonst: Leerlauf ≥ 10 min **oder** Bildschirm gesperrt | **jetzt**, Fenster danach wiederherstellen |
| sonst | warten |

Ausgabe `.installNow` / `.wait(Reason)`. Tabellengetestet, jede Zeile.

### 3.2 Takt: warten ist billig, prüfen nicht

- Die **Netzwerk**-Prüfung bleibt beim 6-h-Takt.
- Liegt ein Update bereit, wird `UpdateWindow` **jede Minute** ausgewertet (lokal,
  kostenlos), zusätzlich bei `screensDidSleepNotification` und
  `sessionDidResignActiveNotification`.
- **Vorab laden:** Sobald ein Update gefunden ist, wird das Zip im Hintergrund geladen,
  entpackt und **die Signatur geprüft**. Ein fehlerhaftes Release fällt dann sofort auf
  und nicht erst im ruhigen Moment um drei Uhr nachts; der Tausch selbst dauert danach
  nur noch die eine Sekunde.

### 3.3 Nichts vergessen

`updatePendingVersion` (Tag, Download-URL, Release-URL, Notizen) in die Defaults,
sobald gefunden; beim Start zuerst zurückgelesen. Gelöscht, sobald die laufende Version
≥ der gespeicherten ist oder die Version übersprungen wurde.

### 3.4 Beenden nur ohne Verlust

- `applicationShouldTerminate` wartet auch auf `processingCount == 0` (Menüstatus
  „Beende nach Fertigstellung der Notiz …"). Das schützt auch ⌘Q, nicht nur den Updater.
- Der Installer bekommt statt `isRecording` eine Abfrage `isBusy` über alle harten
  Sperren aus 3.1 — dieselbe Funktion, damit die zwei Stellen nicht auseinanderlaufen.

### 3.5 Jeder Ausgang des Tausch-Skripts startet eine App

Nach dem Beenden startet **jeder** Zweig `open "$dest"` — auch „`mv` fehlgeschlagen",
wo die alte Version unangetastet am Platz liegt. Einzige Ausnahme bleibt „Prozess lebt
noch" (dann läuft die App ja). Neuer Test in `UpdateInstallerTests` im Muster der
vorhandenen Skript-Tests.

### 3.6 Fenster wiederherstellen

Vor dem Beenden `updateRestoreWindows = ["notes", "stats", …]` (die IDs, die
`AppContainer.presentWindow` kennt); beim Start einmal öffnen, **nicht aktivierend**,
dann löschen. Wer nach der Mittagspause zurückkommt, findet seine Fenster, wo sie waren.

### 3.7 Hinterher sagen, dass es passiert ist

- Vor dem Beenden `updateInstalledFrom = "1.1.1"`, `updateInstalledAt`,
  `updateInstalledUnattended`.
- Beim Start, wenn die laufende Version größer ist: **eine** Mitteilung „Notable wurde
  auf 1.2.0 aktualisiert" — Klick öffnet Einstellungen → Allgemein mit den
  Release-Notes (`ReleaseNotes` existiert).
- Einstellungen → Updates: „Zuletzt aktualisiert: 12.09., 03:14 — automatisch".

### 3.8 Warten sichtbar machen

- Einstellungen: „1.2.0 wartet auf einen ruhigen Moment — gerade: Meeting wird
  verarbeitet." (Text aus `Reason`.)
- Wartet ein Update **72 h**, und der einzige Grund sind offene Fenster während aktiver
  Nutzung: eine Mitteilung mit „Jetzt installieren". Harte Sperren lösen sie nie aus.

### 3.9 Einmal echt durchlaufen lassen

Weil der Build-Rechner jedes Release vorab installiert, gibt es sonst keinen Beweis.

- `UpdateChecker` liest die Feed-URL aus `updateFeedURL` (nur Debug-Builds, sonst die
  feste GitHub-URL).
- `scripts/test-update.sh`: baut dieselbe App als `9.9.9-test`, signiert mit derselben
  Identität, zippt, serviert Zip und ein nachgebautes `releases/latest`-JSON über
  `python3 -m http.server` und wartet auf den Tausch. Danach: Version ist 9.9.9,
  `AXIsProcessTrusted()` und Mikrofonstatus unverändert (die TCC-Zusagen hängen an der
  Designated Requirement, die bei gleicher Developer-ID gleich bleibt — `install.sh`
  tauscht das Bundle schon heute genauso).

## 4. Integration

- **Neu `Update/UpdateWindow.swift`** (pure).
- **`UpdateInstaller`** — `isBusy`-Abfrage statt `isRecording`, Vorab-Laden,
  Skript-Fix, Restore-/Installed-Marker.
- **`UpdateChecker`** — Persistenz von `available`, Feed-URL im Debug.
- **`NotableApp`** (`AppDelegate`) — 1-min-Auswertung, Schlaf-/Sperr-Beobachter,
  `applicationShouldTerminate` wartet auf Verarbeitung, Mitteilung nach dem Update,
  Fenster wiederherstellen.
- **`DictationController`** — öffentlicher Leerlauf-Zustand für `isBusy`.
- **`NoteListView`** — Entwurf-offen-Flag.
- **`GeneralSettingsView`** — Warte-Grund, „Zuletzt aktualisiert", Fußtext anpassen
  (heute: „kein offenes Notable-Fenster").
- **`NotificationCenterService`** — „aktualisiert"-Mitteilung.

## 5. Risiken

- **Die Leerlauf-Heuristik irrt:** jemand liest zehn Minuten eine Notiz, ohne Maus
  oder Tastatur anzufassen, und das Fenster schließt sich. Abgefangen durch 3.6 (es
  kommt eine Sekunde später zurück) und die harte Sperre für Entwürfe.
- **Ein kaputtes Release installiert sich jetzt wirklich.** Die Signaturprüfung schützt
  vor fremden, nicht vor eigenen Fehlern. Deshalb 3.9 vor jedem Release, das den
  Updater selbst anfasst — ein Updater, der sich kaputt aktualisiert, lässt sich nicht
  mehr per Update reparieren.
- **Der Neustart um drei Uhr nachts:** Menüleisten-App, eine Sekunde, Fenster kommen
  zurück. Kein Risiko, solange 3.1 die harten Sperren hält.

## 6. Abnahme

- `test-update.sh` läuft durch: neue Version aktiv, Berechtigungen intakt, Mitteilung
  „aktualisiert" erscheint, Einstellungen zeigen „automatisch".
- Kein Tausch während Diktat, Aufnahme oder Verarbeitung (Tests mit injiziertem
  Zustand); ⌘Q während der Verarbeitung wartet auf die Notiz.
- `mv`-Fehler im Tausch-Skript: die alte App läuft danach wieder.
- Neustart der App mit gefundenem, noch nicht installiertem Update: es wird ohne neue
  Netzwerkprüfung installiert.
- Offenes Notizen-Fenster + 10 min Leerlauf: Update installiert, Fenster ist danach
  wieder da.

## 7. Stand des Baus (2026-09-11)

3.1–3.9 sind gebaut. Abweichungen und was offen ist:

- **`scripts/test-update.sh` ist geschrieben, aber nicht gelaufen.** Es ersetzt
  `/Applications/Notable.app`, und die Installation ist auf später gestellt. Damit
  fehlt der eine Beweis, um den es in 3.9 geht — bis zu diesem Lauf ist der Pfad
  getestet, aber nicht nachgewiesen. Zwei Annahmen prüft erst er: dass App Transport
  Security `http://127.0.0.1` durchlässt, und dass SwiftUI das `NSWindow` einer
  `Window`-Szene nach deren id benennt (davon hängt das Wiederherstellen der Fenster
  ab; abgeglichen wird per Präfix).
- **Vorbereiten ist sichtbar.** Das Vorab-Laden setzt dieselben Phasen wie der Knopf;
  das Menü zeigt „Update wird geladen…", und ein kaputtes Release steht sofort als
  „Update fehlgeschlagen" da. Wiederholt wird mit dem 6-h-Takt, nicht jede Minute.
- **Die Signatur wird beim Tausch noch einmal geprüft** — zwischen Vorbereiten und
  ruhigem Moment können Stunden liegen.
- **Auch ein misslungener Tausch wird gemeldet** („Update nicht installiert — es läuft
  weiter 1.1.1"). Die Spec sah nur die Erfolgsmeldung vor; ohne die zweite sähe ein
  Fehlschlag genauso aus wie ein Updater, den es nicht gibt.
- **„Jetzt installieren" in einer Mitteilung** widerspricht der früheren Regel in
  `NotificationCenterService` (nie aus einer Mitteilung installieren). Es gibt die
  Aktion nur beim 72-h-Hinweis, und sie läuft über den manuellen Pfad mit allen
  harten Sperren.
- **Die Release-Notes der installierten Version werden gemerkt**, damit die Mitteilung
  „aktualisiert" wirklich zu ihnen führt („Neu in …" unter „Zuletzt aktualisiert").
- **⌘Q wartet auf jede Notiz**, auch auf wiederhergestellte, mit der Menüzeile
  „Beende nach Fertigstellung der Notiz …". Ein erzwungenes Beenden gibt es dafür
  nicht.
- Leerlauf und Bildschirmsperre kommen ohne Berechtigung aus
  (`CGEventSource.secondsSinceLastEventType`, `CGSessionCopyCurrentDictionary`); sie
  sind nicht automatisch getestet, nur die Tabelle, die sie speisen.
