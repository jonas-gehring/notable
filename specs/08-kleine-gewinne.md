# Spec 08 — Kleine Gewinne

> **Aufwand: je S, zusammen S–M.** Eine Sammlung kleiner, klar abgegrenzter
> Verbesserungen an der täglichen Ergonomie — jede für sich zu klein für eine eigene
> Spec, zusammen spürbar. Die großen Brocken sind Specs 01–07.

Jeder Punkt ist einzeln umsetz- und abschaltbar. Reihenfolge = grob Wert-für-Aufwand.

## A. Nächstes Meeting in der Menüleiste + Erinnerung

- Im `MenuBarExtra`-Menü eine Zeile **„Nächstes: 15:00 Standup (in 12 min)"**, gespeist aus
  dem bestehenden `CalendarMonitor` (EventKit ist schon da, read-only).
- Optional eine **lokale Notification** bei Meeting-Beginn: „Standup startet — aufzeichnen?"
  — dockt direkt an den Consent-Flow (`ConsentCoordinator`) an, den es schon gibt.
- **Datenquelle vorhanden**, kein neues Recht (Kalender ist bereits integriert).
- Settings-Toggles: „Nächstes Meeting in der Menüleiste zeigen", „Bei Meeting-Beginn
  erinnern".

**Aufwand: S–M.** Wert: hoch für tägliche Meeting-Nutzung. Reuse pur.

## B. Medien pausieren / System stumm beim Diktat

- Beim Start eines Diktats laufende Medienwiedergabe pausieren (Media-Key `F8`/
  `NX_KEYTYPE_PLAY` via `IOKit`/`CGEvent`), beim Ende optional fortsetzen; oder
  System-Ausgabe kurz stummschalten, damit Podcast/Musik das Mikro nicht überlagert.
- Zwei getrennte Toggles, **beide Default AUS** (Eingriff ins System, nur auf Wunsch).
- Edge: nichts fortsetzen, was der Nutzer selbst pausiert hat (nur den eigenen Eingriff
  rückgängig machen).

**Aufwand: S.** Wert: mittel (nur wer beim Musikhören diktiert).

## C. Akustische Cues

- Kurzer, dezenter Ton bei Aufnahme-Start und -Ende (und optional bei „eingefügt"). Gibt
  haptisch/akustisch Sicherheit, dass der Hotkey griff — ergänzt das visuelle Overlay.
- Ein Toggle „Töne", Default AUS oder sehr leise. `NSSound`/Systemsound, keine Assets nötig.

**Aufwand: S.** Wert: mittel, reine Ergonomie.

## D. Idle-Timeout für den Freihand-Lock

- Der Freihand-Lock (Doppel-Tap) hat heute nur das 10-Minuten-Hardcap
  (`DictationController.maximumRecordingSeconds`). Ergänzend: **nach X Sekunden Stille**
  automatisch beenden (VAD/RMS ist im Level-Callback schon verfügbar) — vergessene
  Lock-Sessions enden von selbst.
- Settings: „Freihändig nach Stille beenden nach … s" (z. B. 0 = aus, Default aus/konservativ).

**Aufwand: S.** Wert: mittel, verhindert vergessene offene Aufnahmen.

## E. Meeting-Hook (Automatisierungs-Ausgang)

- Nach Abschluss eines Meetings ein **benutzerdefiniertes Skript** ausführen, dem der Pfad
  der fertigen Markdown-Datei (und/oder JSON mit Metadaten) übergeben wird — z. B. „push
  nach Obsidian", „an Ort X kopieren", „Webhook feuern".
- Für ein Personal-Tool trivial und mächtig: ein `Process`-Aufruf mit Timeout, Muster wie
  `ClaudeCodeCLIProvider` (Spawn + Timeout + SIGTERM/SIGKILL).
- **Sicherheit:** nur ein vom Nutzer in Settings gewählter Pfad, kein Default, klarer Hinweis.
  Fehler sichtbar, nie still.
- Settings: „Skript nach Meeting-Ende ausführen" + Pfad-Auswahl + Timeout.

**Aufwand: S.** Wert: hoch für Power-User-Workflows, null Scope-Konflikt.

## Bewusst nicht dabei

- **Meeting-Templates** (wählbare Summary-Struktur) — gestrichen, eine gute Struktur reicht.
- **Weitere STT-/LLM-Backends** — die Anbieter-Auswahl steht; ein lokales Modell bleibt
  Someday-Roadmap.
- **Agentische Diktat-Aktionen** (Sprache steuert die Maschine) — anderes Produkt, klar
  außerhalb des Scopes.
- **Kontaktdatenbank** — Attendee-Namen fließen nur in die Sprecher-Benennung.

## Tests

- Pro Unterpunkt klein: A (nächstes-Event-Auswahl pur über `CalendarMonitor`-Daten),
  D (Idle-Timeout-Zustand über gefakte RMS-Ticks), E (Hook-Spawn mit Fake-Prozess,
  Timeout-Pfad). B/C sind Systemeingriffe → manuell verifizieren.

## Umsetzungsreihenfolge (empfohlen)

1. **A** (nächstes Meeting + Erinnerung) — höchster Alltagswert, reiner Reuse.
2. **E** (Meeting-Hook) — mächtig, klein, kein Scope-Konflikt.
3. **D** (Idle-Timeout) — schließt eine echte Lücke im Lock-Modus.
4. **C** (Töne), **B** (Medien pausieren) — reine Ergonomie, wenn Zeit.
