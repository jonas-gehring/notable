# Spec 12 — Prozess-Supervision (Autostart + Neustart nach Absturz)

> **Aufwand: S–M.** Ein LaunchAgent mit `RunAtLoad` **und** `KeepAlive`: die App startet
> bei Anmeldung und wird nach einem Absturz automatisch wiederbelebt.
> **Status: ZURÜCKGESTELLT.** Stufe 1 (§3, Absturzerkennung) ist sofort baubar und liefert
> die Datenlage; Stufe 2 (§4, KeepAlive) erst, wenn Stufe 1 tatsächlich Abstürze belegt.

## 1. Ausgangslage (Fakten aus dem Code)

- Autostart existiert: Toggle „Bei Anmeldung starten" → `SMAppService.mainApp.register()` /
  `.unregister()` (`SettingsView.swift:110-124`), Fehler werden angezeigt
  (`loginItemError`, `:124`).
- **Kein Neustart nach Absturz.** Stirbt der Prozess, ist die Menüleisten-App weg; auffallen
  kann das erst beim nächsten Hotkey-Druck, der dann wirkungslos bleibt.
- **Kein Absturz-Protokoll.** `AppDelegate` (`NotableApp.swift:27`) bootet Diktat, verdrahtet
  den Meeting-Detektor und fährt die Spool-Wiederherstellung — es gibt aber keine Markierung
  dafür, ob die letzte Sitzung sauber endete.
- Für Meetings ist der Datenverlust schon abgefedert: `SpoolStore` schreibt rohes PCM
  fortlaufend auf Platte und wird beim nächsten Start wiederhergestellt.

## 2. Warum zurückgestellt

Der Gegenwert ist schmaler, als er klingt:

- Ein neu gestarteter Prozess **rettet kein laufendes Meeting.** Der CoreAudio-Process-Tap ist
  mit dem Prozess tot; Audio ab dem Absturzzeitpunkt ist verloren. Was zu retten war, rettet
  `SpoolStore` beim nächsten Start ohnehin — auch bei manuellem Start.
- Für Diktat ist der Gewinn „Hotkey funktioniert wieder, ohne dass ich die App suche". Real,
  aber klein.
- Das Risiko liegt auf der anderen Seite: ein Absturz **beim Start** (fehlendes Modell,
  defekte DB, TCC-Reset) wird mit `KeepAlive` zur Neustart-Schleife, die CPU zieht und deren
  Ursache man erst im Log findet.
- Es gibt bis heute **keinen belegten Absturz**. Ohne Zahlen ist das Aufwand ohne Anlass.

Deshalb: erst messen (§3), dann entscheiden (§4).

## 3. Stufe 1 — Absturzerkennung (empfohlen, klein)

Ein Flag, das ein sauberes Ende bezeugt:

- Beim Start eine Marker-Datei anlegen (neben dem Spool-Verzeichnis, damit alles
  Diagnostische an einem Ort liegt) mit Startzeit, Version, aktivem Modus.
- `applicationWillTerminate` (bzw. der reguläre Beenden-Pfad) löscht sie.
- Ist die Datei beim Start **noch da**, endete die letzte Sitzung unsauber → Eintrag im Log
  und eine sichtbare, quittierbare Meldung im Menü („Letzte Sitzung endete unerwartet —
  Details im Log"), im Stil der bestehenden `statusMessage`-Meldungen.
- Wenn zum Zeitpunkt des Absturzes ein Meeting lief, ist das genau der Fall, den
  `spool-failed` schon kennt — die beiden Hinweise gehören in eine Meldung, nicht in zwei.

Das kostet wenig, ist rein additiv und liefert nach ein paar Wochen die Antwort auf die Frage,
ob §4 überhaupt gebraucht wird.

## 4. Stufe 2 — LaunchAgent mit KeepAlive (nur bei belegtem Bedarf)

Wenn Stufe 1 Abstürze zeigt:

- Ein LaunchAgent-plist **im Bundle** (`Contents/Library/LaunchAgents/`, Label z. B.
  `de.jonasgehring.notable.agent`), registriert über `SMAppService.agent(plistName:)`.
- `RunAtLoad = true` (ersetzt den heutigen Login-Item-Zweck).
- `KeepAlive = { SuccessfulExit: false }` — **nicht** `KeepAlive = true`. Sonst startet das
  eigene „Beenden" die App sofort wieder, und man kann sie nicht mehr abschalten.
  Voraussetzung: der reguläre Beenden-Pfad endet mit Exit-Code 0 (heute `NSApp.terminate`;
  prüfen, dass kein `exit(1)`-Pfad existiert).
- `ThrottleInterval` deutlich über dem Default (z. B. 30 s) als Bremse gegen Startup-Crash-Schleifen.
- **Danach `SMAppService.mainApp` abmelden.** Zwei Startpfade parallel wären ein Bug: doppelte
  Instanz oder ein Toggle, der nichts mehr tut. Der bestehende Toggle in Settings schaltet dann
  den Agent (`register`/`unregister`), Label und Hinweistext entsprechend anpassen.
- **Migration** für die eigene Installation beschreiben: bestehende Login-Item-Registrierung
  entfernen, Agent registrieren, einmal ab-/anmelden zum Prüfen.
- **TCC**: bleibt unberührt, weil derselbe Bundle-Pfad (`/Applications/Notable.app`) und dank
  Developer-ID-Signatur eine stabile Designated Requirement. Trotzdem nach dem Umbau alle drei
  Berechtigungen einmal aktiv verifizieren (Mikrofon, Eingabeüberwachung, Systemaudio) —
  Berechtigungen sind bei diesem Projekt schon zweimal zum Problem geworden.

## 5. Edge Cases

- **Neustart-Schleife** trotz `ThrottleInterval`: Wenn Stufe 1 drei unsaubere Starts in Folge
  protokolliert, soll die App den Agent selbst deaktivieren und das melden, statt weiter zu
  kreisen.
- **Nutzer beendet absichtlich** → kein Neustart (`SuccessfulExit: false` deckt das ab, und
  genau das ist zu testen).
- **Update-Installation**: `UpdateInstaller` tauscht das Bundle im Betrieb und startet neu.
  Mit KeepAlive darf daraus kein Wettlauf werden — der Tausch-/Relaunch-Pfad ist vor der
  Aktivierung einmal gegen den Agent zu prüfen.
- **Zwei Instanzen** (Agent startet, während die App schon läuft): Single-Instance-Schutz per
  Bundle-Identifier prüfen.

## 6. Abbruchkriterium

Protokolliert Stufe 1 über mehrere Wochen täglicher Nutzung **kein** unsauberes Ende, wird
diese Spec geschlossen und §4 gestrichen. Das ist ein legitimes Ergebnis, kein offener Rest.

## 7. Nicht-Ziele

- Kein eigener Watchdog-Hilfsprozess. Wenn Supervision, dann von launchd.
- Keine Wiederaufnahme eines laufenden Meetings nach dem Absturz — nur Wiederherstellung des
  bereits gespoolten Audios, wie heute.
- Kein Absturzbericht nach außen. Es verlässt nichts das Gerät; das Log bleibt lokal.
