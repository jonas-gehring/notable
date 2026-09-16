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
| [23](23-mikrofon-folgt-dem-call.md) | **Das Mikrofon folgt dem Call** — aufnehmen, wo man hineinspricht, statt den Systemstandard zu erben | S + M + S | `kAudioProcessPropertyDevices` ist dünn dokumentiert | gebaut; Abnahme im echten Call offen |
| [24](24-sprechererkennung.md) | **Sprechererkennung** — Teilnehmer und aktiver Sprecher vom Call-Bildschirm, Splitter auflösen, Korrektur, die hält | ½ T + S + S–M + M + M | Call-Oberflächen ändern sich mit jedem App-Update | Stufen 1 + 4 gebaut, 2/3 pur und verdrahtet; Adapter warten auf die Messung (Stufe 0); Stufe 1 nach Messung neu geregelt (§9.2, 2026-09-15: „Sprecher ?", eine große Stimme, Nummer nach Redeanteil) |
| [25](25-auto-update-das-wirklich-installiert.md) | **Updates, die sich tatsächlich installieren** — ruhiger Moment statt „kein Fenster offen", nichts vergessen, hinterher sagen | M | ein kaputtes Release installiert sich jetzt wirklich | gebaut; `test-update.sh` gelaufen (2026-09-15) — fand den fehlenden Neustart, mit Fix grün (§7) |
| [26](26-notizen-einruecken.md) | **Einrücken/Ausrücken in Notizen** — verschachtelte Listen, Tab/⇧Tab, ⌘]/⌘[ | S–M + S | Drift im Markdown-Round-Trip | gebaut |
| [27](27-notizen-ordner-icloud-und-symbol.md) | **Notizen-Ordner** — Notable-Symbol am Ordner, iCloud Drive als Vorgabe für neue Einrichtungen | S (+ S) | TCC beim ersten Zugriff ohne Open-Panel | gebaut, mit Stufe 2; TCC auf frischem Konto offen |
| [28](28-overlay-rechts-am-rand.md) | **Diktat-Anzeige rechts am Rand** — vierter Platz im Picker, Kapsel wächst von der Kante nach innen | S | verdeckt für die Dauer eines Diktats den rechten Fensterrand — deshalb Wahl, nicht Standard | gebaut (2026-09-14); Handtest offen |
| [29](29-kernschleife-haerten.md) | **Kernschleife härten** — zweites Diktat sofort, Esc in jeder Phase, Stille nennt die Ursache, Ziel vor dem Paste, Gerätewechsel ohne Verlust; `DictationPipeline` als Testnaht | M | der latenzkritische Pfad wird umgebaut — `LatencyProbeTests` vorher/nachher | gebaut (2026-09-14), mit Abweichungen (§8); Handtests offen |
| [30](30-hud-und-fehlerflaeche.md) | **HUD und Fehlerfläche** — ein Gesicht, Ein-/Ausblenden, Töne an, `DictationFailure` statt `localizedDescription`, letzter Clip bleibt wiederholbar | S–M + S + S | Stufe 3 (klickbares HUD) berührt die Nie-key-Invariante | alle drei Stufen gebaut (2026-09-14), eigene Klänge; Kontrastmessung und Handtests offen |
| [31](31-regeln-nachziehen.md) | **Regeln nachziehen** — Satzanfänge, `GermanITN`, Füllwörter mit Position, App-Tabelle + Picker, Absätze an Sprechpausen aus `tokenTimings` | ~1 Woche | eine falsche Zahl ist schlimmer als ein ausgeschriebenes Wort | gebaut (2026-09-14), Pausenschwelle an Parakeet gemessen (0,35 s); Handtests offen |
| [32](32-lokales-sprachmodell.md) | **Lokales Sprachmodell als Textstufe** — FoundationModels (macOS 26) für Selbstkorrektur, Satzzeichen, Listen; nichts verlässt das Gerät | ½ T Messung + M | Latenz: 119 ms gegen voraussichtlich das Zehnfache — **erst messen** | Stufen 1 + 2 und Statistik gebaut, **aus** (2026-09-14); Messung offen, weil Apple Intelligence auf dem Build-Rechner aus ist (§8) |
| [35](35-sprecher-und-titel-messen.md) | **Sprechernamen und Titel: erst messen** — jeder stille Ausgang bekommt einen Code in `meta.json`, „Dein Name" gegen die eigene-Name-Lücke, Kalenderliste, Call-Quelle statt „Meeting" | S | keine Regel gelockert — Namen kommen erst nach der Messung | gebaut (2026-09-15); Messung im nächsten Meeting offen |
| [34](34-aufnahme-endet-mit-dem-call.md) | **Die Aufnahme endet mit dem Call** — manueller Start übernimmt den erkannten Call, nur-Ausgabe zählt nur bei hörbarer Gegenseite, Stille fragt und stoppt, `meta.json` sagt warum | S–M | beendet einen stillen, echten Call zu früh | gebaut (2026-09-15); Handtests im Call offen |
| [33](33-einstellungen-diaet-und-craft.md) | **Einstellungen-Diät und Craft** — Messinstrumente hinter ⌥, ein Satz je Footer, Tokens, Fenster-Autosave, Über/Hilfe, Onboarding ohne Mikrofon blockiert | M | 62 sichtbare Stellen, optisches Risiko | gebaut (2026-09-14), vervollständigt bis auf App-Icon und Screenshots (§9); Handtests offen |
| [36](36-sprecher-wiedererkennen.md) | **Sprecher wiedererkennen** — `CHECK`-Fehler in `speaker_labels` (rollt das erste benannte 1:1-Meeting zurück), Bildschirm-Messung von selbst, Adapter mit Fixtures, Hörprobe im Sprecher-Dialog, Stimmprofile aus bestätigten Namen | ½ h + S + S–M + M | Stimmprofil = biometrisches Merkmal eines Kollegen, lokal; Stufe 3 nur nach Messung (§3.4) | 📋 Entwurf (2026-09-16); §3.0 sofort |
| [37](37-das-gefuehl.md) | **Das Gefühl** — ein benutztes Bewegungssystem, HUD als eine Form (Aufwachsen, Atem, Fall auf die Linie, ✓ mit Wortzahl), Statistik zählt hoch mit Rekorden, Serie, Jahresraster, Wochenrückblick, Meilensteine | M–L | Diktatpfad darf 0 ms langsamer werden; „zu viel" | 📋 Entwurf (2026-09-16) |
| [38](38-weniger.md) | **Weniger** — vier Seiten statt sieben (Allgemein, Diktat, Meetings, Daten), 27 → 14 Toggles, 18 → 9 Picker, Menü 27 → 8 Slots ohne Untermenü, Onboarding 8 → 5 | M | kein Key wird umbenannt, kein Pfad ändert sein Verhalten — nur Oberfläche | 📋 Entwurf (2026-09-16); vor 37 bauen |
| [39](39-genauigkeit.md) | **Genauigkeit** — Korpus und WER-Harness (es gibt heute keine Messung), Pre-Roll und Nachlauf, Konfidenz sichtbar statt verworfen, Vokabular ins lokale Modell, Meetings auf das beste Modell, Kölner Phonetik | S+S+S–M+S+S (+M an Spec 32) | die erste Stelle, an der Diktat-Audio behalten wird — Schalter, 50 Clips, aus in der Vorgabe | 📋 Entwurf (2026-09-16); Stufe 0 vor allem anderen |

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

**Zu 23–27:** Fünf Anforderungen vom 2026-09-11, nummeriert in der empfohlenen
Bau-Reihenfolge, nicht in der Reihenfolge der Liste. Zwei davon erwiesen sich bei der
Messung als etwas anderes als gedacht:

- *„externes Audio wird nicht erkannt"* ist der gravierendste Befund der Runde: seit
  dem 12.08. ist die Mikrofonspur in **jedem** Call exakt stumm (Deckel zu, eingebautes
  Mikrofon ist Standard, der Call benutzt ein anderes Gerät). → 23.
- *„Sprechererkennung"* ist zum größten Teil eine Folge davon — bei stummem Mikrofon
  läuft die Benennung absichtlich nicht. → 24 baut auf 23 auf.
- *„Auto-Install vom Update"* existiert bereits (`installUnattended`, Default an), lief
  auf diesem Rechner aber nie nachweislich und prüft zwei Zustände nicht, in denen ein
  Neustart Arbeit vernichtet. → 25.

26 und 27 sind unabhängig und klein. Offene Entscheidungen stehen in 24 §7 und 27 §7.

**Zu 28–33:** Aus dem Vergleich mit Wispr Flow vom 2026-09-14
(`docs/analyse-wispr-flow-paritaet-2026-09-14.md`). Die Reihenfolge ist die
empfohlene Baureihenfolge: 29 zuerst (das „buggy" sitzt dort, und die Testnaht, die
29 anlegt, tragen 30 und 32), dann 30 und 31 unabhängig, 32 nur nach bestandener
Messung (Stufe 0), 33 zuletzt. 28 ist unabhängig und klein. Local-First bleibt in
allen sechs unberührt; 32 ist der Grund, warum das trotz Textintelligenz geht.
Offene Entscheidungen stehen in 29 §7, 30 §7, 31 §7, 32 §7 und 33 §7.

**Zu 36–38:** Drei Anforderungen vom 2026-09-16 — bessere Sprechererkennung, ein
Gefühl „wie Wispr Flow", und weniger Optionen. Die Inventur davor ergab: die
Sprechererkennung ist fertig gebaut und wartet seit dem 11.09. auf eine Messung, die
einen Knopf mitten im Call verlangt (36 lässt sie von selbst passieren) — und sie trägt
einen `CHECK`-Fehler, der das erste erfolgreich benannte 1:1-Meeting verlieren würde
(36 §3.0, sofort). Die App hat fünf Animationsstellen in 25 000 Zeilen und einen
Bewegungs-Token, den niemand benutzt (37). Spec 33 hat Einstellungen verschoben, nicht
entfernt: 27 Toggles, 18 Picker, 27 Menü-Slots (38). Reihenfolge: 36 §3.0 heute,
dann 38 vor 37 (weniger Flächen zu bewegen), 36 Stufe 3 nur nach der Messung in §3.4.

**Zu 39:** Die Frage „wie wird die Erkennung genauer?" ließ sich am 2026-09-16 nicht
beantworten, weil es **keine Messung gibt**: kein WER-Harness, kein Korpus,
`recordings.raw_text` in 0 von 234 Diktaten belegt, das persönliche Wörterbuch nach 234
Diktaten leer, und die Konfidenz, die FluidAudio je Token mitliefert, wird nirgends
gelesen. 39 baut deshalb zuerst das Maß und dann die fünf Hebel, die *vor* dem Modell
liegen — ein Modellwechsel steht ausdrücklich nicht darin.

Offene Entscheidungen in 36 §7, 37 §7, 38 §7, 39 §7.

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

Und umgekehrt (Spec 32): **ein Modell, das auf diesem Mac läuft, verletzt die Grenze
nicht.** Apples Systemmodell (FoundationModels) bekommt Diktattext, aber nichts davon
verlässt das Gerät — deshalb bucht die lokale Textstufe keine Zeile in `llm_usage`, und
das HUD sagt „Formatiere…" ohne „Text verlässt das Gerät". Lokal heißt: im Prozess oder
im System, ohne Netz. Ein lokal gestarteter Prozess, der ins Netz spricht, ist es nicht.

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
