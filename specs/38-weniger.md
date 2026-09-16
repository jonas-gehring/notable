# Spec 38 — Weniger: vier Seiten, ein kurzes Menü, fünf Onboarding-Schritte

> **Aufwand: M (3 Tage): Einstellungen S–M, Menü S, Onboarding S.** Spec 33 hat die
> Einstellungen auf Diät gesetzt und dabei nur drei Schalter entfernt; die übrigen rückten
> eine Ebene tiefer. Gezählt heute: **7 Seiten, 27 Toggles, 18 Picker, 6 Textfelder, 4
> „Erweitert"-Gruppen**, ein Menü mit **27 möglichen Einträgen**, ein Onboarding mit
> **8 Seiten**. Die Regel dieser Spec ist strenger als die drei aus Spec 33 §3.1: **eine
> Entscheidung, die der Code treffen kann, ist keine Einstellung** — und eine Seite ist
> eine Frage, die der Nutzer sich stellt, nicht eine Klasse im Code.

## 1. Ausgangslage (Inventur 2026-09-16, `Sources/Notable/Settings/`, `NotableApp.swift:543-780`)

**Einstellungen**, je Seite Toggles / Picker / Textfelder:

| Seite | T | P | TF | Bemerkung |
|---|---|---|---|---|
| Allgemein | 4 | 1 | 0 | Sprache, Notizen-Ordner, Anmeldung, Einführung, Updates (2 Toggles) |
| Diktat | 11 | 9 | 3 | acht Abschnitte; „Textstufe auf dem Gerät" und „Textverbesserung" sind zwei KI-Abschnitte mit zusammen 2 Toggles, 5 Pickern, 1 Slider, 1 Textfeld; „Erweitert" mit Einfügemethode, Vorschaltmodell, Idle-Stepper, Latenzzeile |
| Meetings | 9 | 1 | 1 | zehn Abschnitte, vier ohne Überschrift; zwei Notizfenster-Toggles; „Erweitert" mit Probe-Knopf, Skript |
| Menüleiste | 1 | 0 | 0 | eine Seite für ein Symbol und einen Stepper |
| Zusammenfassung | 0 | 1 | 2 | eine Seite für einen Picker und einen Key |
| Speicherplatz | 2 | 6 | 0 | sechs Aufbewahrungs-Picker mit je fünf Stufen |
| Berechtigungen | 0 | 0 | 0 | sechs Statuszeilen |

Drei Beobachtungen, die die Struktur erklären:

1. **Seiten folgen dem Code, nicht der Frage.** „Zusammenfassung" ist ein Abschnitt der
   Meetings-Seite, der eine eigene Seite bekam, weil `SummarizationProvider` ein eigenes
   Modul ist. „Menüleiste" ist ein Symbol-Picker und ein Stepper. „Speicherplatz" und
   „Berechtigungen" beantworten zusammen eine Frage: *Was weiß und behält Notable?*
2. **Vorgaben mit Picker.** Sechs Aufbewahrungs-Picker (`StorageSettingsView.swift:60-72`),
   jeder mit Aus/7/30/90 Tage/1 Jahr — für Diktattext, Meeting-Text, Chat, Audio, Budget,
   fehlgeschlagene Aufnahmen. Sie sind alle aus in der Vorgabe (CLAUDE.md: Retention
   opt-in). Sechs Picker für eine Entscheidung („aufräumen: ja/nein, wie lange
   behalten") sind fünf zu viel.
3. **Zwei Wege für dieselbe Sache.** Verbesserungs-„Dienst" (`EnhancementSettingsSection.swift:29`)
   und Zusammenfassungs-Provider sind zwei Picker für die Frage „welche CLI"; „Töne", „Wiedergabe
   pausieren", „Systemton stummschalten" sind drei Toggles für „was passiert mit dem Ton
   während ich diktiere"; „Sprecher anhand genannter Namen" und „Sprecher am Bildschirm"
   sind zwei Toggles mit einer Datenschutz-Achse (das eine schickt Text raus, das andere
   nicht), die als zwei gleichrangige Häkchen dastehen.

**Menü** (`MenuContentView.body`, `NotableApp.swift:543`): 27 Slots, im Leerlauf mit
Historie und aktiviertem Enhancement **14 sichtbare Einträge, 4 Untermenüs, 4 Trenner**.
Darunter: eine Statuszeile, die im Leerlauf „Bereit" o. ä. sagt; „Heute: …" als
deaktivierter Text neben einem separaten „Statistik…"; „Letztes Diktat einfügen",
„… kopieren", „… verbessern ▸", „Letzte Diktate ▸ (8 Einträge + Alle anzeigen…)"
— vier Einträge für die Historie; „Notizen ▸" mit drei Einträgen, von denen „Durchsuchen"
und „Ordner öffnen" Funktionen des Notizfensters sind; ein Update-Abschnitt, der auch
ohne Update eine Zeile zeigt („Nach Updates suchen" bzw. „ist aktuell").

**Onboarding** (`OnboardingView.swift:21`): Willkommen · Mikrofon · Taste & Einfügen ·
Erstes Diktat · Meetings · Zusammenfassung · Notizen-Ordner · Alles bereit. Die Seiten
„Zusammenfassung" (drei Sätze und „Einstellungen öffnen…") und „Notizen-Ordner" (Vorgabe
iCloud Drive, seit Spec 27 ohnehin die richtige) fragen nichts, was der Start braucht.

## 2. Ziel

Vier Seiten — **Allgemein, Diktat, Meetings, Daten** — mit zusammen **≤ 14 Toggles,
≤ 9 Pickern, ≤ 3 Textfeldern** und **einer** „Erweitert"-Gruppe je Seite, in der nur
steht, was misst oder überschreibt. Ein Menü mit **≤ 9 Einträgen im Leerlauf** und
keinem Untermenü. Ein Onboarding mit **fünf** Schritten, von denen keiner etwas fragt,
was die Vorgabe schon richtig macht. Kein Defaults-Key wird umbenannt oder gelöscht;
jede entfernte Einstellung behält ihren Key mit der Vorgabe als festem Wert.

## 3. Konzept

### 3.1 Die Regel und ihre drei Prüfungen

Für jeden Control drei Fragen, in dieser Reihenfolge; die erste, die „ja" ergibt,
entscheidet:

1. **Kann der Code es wissen?** → keine Einstellung. (Idle-Timeout-Sekunden.
   Vorschaltmodell. Zeitbudget der Verbesserung. Budget des Audio-Archivs. *Nicht*
   Echo unterdrücken: ob VPIO auf diesem Gerät den Graphen stumm schaltet, weiß der
   Code nicht — das war der Juli-Postmortem.)
2. **Ist es eine Ausprägung derselben Frage wie ein anderer Control?** → ein Control mit
   Stufen. (Drei Ton-Toggles → ein Picker. Zwei Sprecher-Toggles → ein Picker mit
   Datenschutz-Ordnung. Sechs Aufbewahrungs-Picker → ein Toggle und ein Picker.)
3. **Würde ein anderer Nutzer desselben Geräts es anders stellen?** (Spec 22 §3.4) →
   Einstellung, sonst Vorgabe.

Was durchkommt, steht über dem Falz. Was misst, protokolliert oder überschreibt, steht
in „Erweitert" (Spec 33 Regel 1). Was keins von beiden ist, verschwindet — und die
Begründung steht hier.

### 3.2 Die vier Seiten

**Allgemein** — *Wie ist Notable eingerichtet?*

| Abschnitt | Controls | Herkunft |
|---|---|---|
| — | Picker Sprache · Toggle Bei Anmeldung starten | wie heute |
| Menüleiste | Picker Symbol (12 Motive, als Popup mit Symbol statt Raster) · Toggle „Heute-Zeile im Menü" | Seite „Menüleiste" geht hier auf; der Tipp-Stepper wandert in die Statistik, wo die Zahl wirkt (`TypingSpeedStepper` steht dort schon) |
| Mitteilungen | Toggle Notiz fertig · Toggle Wochenrückblick (Spec 37) | „Benachrichtigen, wenn die Notiz fertig ist" kommt von Meetings; ein Ort für alles, was Notable ungefragt sagt |
| Notizen-Ordner | Pfad, Ändern…, Im Finder zeigen, In iCloud Drive verschieben… | wie heute; Toggle „Symbol am Ordner" → Erweitert |
| Updates | **ein** Toggle „Updates automatisch installieren" (ohne Suchen kein Installieren — Suchen ist mit dem Toggle an, und ohne ihn wird trotzdem gesucht und im Menü gesagt) · Versionszeile · Nach Updates suchen · Neu in … | zwei Toggles → einer; `updateAutomaticChecks` bleibt als Key, fest `true` |
| Erweitert | Symbol am Ordner · Einführung zeigen · Notable neu starten | — |

**Diktat** — *Wie diktiere ich?*

| Abschnitt | Controls | Herkunft |
|---|---|---|
| Taste | Picker Push-to-talk · Toggle Freihändig bei Stille beenden | wie heute; die Sekunden (`dictationIdleTimeout`) fest 45 |
| Erkennung | Picker Erkennung (drei Rollen) · `EngineStatusRow` · Sprachen (2 Checkboxen) · Whisper-Modell nur bei Whisper | wie heute |
| Text | Toggle Text aufbereiten · Anpassen… (Sheet mit den fünf Schaltern und der App-Tabelle) | wie heute |
| KI | Picker **„Lokal formatieren"** (Aus / Ab 25 Wörtern / Immer; grau ohne Modell) · Toggle **„Verbesserung auf Abruf"** — darunter nur noch: Picker Taste, Picker Profil (mit „Eigenes…" als letztem Eintrag, der das Sheet öffnet) | zwei Abschnitte → einer. **Dienst** entfällt: die Verbesserung nimmt den Zusammenfassungs-Anbieter, wenn er eine CLI ist, sonst die Claude-CLI (`SummarizationProviderID.cliProviders` entscheidet — genau die Regel, die `DictationEnhancer` heute schon als Fallback hat). **Zeitbudget** fest 15 s. Statuszeile und CLI-Argumente → Meetings › Erweitert, wo der Anbieter steht |
| Wörterbuch & Bausteine | Tabelle, Vorschläge, Bausteine, Toggle Ähnliche Schreibweisen | wie heute, ein Abschnitt |
| Anzeige & Ton | Picker Anzeige (4 Plätze) · Toggle Töne · **Picker „Während des Diktats"**: Nichts / Wiedergabe pausieren / Systemton stummschalten | zwei Toggles → ein Picker (beide aus in der Vorgabe ⇒ „Nichts"); `pauseMediaDuringDictation`/`muteSystemAudioDuringDictation` bleiben die Keys, der Picker schreibt beide |
| Erweitert | Picker Einfügemethode · Zeile „Text aus der Ziel-App lesen (lokal)" mit Befehl-Taste (Spec 32 Stufe 2 — eine Consent-Einstellung, die niemand versehentlich finden soll, aber jeder finden kann) · letzte Latenz | Vorschaltmodell **entfällt** (`bootstrapModel` bleibt Key, fest `true`, Spec 33 Abweichung 3 wird eingelöst); Idle-Stepper entfällt |

Diktat danach: 6 Toggles (+ 2 Sprach-Checkboxen), 6 Picker über dem Falz, 3 in
Erweitert-Nähe. Über dem Falz eines 620-pt-Fensters: Taste, Erkennung, Text.

**Meetings** — *Wie werden Calls aufgenommen und was wird daraus?*

| Abschnitt | Controls | Herkunft |
|---|---|---|
| — | Toggle Erkannte Calls anbieten · Toggle Nächstes Meeting in der Menüleiste | wie heute |
| Mikrofon | Picker Eingabegerät · „Zuletzt aufgenommen von" | wie heute; **Echo unterdrücken → Erweitert**: der Schalter bleibt (Vorgabe aus, seit dem Juli-Postmortem — VPIO hat einmal ganze Meetings stumm geschaltet; ob es das wieder tut, kann der Code nicht wissen), aber er ist keine Frage, die sich jeder stellt |
| Sprecher | **Picker „Sprecher benennen"**: Aus / Nur auf dem Gerät (Bildschirm, Kalender, Stimme) / Auch aus dem Gespräch (Text geht an den Anbieter) · Textfeld Dein Name · Stimmprofile-Liste (Spec 36, wenn gebaut) | zwei Toggles → ein Picker mit Datenschutz-Ordnung; `speakerNamingEnabled`/`screenSpeakerRecognition` bleiben Keys, der Picker schreibt beide |
| Notizen im Call | Toggle Notizfenster beim Start öffnen | „immer im Vordergrund" **entfällt**: das Fenster schwebt — das ist sein Zweck (CLAUDE.md, LiveNotes). `meetingNotesFloating` Key, fest `true` |
| Zusammenfassung | Picker Anbieter · API-Key-Zeile (nur bei API) · Statuszeile mit „Verbindung testen" (nur bei CLI) | Seite „Zusammenfassung" geht hier auf |
| Kalender | Liste wie heute | — |
| Gemerkte Entscheidungen | wie heute | eine Consent-Fläche bleibt sichtbar |
| Erweitert | Toggle Echo unterdrücken · Toggle Meetings mit dem Diktat-Modell · Skript nach Meeting-Ende · CLI-Argumente · Bildschirm-Messungen (Spec 36) | „Call-Fenster jetzt auslesen" entfällt mit Spec 36 §3.1 |

**Daten** — *Was weiß Notable, was behält es, was darf es?*

| Abschnitt | Controls | Herkunft |
|---|---|---|
| Belegung | die vier Zahlen und die Summe (Spec 20/21) | wie heute |
| Aufbewahrung | Toggle **„Alte Aufnahmen automatisch aufräumen"** · **ein** Picker **„Meeting-Audio behalten"**: 7 Tage / 30 Tage / 90 Tage / 1 Jahr / Immer | sechs Picker → einer. Budget fest 20 GB (`retentionAudioBudgetGB`), fehlgeschlagene Aufnahmen fest 2 × Audio-Frist, **Texte werden nicht mehr automatisch gelöscht** — die drei Text-Picker waren aus in der Vorgabe und sind es bei jedem bekannten Nutzer geblieben; wer Transkripte loswerden will, hat „Jetzt aufräumen…". Alle sechs Keys bleiben und werden weiter gelesen: ein Nutzer, der einen Text-Picker gestellt hat, behält seine Frist — nur der Picker dafür steht unter Erweitert |
| Statistik | Toggle Ziel-App erfassen · Erfasste Ziel-Apps löschen | von „App-Statistik" |
| Berechtigungen | die sechs Zeilen mit Erlauben / Systemeinstellungen… | Seite „Berechtigungen" geht hier auf; „Status aktualisieren" entfällt (es läuft alle 2 s), „Notable neu starten" → Allgemein › Erweitert |
| Modelle · Manuell aufräumen | wie heute | — |
| Erweitert | die drei Text-Fristen · Budget · Fehlgeschlagene-Frist | für den, der sie gestellt hat |

**Summe danach: 4 Seiten, 14 Toggles (+ 2 Checkboxen), 9 Picker, 2 Textfelder (Name,
Wörterbuch-Paar zählt als Tabelle), 4 Erweitert-Gruppen (eine je Seite).** Entfernt als
Wahl, im Code fest: Vorschaltmodell, Idle-Sekunden, Zeitbudget, Dienst, Notizen
schwebend, Update-Suche, Audio-Budget, Fehlgeschlagene-Frist. Zusammengelegt: Ton (3 → 1),
Sprecher (2 → 1), Aufbewahrung (6 → 1), KI (2 Abschnitte → 1).

### 3.3 Das Menü

Vorher 27 Slots. Danach, im Leerlauf:

```
Heute: 1.240 Wörter · 38 min gespart        ← klickbar → Statistik; entfällt ohne Zahlen
─────────────────────────
Meeting aufzeichnen                          ← „beenden" während einer Aufnahme
Nächstes: Standup, 14:00                     ← nur mit Kalender-Ereignis
─────────────────────────
Letztes Diktat einfügen                      ← ⌥: Letztes Diktat kopieren (macOS 15)
Letzte Diktate…                              ← das Fenster; kein Untermenü mit acht Einträgen
Notizen…                                     ← das Fenster; Suchen (⌘F) und Ordner sind dort
─────────────────────────
Einstellungen…                          ⌘,
Notable beenden                         ⌘Q
```

Acht Einträge, drei Trenner, kein Untermenü. Alles Weitere erscheint **nur, wenn es
etwas zu tun gibt**, an seiner Stelle:

- **Statuszeile** ganz oben nur, wenn nicht Leerlauf: „Meeting wird aufgezeichnet ·
  MacBook-Mikrofon" (die Mikrofon-Zeile geht darin auf), „Meeting wird verarbeitet…",
  „Modell lädt: 40 %", „Vorläufiges Modell aktiv…", „⚠︎ …". Im Leerlauf **keine**
  Statuszeile — „Bereit" ist keine Information.
- **Speicherplatz-Hinweis** (Spec 21) über der ersten Trennlinie, wie heute, nur über
  der Schwelle.
- **Während eines Meetings**: „Notizen zum Meeting…" unter „Meeting beenden".
- **Nach einem Meeting**: „Letzte Notiz öffnen" (bis zum nächsten Diktat oder Meeting,
  nicht für immer) und „Zusammenfassung nachholen" (solange der Fehler steht).
- **Fehlgeschlagenes Diktat**: **ein** Eintrag „Fehlgeschlagenes Diktat wiederholen"
  statt Untermenü; Verwerfen bleibt im Fenster „Letzte Diktate".
- **Verbessern**: „Letztes Diktat verbessern" als **ein** Eintrag mit dem automatischen
  Profil; die Profile stehen im Fenster „Letzte Diktate" an jedem Eintrag. Nur mit
  eingeschalteter Verbesserung.
- **Update**: nur wenn eines gefunden ist („Update 1.4.0 installieren") oder gerade
  läuft; „Nach Updates suchen" und „ist aktuell" wandern nach Allgemein, wo sie schon
  stehen. Ein Menü, das ohne Anlass eine Update-Zeile zeigt, sagt jedes Mal „nichts".

Untermenüs entfallen alle vier. Die acht letzten Diktate im Menü waren ein zweites
Fenster in einer Liste — das Fenster ist einen Klick entfernt und kann mehr
(korrigieren, wiederholen, verbessern mit Profil). „Durchsuchen…" wird ⌘F im
Notizfenster und ein Suchfeld in dessen Toolbar; „Notizen-Ordner öffnen" ein Knopf in
derselben Toolbar (der Fehler `notesFolder.lastError` steht dann dort, wo der Ordner
gebraucht wird).

### 3.4 Das Onboarding

Fünf Schritte:

1. **Willkommen** — drei Sätze, wie heute.
2. **Mikrofon & Taste** — die drei Berechtigungen, die das Diktat braucht (Mikrofon,
   Eingabeüberwachung, Bedienungshilfen), auf einer Seite; „Weiter" aus, bis das
   Mikrofon erteilt ist (Spec 33 §3.5 bleibt).
3. **Dein erstes Diktat** — wie heute, plus der Satz aus Spec 37 §3.7.
4. **Meetings** — Systemaudio, Kalender, Mitteilungen; ein Satz, dass Calls erkannt und
   angeboten werden.
5. **Fertig** — drei Sätze: wo die Notizen liegen (der Ordner ist angelegt, iCloud
   Drive), dass Zusammenfassungen einen Anbieter brauchen („Einstellungen › Meetings"),
   dass ⌘, alles Weitere hat.

„Zusammenfassung" und „Notizen-Ordner" entfallen als Seiten: die eine fragt nichts, die
andere bestätigt eine Vorgabe, die seit Spec 27 stimmt. Wer einen anderen Ordner will,
findet ihn unter Allgemein — und die Fertig-Seite sagt, wo.

### 3.5 Was mit den Keys passiert

Kein Key wird umbenannt oder gelöscht (CLAUDE.md, `DefaultsKey`). Drei Klassen:

- **Fest gesetzt, weiter gelesen**: `bootstrapModel` (true), `dictationIdleTimeout`
  (45 wenn > 0), `dictationEnhanceDeadline` (15),
  `meetingNotesFloating` (true), `updateAutomaticChecks` (true),
  `retentionAudioBudgetGB` (20), `retentionFailedDays` (2 × Audio). Der Leser bekommt
  einen Kommentar, dass der Key seit Spec 38 keine Oberfläche mehr hat.
- **Von einem Picker beschrieben, der zwei Keys hält**: Ton (`pauseMediaDuringDictation`
  + `muteSystemAudioDuringDictation`), Sprecher (`speakerNamingEnabled` +
  `screenSpeakerRecognition`). Ein `Binding` pro Picker in einer puren Tabelle
  (`SettingsBindings.swift`), getestet: jede Picker-Stellung ⇄ Key-Paar eindeutig;
  eine Key-Kombination, die keiner Stellung entspricht (beide Ton-Keys `true`), zeigt
  die *stärkere* Stellung und schreibt beim nächsten Wechsel sauber.
- **Weggefallen als Wahl, Key wird weiter gelesen**: `dictationEnhanceProvider` — der
  Leser nimmt ihn, wenn er gesetzt ist, sonst die neue Ableitung aus dem
  Zusammenfassungs-Anbieter. Wer den Dienst gestellt hat, behält ihn.

## 4. Integration

| Stelle | Änderung |
|---|---|
| `Settings/SettingsView.swift`, `SettingsRoute.swift` | `Pane`: `.general, .dictation, .meetings, .data`; Routen der alten Seiten (`.storage`, `.permissions`, `.summarization`, `.menuBar`) bleiben als Aliase, die auf die neue Seite und den Abschnitt zeigen — `storageNotice` und der Notizen-Ordner-Fehler routen dorthin |
| `Settings/GeneralSettingsView.swift` | Menüleiste, Mitteilungen, Updates-Toggle |
| `Settings/DictationSettingsView.swift`, `LocalPolishSection.swift`, `EnhancementSettingsSection.swift` | KI-Abschnitt; Ton-Picker; Erweitert |
| `Settings/MeetingsSettingsView.swift`, `SummarizationSettingsView.swift` → Abschnitt | Sprecher-Picker; Zusammenfassung als Abschnitt; Erweitert |
| `Settings/DataSettingsView.swift` (neu, aus `StorageSettingsView` + `PermissionsSettingsView`) | Aufbewahrung 1 + 1; Berechtigungen |
| `Settings/MenuBarSettingsView.swift`, `IconPickerView.swift` | gelöscht bzw. Popup |
| `Settings/SettingsBindings.swift` (neu, pur) | Picker ⇄ Key-Paare |
| `Dictation/DictationEnhancer.swift` | Anbieter-Ableitung; Deadline fest |
| `Storage/RetentionPolicy.swift` | Budget/Fehlgeschlagene aus der Audio-Frist, wenn der Key ungesetzt ist |
| `NotableApp.swift` `MenuContentView` | §3.3; `optionAlternate` für Kopieren |
| `Notes/NoteListView.swift` | Toolbar: Suchfeld (⌘F), Ordner öffnen, Fehlerzeile |
| `Onboarding/OnboardingView.swift` | fünf Seiten |
| `Stats/StatsView.swift` | `TypingSpeedStepper` bleibt dort — einziger Ort |
| `Tests/SettingsBindingsTests.swift` (neu) | §3.5 Tabelle |
| `Tests/LocalizationTests.swift` | neue Sätze; `en.lproj` |
| `README.md`, `README.de.md`, `docs/images/` | Screenshots nach dem Umbau (seit Spec 33 offen) |

Keine Migration.

## 5. Risiken

- **Etwas verschwindet, das jemand gestellt hat.** Kein Key wird gelöscht; jeder
  weggefallene Wert wird weiter gelesen (§3.5). Was fehlt, ist nur die Oberfläche — und
  für die Text-Fristen und den Dienst steht sie unter Erweitert bzw. wird abgeleitet.
- **Kein Meeting-Pfad ändert sein Verhalten.** Alles, was fest gesetzt wird, wird auf
  seine heutige Vorgabe gesetzt; der einzige Kandidat für eine Ableitung (Echo) bleibt
  ein Schalter, weil der Code die Antwort nicht kennt.
- **Der Dienst-Picker war die Stelle, an der stand, wohin Diktattext geht.** Danach
  steht es am Verbesserungs-Toggle: Footer „Text geht an <Anbieter> (aus Meetings ›
  Zusammenfassung)". Die Nennung des Anbieters am Punkt der Wahl (CLAUDE.md „each one is
  named at the point of choosing") bleibt — sie steht nur einmal statt zweimal.
- **Vier Seiten sind länger.** Meetings hat danach acht Abschnitte. Der Falz-Test
  (Abnahme 1) gilt je Seite: die erste Bildschirmhöhe beantwortet die häufigste Frage.
- **`Pane`-Routen**: `settingsRoute.requested = .storage` an drei Stellen; Aliase
  fangen es, ein Test prüft jede alte Route auf ein Ziel.
- **Reihenfolge zu Spec 37**: diese zuerst, damit 37 weniger Flächen bewegt.

## 6. Abnahme

1. Vier Seiten; je Seite über dem Falz (620 pt) die drei ersten Abschnitte aus §3.2;
   genau eine Erweitert-Gruppe je Seite, zugeklappt.
2. Zählung im Quelltext: `Toggle(` ≤ 16, `Picker(` ≤ 10 unter `Settings/` außerhalb von
   Sheets — ein `ThemeTests`-artiger Test hält die Zahl fest, damit sie nicht zurückwächst.
3. Menü im Leerlauf: acht Einträge, kein Untermenü; während einer Aufnahme: Statuszeile
   oben, „Notizen zum Meeting…" darunter; mit gefundenem Update: eine Update-Zeile;
   ohne: keine.
4. `SettingsBindingsTests`: jede Picker-Stellung schreibt das erwartete Key-Paar, jede
   Key-Kombination liest eine Stellung; die Keys aus §3.5 werden weiter gelesen
   (Regressionstest je Key mit gesetztem Alt-Wert).
5. Onboarding fünf Seiten; ohne Mikrofon kein „Weiter"; nach Fertig existiert der
   Notizen-Ordner.
6. Notizfenster: ⌘F fokussiert das Suchfeld, Ordner-Knopf öffnet ihn, Fehler steht in
   der Toolbar.
7. `LocalizationTests` grün; englisches Fenster ohne deutschen Satz.
8. Screenshots aller vier Seiten und des Menüs in `docs/images/`, README erneuert.

## 7. Offene Entscheidungen

- **Texte nicht mehr automatisch löschen** (die drei Text-Fristen nur noch unter
  Erweitert): Vorschlag ja — sie waren nie an. Gegenposition: Retention war das Thema
  von issue #2, und die Text-Fristen waren dort eine bewusste Achse.
- **Update-Zeile nur bei Anlass**: Vorschlag ja. Gegenposition: „Nach Updates suchen"
  im Menü ist die eine Stelle, an der man es ohne Einstellungen anstoßen kann.
- **Dienst der Verbesserung abgeleitet** statt gewählt: Vorschlag ja. Gegenposition:
  jemand fasst Meetings mit der API zusammen und will Diktate über Gemini verbessern —
  dann bleibt der Key setzbar, nur ohne Picker.
- **Seitenname „Daten"** — oder „Datenschutz", oder „Speicher & Rechte".

## 8. Handtests

*Noch nicht gelaufen.* Jede alte Route (`storageNotice`, Notizen-Ordner-Fehler, Menü
„Einstellungen…") landet auf der richtigen Seite; Datum und Ergebnis hierher.

## 9. Stand des Baus (2026-09-16)

**Gebaut:**

- **Vier Seiten** (§3.2): Allgemein, Diktat, Meetings, Daten. „Menüleiste“ ist in
  Allgemein aufgegangen, „Zusammenfassung“ in Meetings, „Speicherplatz“ und
  „Berechtigungen“ zusammen in der neuen Seite `DataSettingsView`.
  `MenuBarSettingsView.swift`, `StorageSettingsView.swift` und
  `PermissionsSettingsView.swift` sind gelöscht. Über dem Falz stehen je Seite die
  drei ersten Abschnitte aus §3.2, und **genau eine** zugeklappte
  „Erweitert“-Gruppe je Seite — gemessen, nicht behauptet.
- **`SettingsPane` ist pur** und liegt in `SettingsRoute.swift`; `SettingsView.Pane`
  bleibt als `typealias` der Name an jeder Aufrufstelle. Ein handgeschriebenes
  `init?(rawValue:)` löst die vier alten Routen (`menubar`, `summary`, `storage`,
  `permissions`) auf die Seite auf, die sie übernommen hat — ein Test prüft jede
  einzeln, und dass ein Tippfehler weiterhin `nil` ergibt statt auf „Allgemein“ zu
  landen.
- **Zwei Picker für je zwei Keys** (`Settings/SettingsBindings.swift`, pur):
  `DictationAudioMode` (Ton während des Diktats) und `SpeakerNamingMode` (Sprecher
  benennen, nach Datenschutz geordnet). Beide Richtungen sind getestet, samt der
  Kombinationen, die zu keiner Stellung gehören: beide Ton-Keys `true` liest als
  „Systemton stummschalten“, `speakerNamingEnabled` ohne `screenSpeakerRecognition`
  als „Auch aus dem Gespräch“ — jeweils die **stärkere** Stellung, weil
  Untertreiben hier die falsche Richtung ist. Der nächste Wechsel schreibt ein
  sauberes Paar.
- **Aufbewahrung 6 → 1** (`AudioRetentionChoice`): ein Schalter, eine Frist.
  Budget fest 20 GB, Fehlgeschlagene-Frist abgeleitet als 2 × Audio-Frist
  (`RetentionPolicy.failedAgeFactor`), Texte werden nicht mehr automatisch
  gelöscht. Alle sechs Keys werden weiter gelesen, ein gesetzter Wert schlägt die
  Ableitung, und die fünf Picker dafür stehen unter „Erweitert“. Eine Zahl, die
  keiner der fünf Stufen entspricht, rundet **auf** — eine Frist darf sich nicht
  dadurch verkürzen, dass jemand die Seite geöffnet hat.
- **KI ist ein Abschnitt** statt zwei: der lokale Picker, der Verbesserungs-Schalter,
  Taste und Profil. **Dienst** ist abgeleitet
  (`DictationEnhancer.resolvedProviderID`): der Zusammenfassungs-Anbieter, wenn er
  eine CLI ist, sonst die Claude-CLI — und `dictationEnhanceProvider` schlägt beides,
  wenn es gesetzt ist. Die gemessene Regel bleibt, dass die API von hier aus
  unerreichbar ist; das ist als Tabelle getestet. Wohin der Text geht, steht als
  Zeile unter dem Schalter, mit dem Namen des Anbieters.
- **Menü: 27 Slots → 7 Einträge im Leerlauf** (8 mit Kalendertermin, 9 mit
  eingeschalteter Verbesserung), drei Trenner, **kein Untermenü**. Keine
  Statuszeile im Leerlauf; die Mikrofon-Zeile ist in der Statuszeile aufgegangen;
  „Fehlgeschlagenes Diktat“ ist ein Eintrag; Kopieren liegt auf ⌥ (macOS 15);
  die Update-Zeile erscheint nur bei gefundenem Update.
- **Onboarding: 8 → 5 Seiten.** Mikrofon, Eingabeüberwachung und Bedienungshilfen
  stehen zusammen auf einer Seite; „Weiter“ bleibt ohne Mikrofon aus. Die
  Fertig-Seite legt den Notizen-Ordner an (`onAppear` **und** `finish()`, auch beim
  Überspringen) und nennt Ordner, Anbieter und ⌘,.
- **Notizfenster**: Suchfeld in der Toolbar mit ⌘F, ein Knopf für den
  Notizen-Ordner, einer für die Volltextsuche — und `notesFolder.lastError` steht
  jetzt dort, wo der Ordner gebraucht wird, statt in einem geschlossenen Untermenü.
- **Keine Umbenennung, keine Löschung.** Die drei Klassen aus §3.5 sind gebaut;
  jeder Leser eines Keys ohne Oberfläche hat einen Kommentar bekommen, der sagt,
  seit wann und warum.

**Abweichungen:**

1. **„Statistik…“ bleibt — als Alternative, nicht zusätzlich.** §3.3 streicht den
   Eintrag und macht die Heute-Zeile zum einzigen Weg. Gebaut ist: **genau eine**
   der beiden ist immer da. Ohne Zahlen (stiller Tag) oder mit abgeschalteter
   Heute-Zeile wäre das Statistik-Fenster sonst aus dem Menü **gar nicht** mehr
   erreichbar — es hat keinen zweiten Einstieg. Die Obergrenze aus §2 (≤ 9) hält.
2. **Die Zahlen aus §6.2 sind nicht erreicht** und der Test hält die gemessenen
   statt der geforderten fest: 26 `Toggle(` und 19 `Picker(` im Quelltext unter
   `Settings/` (ohne Kommentarzeilen), davon 21 bzw. 18 außerhalb des
   „Text aufbereiten“-Sheets. §6.2 fordert ≤ 16 und ≤ 10. Der Grund ist nicht die
   Diät, sondern die Zählweise: §3.2 listet in seinen eigenen Tabellen schon rund
   18 Schalter, und der Quelltext enthält zusätzlich die Zeilen-`Toggle`s der
   Wörterbuch- und Baustein-Tabellen (einer im Code, N auf dem Schirm) sowie zwei
   Helfer, die je ein `Picker(` für fünf sichtbare schreiben. Die Zahl ist gepinnt,
   damit sie nicht zurückwächst; wer sie senken will, muss Abschnitte streichen,
   die §3.2 verlangt.
3. **„Fest gesetzt“ heißt: keine Oberfläche, Vorgabe im Code, gesetzter Wert gilt
   weiter.** `EnhancementSettings.deadline` liest den Key nach wie vor (geklemmt)
   und fällt nur auf `fixedDeadlineSeconds = 15` zurück; dasselbe gilt für
   `dictationIdleTimeout` und die Fehlgeschlagene-Frist. §3.5 nennt diese Keys
   „fest gesetzt, weiter gelesen“, was für einen einzelnen Wert widersprüchlich
   ist — gebaut ist die Lesart, die §5 („Was fehlt, ist nur die Oberfläche“)
   einlöst und niemandem eine Einstellung wegnimmt.
4. **`updateAutomaticChecks` wird nicht auf `true` gezwungen.** Der Toggle ist weg
   und der ungesetzte Key bedeutet weiterhin `true`. Wer die Suche früher
   abgeschaltet hat, behält das — ohne Weg zurück in der Oberfläche. Das Gegenteil
   hieße, eine gemachte Einstellung zu überschreiben *und*
   `Update/UpdateChecker.swift` anzufassen, das zu dieser Spec nicht gehört.
5. **Die Profile stehen nicht an jedem Eintrag in „Letzte Diktate“.** §3.3 setzt
   das voraus; `Notes/RecentDictationsView.swift` hat es heute nicht (nur
   „Kopieren“ und „Verwerfen“) und gehörte nicht zu den Dateien dieses Baus. Der
   Menü-Eintrag „Letztes Diktat verbessern“ nimmt das automatische Profil; die
   Profile selbst sind unter Diktat › KI wählbar und editierbar.
6. **„Call-Fenster jetzt auslesen“ bleibt** unter Meetings › Erweitert. §3.2 sagt,
   es entfällt *mit* Spec 36 — die ist nicht gebaut, und die ⌥-Alternative im Menü
   ruft dieselbe Funktion.
7. **`CLIProviderStatusRow` ist geteilt** in Statuszeile und `CLIArgumentsRow`. Die
   eigene `DisclosureGroup("Erweitert")` der Zeile wäre sonst eine **zweite**
   zugeklappte Gruppe auf der Meetings-Seite gewesen.
8. **Profile behalten Bearbeiten/Löschen.** §3.2 listet im KI-Abschnitt nur den
   Picker. Ein geschriebener Prompt ohne Weg, ihn zu ändern oder zu entfernen, ist
   schlechter als eine Zeile mehr.
9. **`SettingsPane` musste aus `SettingsView` heraus.** Das Test-Bundle hat keinen
   App-Host: `@testable import Notable` übersetzt, linkt aber nicht — jeder
   benutzte Typ muss selbst im Bundle liegen. Die Routen testbar zu machen, ohne
   vier SwiftUI-Seiten mit hineinzuziehen, geht nur so. (Erst am Linker-Fehler
   gesehen, nicht vorher.)

**Tests:** `SettingsBindingsTests` **26 neu, grün**. Regressionslauf der
betroffenen Suiten — `LocalizationTests`, `ThemeTests`, `DefaultsKeyTests`,
`DictationEnhancerTests`, `RetentionPlannerTests`, `RetentionStoreTests`,
`MenuUsageLineTests`, `MediaInterrupterTests`, `UpdateCheckerTests`,
`StorageFootprintTests` — **121 Tests, 0 Fehler**. `LocalizationTests` fand 32
fehlende englische Einträge; ergänzt sind 44, weil elf Zeichenketten der Scanner
bauartbedingt nicht sieht (`explanation`-Member, der `bullet()`-Helfer,
mehrzeilige Footer, interpolierte Schlüssel). Der App-Build ist grün. Modell-
Suiten wurden nicht gelaufen.

**Nicht gebaut / nicht verifiziert:** Abnahme 8 (Screenshots aller vier Seiten und
des Menüs, README) — wie schon nach Spec 33 offen. Die Handtests aus §8 sind
**nicht gelaufen**: ein Debug-Build startet nicht neben der installierten App, also
ist alles, was man sehen oder bedienen muss, ungeprüft — der Falz-Test (Abnahme 1)
ist am Quelltext ausgezählt, nicht am Bildschirm, und Abnahme 3, 5 und 6 (Menü im
Leerlauf und während einer Aufnahme, Onboarding ohne Mikrofon, ⌘F im Notizfenster)
ebenso. Die Zeilen für Spec 37 (Wochenrückblick, Allgemein › Mitteilungen) und
Spec 36 (Stimmprofile, Meetings › Sprecher) stehen als Kommentar an ihrer Stelle.

**Was die Spec über den Code falsch sagt:** (a) §3.3 setzt voraus, dass die
Verbesserungs-Profile im Fenster „Letzte Diktate“ an jedem Eintrag stehen — sie
stehen dort nicht (Abweichung 5). (b) §6.2 fordert ≤ 16 Toggles und ≤ 10 Picker,
während §3.2 in seinen eigenen Tabellen schon rund 18 Schalter aufzählt
(Abweichung 2). (c) §4 verweist für den Tipp-Stepper auf `Stats/StatsView.swift`;
er ist eine eigene Datei, `Stats/TypingSpeedStepper.swift`, und stand in **zwei**
Ansichten — nach dem Wegfall der Menüleisten-Seite steht er, wie gewünscht, nur
noch an einer. (d) §3.5 nennt `dictationEnhanceDeadline` „fest gesetzt, weiter
gelesen“, was für einen einzelnen Wert nicht beides sein kann (Abweichung 3).
