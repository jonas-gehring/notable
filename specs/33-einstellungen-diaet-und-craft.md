# Spec 33 — Einstellungen-Diät und Craft

> **Aufwand: M (4 Tage): Diät S–M, Tokens S, Fenster/Menü S, Onboarding S.** Die
> Begründungen dieses Codes sind ungewöhnlich gut — und sie stehen in der Oberfläche.
> Rund ein Drittel des sichtbaren Textes erklärt, *warum der Code so ist*. Dazu ~50
> Einstellungs-Controls, ein HUD-Token-Set, das es nicht gibt, und ein Onboarding, das
> ohne Mikrofon zu „Alles bereit" führt. Reines Craft; kein Kernpfad wird angefasst.
> Quelle: `docs/analyse-wispr-flow-paritaet-2026-09-14.md` §5.2–§5.5.

## 1. Ausgangslage (Fakten aus dem Code)

- **Dichte.** Sieben Seiten (`SettingsView.swift:8-9`); gezählt ~29 Toggles, 18
  Picker, 3 Stepper/Slider, zwei editierbare Tabellen, ein 40-Zellen-Icon-Raster
  (`IconPickerView.swift:23-65`), vier destruktive Flüsse. Die Diktat-Seite
  (`DictationSettingsView.swift`) hat acht Abschnitte, zehn `Toggle(`, acht Picker,
  Slider, Stepper, Wörterbuch-Tabelle, Vorschläge, Latenzzeile (`:191-203`), die
  Verbesserungs-Sektion, Bausteine und eine Kopie der Diktat-Historie (`:209`).
- **Messinstrumente als Einstellungen.** „Call-Fenster jetzt auslesen"
  (`MeetingsSettingsView.swift:86-103`) für eine Funktion mit leerer Adapterliste, der
  Footer nennt `~/Library/Logs/Notable/screen-probe`. Rohes CLI-Argument-Feld
  (`CLIProviderStatusRow.swift:40-57`). „Beim ersten Start ein kleines Modell
  vorschalten" (`:75`), „Einfügemethode" (`:66`), „VPIO" (`MeetingsSettingsView.swift:106`)
  mit Postmortem-Footer, „Modell: claude-sonnet-5." (`SummarizationSettingsView.swift:86`).
- **Footer in Changelog-Stimme**: `StorageSettingsView.swift:52-55, 69-74, 84-87`,
  `MeetingsSettingsView.swift:117`, `EngineStatusRow.swift:66-72`,
  `GeneralSettingsView.swift:249-258` (sieben Zeilen), `EnhancementSettingsSection.swift:94-109`.
  Vier Abschnitte der Diktat-Seite ohne Überschrift (`:31, :205, :207, :209`);
  destruktive Aktionen in drei Stilen (`.link`, `role: .destructive`, `.borderedProminent`);
  ein `.radioGroup` in der ganzen App (`SummarizationSettingsView.swift:27`).
- **Visuelles System.** `Theme.swift` (113 Zeilen): Farben, drei Radien, `CalCard`,
  `CalSegmented`. Kein Abstands-, Typo-, Schatten- oder Dauer-Token.
  `Theme.textEmphasis == Theme.textDefault` (`:19-20`). **62** `.font(.system(size:))`
  gegen 72 semantische Fonts, getrennt nach Datei; **neun** Eckenradien
  (5, 6, 7, 8, 10, 12 …) gegen drei Tokens. `CalSegmented` einmal benutzt
  (`StatsView.swift:171`), daneben ein System-`.segmented` für dieselbe Aufgabe
  (`RecentDictationsView.swift:38`).
- **Fenster.** Größen als Magie in `NotableApp.swift:404-464` **und** als `minWidth`
  in den Views (`StatsView.swift:140`, `SearchWindow.swift:35`, `SettingsView.swift:55`),
  je Fenster drei Zahlen, die nicht übereinstimmen. Kein `setFrameAutosaveName`. Kein
  `.commands`: kein Über-Fenster, kein Hilfe-Menü; die Version steht nur in
  Allgemein (`GeneralSettingsView.swift:210`). `MeetingsSettingsView.swift:130`
  dokumentiert ein ⇧⌘N, das nirgends registriert ist.
- **Onboarding.** Acht Seiten (`OnboardingView.swift:22`). „Weiter" und
  „Überspringen" funktionieren auf jeder Seite (`:304-315`), auch auf der
  Mikrofon-Seite, deren Text sagt: „Die einzige Berechtigung, ohne die nichts geht"
  (`:79`). Die Erste-Diktat-Seite ist Text und ein Häkchen (`:171-202`). Neun feste
  Punktgrößen in dieser einen Datei.
- **Leerzustände und Fortschritt.** Drei `ContentUnavailableView`, eine eigene Karte,
  sieben ad-hoc `Text("Noch keine …")`; `RecentDictationsView.swift:57` benutzt
  `ContentUnavailableView` als Ladeanzeige. Download-Fortschritt viermal anders
  formuliert (`NotableApp.swift:543`, `OnboardingView.swift:192`,
  `EngineStatusRow.swift:28`, `GeneralSettingsView.swift:279`), einmal als Balken.
- **Icon.** `Resources/AppIcon.icns`, eine Auflösung, kein Asset-Katalog, keine
  Dark-/Tinted-Variante (`project.yml:204`).

## 2. Ziel

Die Diktat-Seite zeigt über dem Falz sechs Dinge; jeder Footer ist ein Satz über die
Wirkung; Messinstrumente sind da, aber nicht in der Vorderreihe; die App benutzt ein
Token-Set und sieht danach aus wie aus einer Hand; Fenster merken sich, wo sie waren;
das Onboarding lässt niemanden ohne Mikrofon zu „Alles bereit" durch.

## 3. Konzept

### 3.1 Drei Regeln für Einstellungen

1. **Messinstrumente stehen hinter ⌥.** Was misst, protokolliert oder überschreibt
   (Call-Fenster-Probe, CLI-Argumente, Latenzzeile, Einfügemethode, Bootstrap,
   Modellinventar-Details), lebt in einer `DisclosureGroup("Erweitert")`, zugeklappt,
   am Ende der Seite — oder als ⌥-Alternative eines Menüpunkts (die Call-Fenster-Probe
   wird „Meeting aufzeichnen" mit gedrückter ⌥: „Call-Fenster auslesen…"; `NSMenuItem`
   kann das nativ, SwiftUI-`Menu` über `.modifierKeyAlternate`).
2. **Ein Footer, ein Satz, über die Wirkung.** Die Begründung gehört in die Spec, der
   Kommentar in den Code. Jeder Footer über zwei Zeilen wird gekürzt; die gestrichenen
   Sätze wandern, wo sie noch nicht stehen, in die betreffende Spec.
3. **Keine Einstellung für eine Vorgabe, die niemand ändern will** (Spec 22 §3.4):
   Bootstrap-Modell (immer an), Einfügemethode (Zwischenablage; Tastatureingabe
   bleibt als Fallback im Code, wird automatisch gewählt, wenn ⌘V zweimal in Folge
   nicht ankam — das ist die einzige ehrliche Auslösung, und sie braucht Spec 29 A4),
   Idle-Timeout-Zahl (feste Vorgabe mit Hysterese; ein Schalter „Freihändig bei Stille
   beenden" bleibt).

### 3.2 Die Diktat-Seite danach

| Abschnitt | Inhalt |
|---|---|
| **Taste** | Push-to-talk-Taste; Verbessern-Taste (wenn eingeschaltet) |
| **Erkennung** | Picker mit **drei Rollen statt drei Herstellern**: „Standard — mehrsprachig", „Englisch — schnell", „Whisper — Vergleich"; `EngineStatusRow` darunter; Sprachen |
| **Text** | ein Schalter „Text aufbereiten" (Füllwörter, Zahlen, Absätze, Struktur, Ziel-App — als **eine** Sache), daneben „Anpassen…" für die fünf Einzelschalter in einem Sheet; Spec 32 hängt hier „Textstufe" an |
| **Wörterbuch & Bausteine** | Tabelle, Vorschläge, Snippets — unverändert, aber unter einer Überschrift |
| **Anzeige & Ton** | Anzeige-Picker (Spec 28), Töne, Wiedergabe pausieren / stummschalten |
| **Erweitert** (zu) | Einfügemethode (nur Anzeige, welche aktiv ist), Idle-Timeout-Zahl, letzte Latenz, Bootstrap-Status |

„Letzte Diktate" verschwindet von der Seite; das Fenster gibt es. Die Historie in den
Einstellungen war eine Bequemlichkeit für den Entwickler.

Meetings: VPIO wird „Echo unterdrücken (nur mit dem Standard-Mikrofon)", Footer ein
Satz. Zusammenfassung: „Modell: claude-sonnet-5." wird ein Hinweis in der
Provider-Zeile, nicht Fließtext; CLI-Argumente unter „Erweitert". Speicherplatz: die
Zahlen bleiben (das ist der Sinn von Spec 20/21), die Footer werden Sätze.
Berechtigungen: unverändert.

Ein Button-Stil für Destruktives: `role: .destructive`, bordered; `.link` nur für
Navigation. Der eine `.radioGroup` wird ein Popup wie die übrigen 17.

### 3.3 Tokens

`Theme` wächst um genau das, was fehlt, und nicht mehr:

```swift
enum Spacing { static let xs: CGFloat = 4, s = 8, m = 12, l = 16, xl = 24 }
enum Type { static let title = Font.title3.weight(.semibold); body = .body;
            secondary = .callout; caption = .caption; mono = .system(.body, design: .monospaced) }
enum Duration { static let appear = 0.12, disappear = 0.16, state = 0.20 }
```

`textEmphasis` und `textDefault` werden eines. Die 62 festen Punktgrößen werden
Rollen — Stats, Onboarding, LiveNotes, Chat, HUD. Die neun Radien werden drei.
`CalSegmented` wird gelöscht, `StatsView:171` benutzt `.pickerStyle(.segmented)`.
Danach ist `grep -rn 'font(.system(size:' Sources` leer, und `cornerRadius:` kommt nur
noch mit `Theme.radius…` vor — beides ein Test in `ThemeTests`, der Quelltext liest,
wie `LocalizationTests`.

### 3.4 Fenster und Menü

`WindowSize` (eine Datei): je Fenster `default` und `min`, gelesen von der Scene
**und** der View. `.windowAutosaveName(id)` als kleiner Modifier über
`NSWindow.setFrameAutosaveName` (per `NSViewRepresentable`-Zugriff auf das Fenster),
damit jedes Fenster dort aufgeht, wo es geschlossen wurde. `.commands`:
`CommandGroup(replacing: .appInfo)` mit einem Über-Fenster (Version, Build, Lizenz,
Notizen-Ordner), `CommandGroup(replacing: .help)` mit „Notable-Hilfe" (README) und
„Einführung zeigen". Der Satz mit ⇧⌘N in `MeetingsSettingsView.swift:130` wird
gestrichen — oder der Shortcut wird als `.keyboardShortcut("n", [.command, .shift])`
auf dem Menüpunkt registriert, der nur wirkt, wenn ein Notable-Fenster key ist;
Vorschlag: streichen, denn ein Shortcut, der meistens nicht geht, ist der schlechtere
Satz. Handtest in der Abnahme: ⌘C/⌘V/⌘Z/⌘A in Chat, Notiz-Editor und Snippet-Editor.

### 3.5 Onboarding

- Mikrofon-Seite: „Weiter" ist inaktiv, bis der Status `granted` ist. „Überspringen"
  bleibt, mit einem Satz: „Ohne Mikrofon funktioniert kein Diktat."
- Erste-Diktat-Seite: die Kapsel selbst, in klein, als Vorschau — `WaveformView` mit
  dem echten Pegel des laufenden Recorders, sobald die Taste gedrückt wird; danach der
  erkannte Text in einer Karte. Der Moment, in dem das Produkt sich selbst zeigt.
- Feste Punktgrößen → Rollen (§3.3). Die Karten-Radien 8 → `Theme.radiusCard`.

### 3.6 Leerzustände und Fortschritt

Ein `EmptyState(title:hint:)` für alle sieben ad-hoc-Texte und die eigene Karte;
`ContentUnavailableView` bleibt für die drei Fenster. `RecentDictationsView:57`
bekommt einen `ProgressView` mit Verzögerung 300 ms. Ein `DownloadProgressRow` für
alle vier Fortschrittsstellen: Balken + Prozent + ein Satz, überall derselbe.

### 3.7 Icon (Entscheidung §7)

Asset-Katalog mit `.icon`-Datei aus Icon Composer (macOS 26), Dark- und Tinted-
Variante. Der Menüleisten-Picker bleibt (er ist eine echte Nutzerwahl), schrumpft aber
auf zwölf Motive; die 40 waren eine Sammlung, keine Auswahl.

## 4. Integration

| Stelle | Änderung |
|---|---|
| `Settings/*.swift` | §3.1–3.2; `DisclosureGroup("Erweitert")` je Seite, wo nötig |
| `NotableApp.swift` | ⌥-Alternativen im Menü; `.commands`; `WindowSize` |
| `Support/Theme.swift`, `Support/WindowSize.swift` (neu), `Support/WindowAutosave.swift` (neu) | Tokens, Größen, Autosave |
| `Stats/*`, `Onboarding/*`, `Meeting/LiveNotesView.swift`, `Meeting/MeetingChat.swift`, `Dictation/DictationOverlay.swift` | Punktgrößen → Rollen, Radien → Tokens |
| `Support/EmptyState.swift`, `Support/DownloadProgressRow.swift` (neu) | §3.6 |
| `Onboarding/OnboardingView.swift` | §3.5 |
| `DefaultsKey.swift` | `bootstrapModel` bleibt als Key (nie umbenennen — `CLAUDE.md`), wird nur nicht mehr gelesen; `dictationIdleTimeout` wird Bool-Semantik über „0 = aus, sonst Vorgabe" |
| `Resources/Assets.xcassets` (neu), `project.yml` | Icon |
| `Tests/ThemeTests.swift` (neu) | die zwei Quelltext-Prüfungen |
| `README.md`, `README.de.md` | Screenshots nach dem Umbau |

Keine Migration; kein Defaults-Key wird umbenannt oder gelöscht.

## 5. Risiken

- **Etwas, das jemand benutzt, verschwindet in „Erweitert".** Es verschwindet nicht,
  es rückt eine Ebene tiefer. Spec 22 §7 hat bewusst keinen Schalter entfernt; diese
  Spec entfernt drei (Bootstrap, Einfügemethode als Wahl, Idle-Timeout-Zahl) und sagt
  bei jedem, warum die Vorgabe reicht.
- **Tastatureingabe automatisch wählen** setzt Spec 29 A4 voraus (Ziel-Vergleich). Bis
  dahin bleibt die Einfügemethode unter „Erweitert" wählbar.
- **Token-Migration ist Fleißarbeit** mit optischem Risiko: 62 Stellen, jede sichtbar.
  Ein Vorher/Nachher-Screenshot je Fenster in der PR, sonst rutscht ein 11-pt-Caption
  auf 13 pt durch.
- **`.commands` in einer Accessory-App** wirken nur, während ein Notable-Fenster key
  ist. Das ist für Über und Hilfe genau richtig; für globale Aktionen taugt es nicht —
  und die stehen hier nicht drin.

## 6. Abnahme

1. Diktat-Seite: fünf Abschnitte plus „Erweitert" (zu); keine Latenzzeile, keine
   Historie, kein Bootstrap-Schalter sichtbar.
2. Kein Footer länger als zwei Zeilen; `grep -rn 'weil\|damals\|früher' Sources/Notable/Settings` liefert nur noch Kommentare.
3. Mit ⌥ gedrücktem Menü erscheint „Call-Fenster auslesen…"; ohne ⌥ nicht.
4. `ThemeTests` grün: keine `.font(.system(size:`, keine nackten `cornerRadius:`.
5. Statistik-Fenster schließen, verschieben, wieder öffnen: gleiche Position.
6. Über-Fenster mit Version; Hilfe-Menü; ⌘C/⌘V/⌘Z/⌘A in allen drei Editoren
   funktionieren (Handtest, protokolliert in §8).
7. Onboarding ohne Mikrofon-Grant: „Weiter" inaktiv; mit Grant: die Erste-Diktat-Seite
   zeigt Wellenform und Text.
8. Vier Fortschrittsstellen sehen gleich aus; kein `ContentUnavailableView` als
   Ladeanzeige.
9. Englisches Fenster: `LocalizationTests` grün nach allen Umformulierungen.

## 7. Offene Entscheidungen

- **Icon neu** (Icon Composer, macOS-26-Look, Dark/Tinted) — ein Gestaltungsauftrag,
  kein Code.
- **Engine-Rollen statt Namen** („Standard — mehrsprachig" statt „Parakeet v3"): Spec 11
  §4 hat eine *Qualitäts*-Skala verworfen, weil sie „Unified = kein Deutsch" versteckt.
  Rollen verstecken das nicht; trotzdem eine Abkehr von der Namensnennung, also fragen.
- **⇧⌘N**: streichen (Vorschlag) oder registrieren.
- **Zwölf Menüleisten-Motive statt vierzig**: welche.

## 8. Handtests

*Noch nicht gelaufen.* ⌘C/⌘V/⌘Z/⌘A in Chat, Notiz-Editor, Snippet-Editor — Datum und
Ergebnis hierher. Die Handtests von 28–33 stehen gesammelt in
`docs/handtests-1.3.0.md`.

## 9. Stand des Baus (2026-09-14)

**Gebaut:**

- **Tokens** (§3.3): `Theme.Spacing`, `Theme.Typography` (die zwei Größen, die kein
  Textstil abdeckt), `Theme.Motion`, `Theme.radiusMark` für Diagramm-Marken;
  `textDefault` ist in `textEmphasis` aufgegangen. Alle 62 festen Schriftgrößen sind
  semantische Stile, alle 17 freien Radien Tokens, `CalSegmented` ist gelöscht und die
  Statistik benutzt das System-Segment. `ThemeTests` prüft das am Quelltext.
- **Fenster** (§3.4): `WindowSize` ist die eine Tabelle für Szene und View; jedes
  Fenster merkt sich seinen Rahmen (`windowFrameAutosave`). Das Hauptmenü hat
  „Über Notable", „Notable-Hilfe" und „Einführung zeigen".
- **Einstellungen** (§3.1, §3.2): Footer in einem Satz auf den Seiten Diktat, Meetings,
  Speicherplatz, Allgemein, Menüleiste und Berechtigungen. Unter „Erweitert":
  Einfügemethode, Vorschaltmodell und Latenzzeile (Diktat), Call-Fenster-Probe,
  unterstützte Apps und Hook-Skript (Meetings), CLI-Argumente (Zusammenfassung). Die
  Kopie der Diktat-Historie ist von der Diktat-Seite verschwunden. „VPIO" heißt „Echo
  unterdrücken", der Satz mit ⇧⌘N ist gestrichen (Vorschlag aus §7), destruktive
  Knöpfe tragen `role: .destructive`, die eine Radio-Gruppe ist ein Popup.
- **Onboarding** (§3.5): „Weiter" ist auf der Mikrofon-Seite ohne Freigabe aus, mit
  einem Satz, was Überspringen kostet. Die Erste-Diktat-Seite zeigt die Wellenform live
  (`LevelMeter`, ein eigenes Objekt, damit 30 Updates pro Sekunde nicht jede Ansicht des
  Controllers neu zeichnen) und danach den angekommenen Text.
- **Leerzustände und Fortschritt** (§3.6): `EmptyState` für Listen in Formularen,
  `DownloadProgressRow` mit einer Formulierung („Lädt: 40 %"); „Letzte Diktate" zeigt
  beim Laden einen Spinner statt eines Leerzustands. `LocalizationTests` scannt
  `DisclosureGroup` und `EmptyState` mit.

**Abweichungen und nicht gebaut:**

1. **⌥-Alternative im Menü → „Erweitert" in den Einstellungen.** SwiftUIs
   `modifierKeyAlternate` braucht macOS 15, das Deployment-Target ist 14.4.
2. **Kein Sammelschalter „Text aufbereiten"** mit Sheet (§3.2); die fünf Schalter
   bleiben, jetzt mit einem Footer-Satz.
3. **Vorschaltmodell und Einfügemethode sind nicht entfernt** (§3.1 Regel 3), sondern
   unter „Erweitert". Ein automatischer Wechsel zur Tastatureingabe bräuchte ein Signal,
   ob ⌘V ankam, und das gibt macOS nicht (Spec 29 §3.5).
4. **Abstände nicht migriert.** Die Tokens existieren und die neuen Bausteine benutzen
   sie; die bestehenden Paddings umzustellen ist optisches Risiko ohne Vorher/Nachher-
   Bilder, also ein eigener Schritt.
5. **Offene Entscheidungen aus §7 unberührt:** neues Icon, Engine-Rollen statt Namen,
   zwölf statt vierzig Menüleisten-Motive. Die eigene Leer-Karte der Statistik bleibt.
6. README-Screenshots nicht erneuert.

**Tests:** `ThemeTests` 3 (neu); 148 Tests der betroffenen Klassen grün. **Nicht
verifiziert:** alles, was man sehen oder bedienen muss — Abnahme 1, 3, 5–8, darunter ob
der Frame-Autosave bei SwiftUI-`Window`-Szenen tatsächlich greift und ob
⌘C/⌘V/⌘Z/⌘A in den Editoren funktionieren (§8).

### Nachtrag: vervollständigt (2026-09-14)

Auf Ansage „alles vollständig bauen", mit den Vorschlägen aus §7 wo es einen gibt:

- **Sammelschalter „Text aufbereiten"** (Abweichung 2 aufgehoben): ein Schalter für
  Füllwörter, Zahlen, Absätze, Struktur und Ziel-App; „Angepasst", sobald die fünf
  nicht gleich stehen; „Anpassen…" öffnet die fünf Einzelschalter samt App-Zuordnungen
  in einem Sheet.
- **Die Diktat-Seite in der Reihenfolge von §3.2:** Taste, Erkennung, Text,
  Textstufe auf dem Gerät, Verbesserung, Wörterbuch & Bausteine, Anzeige & Ton,
  Erweitert. Der Idle-Timeout ist ein Schalter „Freihändig bei Stille beenden"
  (45 s); die Zahl steht unter „Erweitert".
- **Engine-Rollen** (§7): „Standard — mehrsprachig (Parakeet v3)", „Englisch — schnell
  (Parakeet Unified)", „Vergleich — Whisper (OpenAI)". Der Name bleibt im Label, damit
  „nur Englisch" nie hinter einem Rollenwort verschwindet (Spec 11 §4).
- **Zwölf Menüleisten-Motive** (§7, Auswahl: Wellenform ×4, Mikrofon ×3, Sprechblase,
  Untertitel, Notiz, Aufnahme, Notieren). Ein gespeichertes Motiv aus der alten Liste
  funktioniert weiter und steht als „Bisherige Wahl" im Picker.
- **⌥-Alternative** (Abweichung 1 ergänzt): mit gedrückter ⌥ wird „Meeting aufzeichnen"
  zu „Call-Fenster auslesen…" — ab macOS 15; auf 14 bleibt nur der Knopf unter
  „Erweitert".
- **Abstände migriert** (Abweichung 4 aufgehoben): 56 Stellen in 18 Dateien, **nur**
  exakte Werte der Skala (4/8/12/16/24 → `Theme.Spacing`), also ohne sichtbare
  Änderung. Zwischenwerte (6, 10, …) bleiben Zahlen — sie auf die Skala zu runden,
  verschiebt Pixel, die niemand angesehen hat. `ThemeTests` hält das fest;
  `DictationOverlay.swift` ist ausgenommen, weil es ohne `Theme` im Test-Bundle liegt.

**Weiter nicht gebaut:** das App-Icon (Icon Composer, ein Gestaltungsauftrag ohne
Vorschlag in §7), die README-Screenshots, und Abweichung 3 bleibt (Einfügemethode und
Vorschaltmodell unter „Erweitert", nicht entfernt). **Tests:** `ThemeTests` +1;
Regressionslauf ohne Modell-Suiten 825 Tests grün.
