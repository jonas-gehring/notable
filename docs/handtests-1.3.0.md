# Handtests vor v1.3.0

Was die Testsuite nicht sehen oder hören kann — aus den Abnahmen von Spec 28–33 und
den offenen Punkten von 23, 25 und 27. Jede Zeile: abhaken oder den Befund
dahinterschreiben; das Ergebnis gehört danach in den §8/§9 der jeweiligen Spec.

Getestet an der installierten App (`/Applications/Notable.app`), nicht am Debug-Build
— der startet nicht, solange die installierte läuft.

## Diktat — Kernschleife (Spec 29)

- [ ] Diktat, sofort ein zweites während „Transkribiere…": beide Texte landen in der
      gesprochenen Reihenfolge.
- [ ] Esc während Aufnahme, Transkription und Verbesserung: nichts wird eingefügt, und
      Esc kommt in der fokussierten App nicht an.
- [ ] Mikrofon in den Systemeinstellungen entziehen, Taste drücken: Meldung **beim
      Drücken**. Erlaubtes, aber stummes Gerät: „Nichts gehört (Gerät X)".
- [ ] ⌘Tab während der Transkription: nichts eingefügt, Text in der Zwischenablage,
      Hinweis sagt es, „Letzte Diktate" zeigt den Eintrag.
- [ ] AirPods mitten im Satz verbinden: der ganze Satz kommt an, HUD sagt
      „Mikrofon: AirPods".
- [ ] Freihändig (Tap) mit der Verbessern-Taste beenden: keine neue Zeile in
      `llm_usage`.
- [ ] Passwortfeld fokussiert, Taste drücken: „Sicheres Eingabefeld", keine Aufnahme.
- [ ] 0,25 s halten: „zu kurz" mit Ton, kein Lock. 0,1 s tippen: Lock.
- [ ] Freihändig, 45 s nichts sagen: Aufnahme endet von selbst und wird transkribiert.

## HUD und Klänge (Spec 28, 30)

- [ ] Einstellungen → Diktat-Anzeige „Rechts am Rand": nächstes Diktat zeigt die
      Kapsel rechts, mittig, ohne Neustart.
- [ ] Aufnahme → Transkribiere → Fehler: die rechte Kante der Kapsel bleibt stehen,
      die Kapsel wächst nach links.
- [ ] Kapsel über einem weißen Dokument und über einem Video lesbar
      (`.regularMaterial`; sonst `.thickMaterial` — Spec 30 §7).
- [ ] Reduce Motion einschalten: Ein-/Ausblenden sofort, ohne Neustart.
- [ ] 5-s-Diktat zeigt keinen Spinner, 60-s-Diktat nach 300 ms.
- [ ] Start, Lock, Fertig, Abbruch, Fehler sind hörbar und unterscheidbar.
- [ ] ×-Knopf in der Kapsel bricht ab; ein Klick daneben landet in der App darunter,
      und das Diktat wird trotzdem ins richtige Feld eingefügt.
- [ ] Mikrofon entzogen, diktieren: „Mikrofonzugriff fehlt." mit Hinweiszeile; Menü
      zeigt „Fehlgeschlagenes Diktat · hh:mm"; nach Erteilen fügt **Wiederholen** ein.

## Textregeln (Spec 31)

- [ ] „das ist gut. dann weiter" → „Das ist gut. Dann weiter".
- [ ] „zweiundzwanzig Euro fünfzig" → „22,50 €"; „halb drei" → „2:30";
      „am dritten März" → „am 3. März"; „ein paar Tage" bleibt.
- [ ] „Also, ich denke, sozusagen, dass das geht" → „Ich denke, dass das geht".
- [ ] 40-s-Diktat mit zwei deutlichen Pausen: Absätze genau dort.
- [ ] Safari, Ship Studio, Claude, Ghostty werden als App erkannt (Einstellungen →
      Erweitert → App-Zuordnung).

## Einstellungen und Fenster (Spec 33)

- [ ] ⌘C/⌘V/⌘Z/⌘A im Chat, im Notiz-Editor und im Textbaustein-Editor.
- [ ] Menü mit gedrückter ⌥: „Call-Fenster auslesen…" statt „Meeting aufzeichnen".
- [ ] Statistik-Fenster verschieben, schließen, wieder öffnen: gleiche Position.
- [ ] „Über Notable" zeigt 1.3.0; Hilfe-Menü vorhanden.
- [ ] Englische Oberfläche einmal durchklicken: kein deutscher Satz.

## Meeting (Spec 23, 24)

- [ ] Call mit **zugeklapptem Deckel** über Headset/AirPods: Mikrofonspur nicht stumm,
      `Ich`-Segmente im Transkript, Menüzeile „Mikrofon: …" nennt das Headset.
- [ ] Im selben Call: Einstellungen → Meetings → Erweitert → „Call-Fenster jetzt
      auslesen". Ergebnis liegt in `~/Library/Logs/Notable/screen-probe/` — das ist
      die Stufe-0-Messung, ohne die es keine Adapter gibt.
- [ ] Sprecher-Dialog einer neuen Notiz: „Sprecher ?" ist nicht umbenennbar und
      kein Ziel für „Zusammenführen"; die Hauptstimme heißt „Sprecher 1".

## Update und Ordner (Spec 25, 27)

- [ ] `scripts/test-update.sh` läuft durch (5× ok), Mitteilung „aktualisiert"
      erschienen, Einstellungen → Allgemein zeigt „automatisch".
- [ ] Notizen-Ordner trägt im Finder das Notable-Symbol.

## Nicht auf diesem Mac prüfbar

- Spec 32 (lokales Modell): braucht eingeschaltetes Apple Intelligence, danach
  `TEST_RUNNER_NOTABLE_LOCAL_MODEL=1 … -only-testing:NotableTests/LocalModelProbeTests`.
- Spec 27: TCC beim ersten Zugriff ohne Open-Panel — braucht ein frisches Benutzerkonto.
