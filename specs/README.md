# Notable — Feature-Specs

Dieser Ordner enthält die **Entwurfsdokumente** hinter dem gebauten Code: pro Feature
ein Dokument, das den Zweck, die Kernentscheidung und das Hauptrisiko festhält. Sie sind
kein Backlog und keine Roadmap — sie erklären, *warum* der Code so aussieht, wie er
aussieht. Was der Code tut, steht in `CLAUDE.md`; was er im Detail tut, im Code selbst.

Die Nummerierung ist die Reihenfolge, in der die Features entstanden sind.

## Übersicht

| # | Feature | Aufwand | Kern-Risiko | Stand |
|---|---------|---------|-------------|-------|
| [01](01-nutzungsstatistiken.md) | **Nutzungsstatistiken** — Zeitersparnis, Wörter, Meetings pro Tag/Woche/Monat/Jahr, Charts | M | rein additiv, kein Risiko im Kernpfad | gebaut |
| [02](02-chat-mit-transkript.md) | **Chat mit Transkript** — Fragen an ein Meeting stellen | M–L | Kontextfenster, Provider-Roundtrips | gebaut |
| [03](03-app-kontext-formatierung.md) | **App-kontextabhängige Formatierung** — Ton/Format je fokussierter App, rein offline/regelbasiert | M | rein lokal, keine Zusatzlatenz | gebaut |
| [04](04-voice-commands.md) | **Voice-Commands & Text per Stimme bearbeiten** | L | schickt markierten Fremdtext raus — siehe Datengrenze unten | ⛔ zurückgestellt |
| [05](05-live-partial-text.md) | **Live-Partial-Text** — inkrementelles Decoding langer Diktate | S–M | war aus Stabilitätsgründen aus | gebaut |
| [06](06-woerterbuch-auto-learn.md) | **Wörterbuch-Auto-Learn** — Korrekturen werden zu Vorschlägen | S | vorhandenes Gerüst aktivieren | gebaut |
| [07](07-onboarding.md) | **Onboarding-Flow** | M | Fenster-/Fokus-Verhalten der Menübar-App | gebaut |
| [08](08-kleine-gewinne.md) | **Kleine Gewinne** — nächstes Meeting in der Menüleiste, Meeting-Hook, Idle-Timeout, Töne, Medien pausieren | S–M | mehrere kleine, unabhängige Änderungen | gebaut |
| [09](09-call-lifecycle-notifications.md) | **Call-Lifecycle** — Join-Hinweis, automatisches Ende, Fertig-Meldung | M | Ende-Erkennung pro Prozess | gebaut |
| [10](10-bootstrap-modell-hotswap.md) | **Vorschalt-Modell & unterbrechungsfreier Modellwechsel** — der erste Start ist sofort diktierfähig | M | Kernpfad Diktat, Tausch nur im Leerlauf | gebaut |
| [11](11-modell-ergonomie-sprachprofil.md) | **Modell-Ergonomie & Sprachprofil** — Größe/Status/Fortschritt am Picker, `de`+`en` für den Polisher | S | `TextPolisher.isEnglish` liegt im Kernpfad | gebaut |
| [12](12-prozess-supervision.md) | **Prozess-Supervision** — Absturzerkennung, KeepAlive-LaunchAgent | S–M | Neustart-Schleife, zwei Startpfade | ⏸ zurückgestellt |
| [13](13-ios-capture-companion.md) | **iOS-Capture-Companion** — das iPhone nimmt auf, der Mac transkribiert | ~7 Tage | iCloud-Entitlement bei Developer-ID-Verteilung | 📋 Entwurf |
| [14](14-ios-vollport.md) | **Notable für iOS/iPadOS** — eigenständiger Client, On-Device-ASR, CloudKit-Sync | ~4 Wochen | ASR-Tempo auf dem Telefon, CloudKit ohne Ausweichweg | 📋 Entwurf |
| 15–19 | **Textverbesserung, Aufbewahrung, Notch-HUD, Textbausteine, Statistik-Ausbau** — als GitHub-Issues #1–#5 geschrieben, nicht als Datei | — | — | gebaut, archiviert in `notable-issues-archiv-20260902.md` |
| [20](20-modellverwaltung.md) | **Modellverwaltung** — 1,1 GB Modelle sichtbar, reparierbar, an die App-Version gebunden | S + M–L | FluidAudio lädt von `resolve/main` — es gibt keine Revision | Stufe 1 gebaut, Stufe 2 neu gefasst und offen |
| [21](21-spool-format-und-speicherplatz.md) | **Spool-Format & sichtbarer Speicherplatz** — Int16 statt Float32, ALAC im Archiv, die Zahl endlich sichtbar | S + S–M + S | ein Formatfehler zerstört die Notfallkopie | gebaut |
| [22](22-oberflaeche-entdoppeln.md) | **Oberfläche entdoppeln** — eine Implementierung je Begriff, eine Datei je Einstellungsseite | M | reiner Umbau ohne Testkriterium außer „vorher genauso" | gebaut |

**Aufwand:** S ≈ 1 Tag, M ≈ 2–4 Tage, L ≈ 1 Woche.

**Zu 20–22:** Sie stammen nicht aus einem Feature-Wunsch, sondern aus einer Messung an
der produktiven Installation am 2026-09-07 — 5,1 GB Platzbedarf, den die App nirgends
nennt, davon rund die Hälfte reines Format. Sie sind unabhängig voneinander und in
dieser Reihenfolge sinnvoll: 21 gibt sofort Platz zurück, 20 macht den zweitgrößten
Posten überhaupt erst sichtbar, 22 ist Pflege ohne sichtbaren Effekt. Keine von ihnen
fügt eine Funktion hinzu.

Umgesetzt am 2026-09-09, mit drei Abweichungen, die beim Bauen sichtbar wurden und in
den Specs selbst nachgetragen sind: die `config.json` der Modelle ist leer, also kommt
die Vollständigkeitsprüfung aus FluidAudios eigenem `ModelNames`; ebenso die Liste der
aktuellen Verzeichnisnamen, was das Hauptrisiko von Spec 20 weitgehend erledigt. Und
WhisperKit lud seine Modelle nach `~/Documents` — davon stand in keiner Spec etwas.
**Offen ist Stufe 2 von Spec 20** (Modelle als Release-Assets): eine eigene
Entscheidung, weil sie rund ein Gigabyte an jedes Release hängt.

Daneben liegen die Specs der ersten Ausbaustufe — `note-management-ui.md`,
`speaker-naming.md`, `auto-detect-consent.md`, `release-and-signing.md` und die
`INTEGRATION-*.md` — sowie `ROADMAP.md` als Übersicht über die Ausbaustufen.

**Zu 13 und 14:** Sie sind **Alternativen zueinander**, keine Abfolge, mit der
Empfehlung, 13 zuerst zu bauen und einen Monat zu leben. Beide kippen die Festlegung
„iOS: not pursued" in `CLAUDE.md`. Was auf iOS **prinzipiell** nicht geht (Telefonate
mitschneiden, System-Audio, Auto-Erkennung, Diktat ins fremde Textfeld), steht in
[13](13-ios-capture-companion.md) §1.1 — vor jeder weiteren Diskussion dort lesen.

## Die Datengrenze

Sie ist die eine Festlegung, an der jede Spec hängt:

> **Audio verlässt das Gerät nie.** Architektur, kein Schalter.
>
> **Meeting-Transkripttext** geht an die Zusammenfassungs-Anbieter — daraus entstehen
> Summary, Sprechernamen und Chat.
>
> **Diktattext verlässt das Gerät nur auf ausdrücklichen Abruf** — per eigenem Hotkey
> oder Menüpunkt, nie automatisch nach einem Diktat, und nur über einen der
> CLI-Anbieter. Der automatische Polish nach jedem Diktat ist offline und regelbasiert.

Zur Klarstellung, weil die Verwechslung nahe liegt: eine CLI ist **nicht lokal**.
`claude -p` ist ein lokal gestarteter Prozess, der Text an einen Anbieter schickt.

Konsequenzen für die Specs:

- **Spec 03** ist deshalb rein offline/regelbasiert. Die erwogene KI-Reformatierung ist
  gestrichen — sie hätte Diktattext gesendet.
- **Spec 04** bleibt zurückgestellt: markierter Text aus fremden Apps ist eine andere
  Datenklasse als ein Diktat, das Notable selbst gerade aufgenommen hat. Zulässig nur
  mit einem lokalen Modell.
- Jeder Lauf der Diktat-Verbesserung wird in `llm_usage` gebucht, auch wenn die Antwort
  verworfen wurde. Die Zeile zählt, wie oft Diktattext das Gerät verlassen hat.

## Bewusst nicht gebaut

- **Export / Teilen (PDF, Share-Sheet).** Die Markdown-Dateien im Notizen-Ordner sind
  der Austauschpunkt.
- **Meeting-Vorlagen** (wählbare Summary-Struktur). Eine gute Struktur reicht.
- **Cloud-ASR.** Audio verlässt das Gerät nicht — das schließt jeden Cloud-Erkenner aus.
- **Absätze an echten Sprechpausen** (Spec 03). Ohne Wortzeiten aus der ASR nur mit einer
  Protokolländerung im latenzkritischen Diktatpfad zu haben. Umgesetzt ist der Fallback:
  Umbruch nach je drei Sätzen, nie mitten im Satz.

## Querschnitts-Prinzipien

Gelten für alle Specs und werden in jeder vorausgesetzt:

1. **Audio bleibt auf dem Gerät.** Nur Transkript-*Text* verlässt es.
2. **Kein stilles Versagen.** Jedes Feature meldet Fehler sichtbar (Overlay/Menü/UI) und
   fällt nie lautlos auf No-op zurück.
3. **SQLite ist die Wahrheit, Markdown die Projektion.** Neue Daten landen zuerst in
   SQLite, Views rendern daraus.
4. **Pure Kernlogik, testbar.** Rechnung, Parsing und Zustandsmaschinen sind pure
   Funktionen mit Unit-Tests (Muster: `PTTStateMachine`, `TextPolisher`, `SummaryParser`).
5. **Menübar-Fenster müssen aktiv nach vorn geholt werden** (`NSApp.activate` + gezieltes
   `makeKeyAndOrderFront`).

## Schema-Migrationen

Seit v1.1.0 laufen sie **nummeriert** über `PRAGMA user_version` in `SQLiteConnection`
— das frühere idempotente `migrateAddColumn` in `RecordingStore.ensureOpen()` verwarf
jeden Fehler außer dem erwarteten und meldete ihn später als „no such column" aus einer
fremden Query. Über alle Specs hinweg kamen hinzu:

- `recordings.word_count INTEGER` (Spec 01)
- `recordings.source_app TEXT` (Spec 03, auch von der Statistik genutzt — ein Name, eine
  Spalte, nicht zwei)
- `recordings.raw_text TEXT` — der polierte Text vor der LLM-Verbesserung; sonst ist nicht
  nachvollziehbar, was das Modell getan hat
- `recordings.engine TEXT`, `recordings.latency_ms INTEGER`, `recordings.enhanced INTEGER`
- neue Tabelle `chat_messages` (Spec 02)
- neue Tabelle `dictionary_candidates` (Spec 06)
- `recordings.calendar_event_title TEXT`, `recordings.attendees TEXT` — Kalendertitel
  und Teilnehmerliste lagen nur im Frontmatter, also verlor sie jedes Umbenennen
- FTS5-Tabelle `segments_fts` über `segments.text`, trigger-synchronisiert

Alle neuen Spalten sind nullable und werden **nicht** rückwirkend befüllt: die
Bestandsdaten hatten diese Werte nie, und eine geschätzte Zahl in einer Statistik ist
schlimmer als eine fehlende.
