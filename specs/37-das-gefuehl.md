# Spec 37 — Das Gefühl: Bewegung, Zahlen, Momente

> **Aufwand: M–L (≈ 6 Tage): Bewegungssystem S, HUD-Momente S–M, Statistik M, Wochenrückblick
> und Meilensteine S, Onboarding-Zahl S.** Notable ist bei Erkennung, Latenz, Ressourcen und
> Datenschutz vor Wispr Flow (`docs/analyse-wispr-flow-paritaet-2026-09-14.md` §1) und fühlt
> sich trotzdem nach weniger an. Der Grund steht in der Inventur unten: in ~25 000 Zeilen
> Swift gibt es **fünf** Animationsstellen, der `Theme.Motion`-Token wird nirgends benutzt,
> und die einzige Zahl, die je gefeiert wird, ist eine Textzeile in der Fußzeile einer Karte.
> Diese Spec baut kein Feature. Sie macht aus dem, was Notable ohnehin tut, Momente, die man
> spürt — und hält dabei die drei Regeln ein, die diesen Code prägen: nie key werden, nie
> eine Zahl schätzen, nie den Diktatpfad verlangsamen.

## 1. Ausgangslage (Fakten aus dem Code, 2026-09-16)

- **Bewegung.** Fünf Stellen: HUD-Einblenden 0,12 s und -Ausblenden 0,16 s als
  `NSAnimationContext`-Literale (`DictationOverlay.swift:136, :252`), Pillen-Spring
  bei `locked` (`:424`), Wellenform 0,04 s (`:528`), Hover im Balkendiagramm 0,12 s
  (`StatsView.swift:705`). Dazu ein `withAnimation` fürs Scrollen im Chat. **Null**
  `.transition`, `symbolEffect`, `contentTransition`, `phaseAnimator`,
  `matchedGeometryEffect`. `Theme.Motion` (Spec 33 §3.3) ist definiert und **nirgends
  referenziert**; `Theme.hover` ebenso; `Theme.Spacing.xl` ebenso. Reduce Motion wird nur
  im HUD gelesen.
- **Das HUD** zeigt während der Aufnahme die Wellenform (18 Kapseln, 30 Hz aus
  `DictationController.swift:218`), springt dann zu „Transkribiere…" mit Spinner (erst ab
  300 ms, Spec 30) und **verschwindet nach dem Einfügen ohne ein Wort**: der Ton
  `cue-done` ist das einzige Signal, dass 42 Wörter angekommen sind. Ein freihändig
  fixiertes Diktat zeigt eine ruhende Wellenform bei Stille — ob das Mikrofon noch offen
  ist, sieht man nicht.
- **Die Statistik** (`StatsView.swift`, 718 Zeilen) ist das am besten gestaltete
  Fenster: Hero mit Verlauf, vier Kacheln mit Delta-Chips, zwei Balkendiagramme, unter
  „Details" Heatmap, Engines, Ziel-Apps, Textstufen. Sie ist vollständig **statisch**:
  Zahlen erscheinen, Balken stehen, ein Wechsel Tag → Woche tauscht das Bild. Die
  Serie steht als eine `.callout`-Zeile mit Flammensymbol (`:244-251`), mit dem
  Kommentar, dass eine Serie eine Zeile bekommt und kein Diagramm. Es gibt keinen
  Rekord, keinen Meilenstein, keinen Rückblick — `grep` auf `milestone|record|celebrat`
  ist leer.
- **Die Menüleiste** ist `.menuBarExtraStyle(.menu)` (`NotableApp.swift:411`), also ein
  echtes `NSMenu`: kein eigenes Zeichnen, keine Farbe, keine Bewegung. Die Zeile
  „Heute: 1.240 Wörter · 38 min gespart" (`UsageMetrics.menuLine`) ist ein
  deaktivierter `Text`.
- **Fenster.** Notizen, Suche, Letzte Diktate: `List(.inset)` mit `.headline`/`.callout`,
  ohne Hover-Zustand, ohne Übergang beim Laden. „Kopieren" → „Kopiert" wechselt den
  Text hart (`RecentDictationsList.swift:90-97`).
- **Onboarding** zeigt seit Spec 33 die Wellenform live und den erkannten Text — aber
  nicht, was das Diktat gerade *gebracht* hat.
- **Bestand auf diesem Rechner:** 234 Diktate, 7 977 Wörter, 33 Meetings seit dem
  13.07.2026. Genug für Rekorde und Rückblicke, zu wenig für „Top 5 %"-Vergleiche —
  die es hier ohnehin nie geben wird (§3.6).

## 2. Ziel

Jeder Zustandswechsel, den der Nutzer sieht, hat einen Übergang aus einem Token-Set.
Das HUD ist eine **einzige Form**, die sich durch das Diktat bewegt, und am Ende steht
dort für einen Moment, was passiert ist. Die Statistik **zählt hoch**, zeichnet ihre
Linien und kennt Rekorde und Meilensteine, die aus `recordings` stammen und nie
geschätzt sind. Einmal die Woche sagt Notable, was es diese Woche erledigt hat. Und die
119 ms bleiben 119 ms.

## 3. Konzept

### 3.1 Ein Bewegungssystem, das benutzt wird

`Theme.Motion` wächst von drei Dauern zu dem, was die App tatsächlich braucht, und wird
zur **einzigen** Quelle:

```swift
enum Motion {
    static let appear    = Animation.easeOut(duration: 0.12)
    static let disappear = Animation.easeIn(duration: 0.16)
    static let state     = Animation.spring(response: 0.30, dampingFraction: 0.85) // Formwechsel
    static let gentle    = Animation.spring(response: 0.55, dampingFraction: 0.90) // Zahlen, Diagramme
    static let breathe   = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)
    static let level     = Animation.linear(duration: 1.0 / 30)                      // Wellenform
}
```

Regel: `Motion.x` oder nichts — `ThemeTests` prüft am Quelltext, dass außerhalb von
`Theme.swift` keine `.easeOut(duration:`, `.spring(response:` oder `NSAnimationContext
…duration =` mehr vorkommt (dasselbe Muster wie für Schriftgrößen und Radien).
`@Environment(\.accessibilityReduceMotion)` an jeder Stelle, die animiert — heute nur im
HUD; das Statistik-Hover ignoriert es. Bei Reduce Motion werden Übergänge zu Opazität,
Zahlen erscheinen fertig, nichts atmet.

Dazu die zwei toten Tokens: `Theme.hover` wird der Hover-Hintergrund jeder Listenzeile
(Notizen, Suche, Letzte Diktate), `Spacing.xl` der Abstand zwischen Karten-Gruppen der
Statistik — oder beide werden gelöscht. Ein Token, das niemand benutzt, ist ein
Versprechen ohne Einlösung.

### 3.2 Das HUD als eine Form (S–M)

Heute: sechs Zustände, sechs `HStack`s, hart umgeschaltet. Danach: **eine Kapsel, die
ihre Form behält und ihren Inhalt bewegt.**

| Moment | Was passiert | Mittel |
|---|---|---|
| Taste gedrückt | Kapsel wächst aus der Mitte auf (nicht Fade), Wellenform beginnt beim ersten Pegel | `.scaleEffect` 0,8 → 1 mit `Motion.state`, `Motion.appear` für Opazität |
| Aufnahme | Wellenform wie heute (30 Hz, Gain 8, Exponent 0,7); zusätzlich ein schwacher Glow hinter der Kapsel, dessen Opazität dem Pegel folgt (0 → 0,25) — der Pegel wird *sichtbar*, nicht nur die Form | `.shadow(color: accent.opacity(level*0.25))` |
| Freihändig fixiert, Stille | Die Kapsel **atmet**: Skala 1,0 ↔ 1,02 alle 1,6 s. Das ist die Antwort auf „ist das Mikro noch offen?" — ein Zustand, den heute nichts zeigt | `Motion.breathe`, nur bei `locked && level < 0,02` |
| Loslassen | Wellenform **fällt** in einer Bewegung auf eine Linie (die 18 Kapseln auf Höhe 2,5), die Linie **pulsiert** solange transkribiert wird | `Motion.state` auf `history = zeros`; Spinner entfällt |
| Text eingefügt | Aus der Linie wächst ein ✓, daneben **„42 Wörter"** — 700 ms, dann Ausblenden. Bei ≥ 25 Wörtern zusätzlich „· ≈ 45 s gespart" aus derselben Rechnung wie die Statistik (`UsageMetrics.savedSeconds`) | `symbolEffect(.bounce)`, `contentTransition(.numericText())` |
| Meilenstein | Statt „42 Wörter": „10.000 Wörter diktiert" für 1,5 s, ✓ mit `.bounce` doppelt; einmal je Meilenstein (§3.5) | dieselbe Fläche, längere Dauer |
| Formatiere… / Verbessere… | Linie pulsiert wie beim Transkribieren; der Text steht rechts davon; bei „Verbessere…" kippt die Akzentfarbe auf Orange — Text verlässt das Gerät, und das sieht anders aus | `Motion.state` für den Farbwechsel |
| Fehler / Hinweis | Kapsel wird **nicht** rot, sie wird breit: der Text schiebt sich aus der Mitte auf, das Symbol kommt mit `.appear`. Die Fehlerfläche aus Spec 30 bleibt, wie sie ist, sie bewegt sich nur | `matchedGeometryEffect` für das Symbol |
| Abbruch (Esc / ×) | Kapsel schrumpft auf die Höhe der Linie und verschwindet — sichtbar anders als das Ausblenden nach Erfolg | `Motion.disappear` + `.scaleEffect(y: 0.2)` |

Drei Regeln, die dabei nicht verhandelbar sind:

1. **Der Erfolgsmoment kommt nach dem Paste, nie davor.** `Paster.insert` läuft wie
   heute; das HUD erfährt danach die Wortzahl. `LatencyProbeTests` misst Loslassen →
   Einfügen und darf sich um 0 ms bewegen. Die 700 ms sind Anzeige, kein Warten.
2. **Text nur, wo die Wellenform nicht sprechen kann** (CLAUDE.md). Die Wortzahl ist ein
   Nicht-Aufnahme-Zustand; während der Aufnahme bleibt es bei Wellenform, Glow und Atem.
3. **Das Panel wird nie key** — keine der Bewegungen berührt `canBecomeKey`,
   `ignoresMouseEvents` oder das Hover-Fenster des ×. `DictationOverlayTests` bleiben
   der Wächter, ein neuer Test prüft, dass `show(.notice)` mit Reduce Motion ohne
   Animation ankommt.

Die Notch-Variante bekommt dieselben Momente in ihrer Geometrie: die zwei Streifen
wachsen aus der Notch heraus, die Wortzahl steht rechts. Der Platz „Rechts am Rand"
(Spec 28) wächst weiter von der Kante nach innen.

### 3.3 Die Statistik, die etwas mit einem macht (M)

Das Fenster bleibt in seiner Struktur — es ist gut. Was fehlt, ist Bewegung, Vergleich
mit sich selbst und ein Grund, es zu öffnen.

**Bewegung.**
- Die Hero-Zahl **zählt beim Öffnen hoch**, 0 → Wert in `Motion.gentle`
  (`contentTransition(.numericText())` über einen animierten Zwischenwert); die
  Sparkline **zeichnet sich** von links (Trim 0 → 1). Die Kacheln erscheinen
  gestaffelt mit 40 ms Versatz. Ein Wechsel Tag → Woche → Monat **morpht** die Balken
  (`.animation(Motion.gentle, value: series)`) statt das Bild zu tauschen.
- Delta-Chips kippen beim Wechsel (`contentTransition(.numericText(countsDown:))`).
- Alles davon respektiert Reduce Motion: dann steht die Zahl sofort.

**Vergleich mit sich selbst — die Karte „Rekorde".** Aus `recordings`, nie geschätzt,
nur Zeilen mit vollständigen Werten (Spec 01: nullable Spalten bleiben unbekannt):

| Rekord | Quelle |
|---|---|
| Längstes Diktat | `max(word_count)` einer Diktat-Zeile, mit Datum |
| Meistes an einem Tag | Tagesbucket mit `max(dictationWords)` |
| Beste Woche | Wochenbucket mit `max(savedSeconds)` |
| Längste Serie | `UsageMetrics.longestStreak` (neu; heute nur die aktuelle) |
| Schnellstes Diktat | `min(latency_ms)` bei ≥ 10 Wörtern, nur wenn `latency_ms` gesetzt |

Ein Rekord, der **in dieser Periode** gebrochen wurde, trägt ein kleines Band „Neu" und
bekommt beim ersten Öffnen danach ein `.bounce`. Die Karte steht **über** „Details",
nicht darin — sie ist der Grund, das Fenster zu öffnen.

**Die Serie wird eine Fläche, keine Zeile.** Ring mit Flamme, aktuelle Zahl groß,
darunter „Bester: 23 Tage". Das kehrt den Kommentar in `StatsView.swift:244` bewusst um
— er war richtig, solange die Serie eine Nebensache war; wenn sie das Gefühl tragen
soll, braucht sie Platz. Was bleibt: **keine Strafe**. Eine gerissene Serie wird nicht
rot, sie wird „Neue Serie: 1 Tag". Wispr macht Streaks zu Druck; hier ist es eine
Beobachtung.

**Das Jahr als Raster.** Bei Granularität „Jahr" ersetzt ein 52 × 7-Raster (wie die
Heatmap, `HeatmapCard`, nur Tage statt Stunden) das Balkendiagramm der Wörter — ein Jahr
Diktieren auf einen Blick, mit Hover je Tag. Dieselbe Farbskala, dieselbe
`radiusMark`-Zelle. Bestandsdaten seit Juli füllen zehn Wochen; das ist ehrlich und wird
mit der Zeit voll.

**„3,4× schneller als Tippen."** Aus `wordsPerMinute` (gemessen an der Aufnahmedauer)
gegen `typingWPM` (die Vorgabe aus dem Stepper) — beide gibt es. Steht als Satz unter
der Hero-Zahl, mit `.help`, wie er zustande kommt. Ändert der Nutzer die
Tippgeschwindigkeit, ändert sich die Zahl vor seinen Augen (`Motion.gentle`).

### 3.4 Der Wochenrückblick (S)

Montag, erste Aktivität nach 8 Uhr (kein fester Timer — eine Menübar-App ohne Timer ist
die bessere Menübar-App), eine Mitteilung:

> **Deine Woche mit Notable**
> 4.210 Wörter · 3 Meetings · 1 h 12 min gespart — 18 % mehr als in der Vorwoche.
> Serie: 9 Tage.

Klick öffnet die Statistik auf „Woche". Die Zahlen sind `UsageMetrics.totals` und
`delta` über dieselben Buckets wie das Fenster. Kein neuer Datenpfad. Ein Schalter
„Wochenrückblick" unter Allgemein → Mitteilungen (Spec 38 legt die Gruppe an), Vorgabe
**an** (§7): es ist eine Mitteilung pro Woche, und sie ist der Moment, in dem Notable
einmal ungefragt sagt, was es getan hat. Fällt die Woche unter 100 Wörter, kommt keine
Mitteilung — eine Woche ohne Diktate braucht keinen Rückblick.

### 3.5 Meilensteine (S)

Feste Liste, aus `recordings` gezählt, einmal je Schwelle erreicht (Marker in
`UserDefaults`, `milestonesReached`):

- Wörter: 1 000 · 10 000 · 50 000 · 100 000 · 500 000 · 1 000 000
- Diktate: 100 · 1 000 · 10 000
- Gespart: 1 h · 10 h · 100 h
- Meetings: 10 · 100
- Serie: 7 · 30 · 100 · 365 Tage

Der Moment ist das HUD (§3.2), nicht eine Mitteilung — er gehört an die Stelle, an der
er passiert ist. Die Statistik führt sie unter „Rekorde" als Leiste mit erreichten und
dem nächsten („noch 2.023 bis 10.000"). **Meilensteine werden aus dem Bestand
nachgeholt**, aber nicht gefeiert: beim ersten Start nach dem Update werden alle bereits
überschrittenen Schwellen still markiert. Sonst feiert Notable am Dienstag 1 000 Wörter
vom Juli.

Retention löscht Text, nie Zeilen (issue #2) — deshalb können Meilensteine und Rekorde
aus `recordings` gezählt werden, ohne je zu schrumpfen. Diese Entscheidung von damals
ist der Grund, warum diese Spec keine eigene Zähltabelle braucht.

### 3.6 Was bewusst nicht gebaut wird

- **Vergleich mit anderen** („Top 5 % der Nutzer"): es gibt keine anderen, und es gibt
  keinen Server. Notable vergleicht den Nutzer nur mit sich selbst.
- **Konfetti, Partikel, Sound-Fanfaren.** Ein Bounce auf einem ✓ ist die Grenze. Die
  fünf Töne aus Spec 30 bleiben die fünf Töne; ein Meilenstein spielt `cue-done`.
- **Ein eigenes Menü-Panel** (`.menuBarExtraStyle(.window)`) als Wispr-„Hub". Es wäre
  die einzige Stelle, an der man in der Menüleiste Farbe und Bewegung bekäme — und es
  ist ein Fenster, das key wird, mit bekannten Schließ- und Fokusproblemen in
  Accessory-Apps. Vorschlag: nein; die „Heute"-Zeile im Menü wird klickbar und öffnet
  die Statistik (Spec 38). Entscheidung in §7.
- **Haptik.** `NSHapticFeedbackManager` ist für Trackpad-Gesten gedacht; ein Klopfen
  beim Loslassen einer Taste ist auf dem Mac fremd.
- **Ein ziehbares HUD.** Panel darf nie key werden; vier Plätze im Picker decken es ab
  (Analyse §7).

### 3.7 Kleine Stellen, die man täglich sieht (½ Tag)

- „Kopieren" → „Kopiert": `contentTransition(.symbolEffect)` auf einem ✓, zurück nach
  1,5 s.
- Listen laden: Zeilen erscheinen mit `Motion.appear` und `.transition(.opacity)`;
  Leerzustände blenden ein statt zu springen.
- Hover-Hintergrund `Theme.hover` auf Listenzeilen in Notizen, Suche, Letzte Diktate.
- Download-Fortschritt (`DownloadProgressRow`): der Balken bewegt sich in `Motion.gentle`
  statt zu springen.
- Onboarding, Seite „Dein erstes Diktat": nach dem Text ein Satz mit `.numericText`:
  **„23 Wörter in 6 s. Getippt: etwa 35 s."** Das ist der Moment, in dem das Produkt
  sich erklärt, ohne einen Satz Marketing.
- Settings-Seitenwechsel: Inhalt mit `.transition(.opacity)` in `Motion.appear`.

## 4. Integration

| Stelle | Änderung |
|---|---|
| `Support/Theme.swift` | `Motion` erweitert (§3.1); `hover`/`Spacing.xl` benutzt oder gelöscht |
| `Tests/ThemeTests.swift` | keine Animations-Literale außerhalb `Theme` |
| `Dictation/DictationOverlay.swift` | §3.2: eine Kapsel, Zustandsinhalte als Übergänge; Glow; Atem; Erfolgsmoment; `OverlayState.done(words:savedSeconds:milestone:)` |
| `Dictation/DictationTextStages.swift` | nach `paste` und `save`: `overlay.show(.done(...))` — nach, nie davor |
| `Dictation/DictationPipeline.swift` | `afterPaste` liefert die Wortzahl und ob ein Meilenstein fiel (pur, getestet) |
| `Stats/UsageMetrics.swift` | `records(_:)`, `longestStreak`, `milestones(_:)`, `yearGrid(_:)`, `speedFactor(wpm:typingWPM:)` — alles pur |
| `Stats/StatsView.swift`, `Stats/Cards/RecordsCard.swift` (neu), `StreakCard.swift` (neu), `YearGridCard.swift` (neu) | §3.3 |
| `Stats/WeeklyRecap.swift` (neu, pur) + `Support/NotificationCenterService.swift` | §3.4; Auslöser in `AppDelegate` bei erster Aktivität |
| `Stats/Milestones.swift` (neu, pur) | §3.5; Nachholen beim ersten Start |
| `Notes/RecentDictationsList.swift`, `Notes/NoteListView.swift`, `Search/SearchWindow.swift`, `Support/EmptyState.swift` | §3.7 |
| `Onboarding/OnboardingView.swift` | Satz nach dem ersten Diktat |
| `DefaultsKey.swift` | `weeklyRecap` (Vorgabe `true`), `milestonesReached`, `showWordCountAfterDictation` (Vorgabe `true`) |

Keine Migration; `recordings` reicht für alles.

## 5. Risiken

- **Der Diktatpfad wird langsamer, ohne dass es jemand merkt.** Jede Animation im HUD
  läuft auf dem Main-Actor, und der Paste auch. Deshalb: `LatencyProbeTests` vor und
  nach, Abnahme 1 ist die Zahl. Der Erfolgsmoment ist eine Anzeige *nach* dem Ende der
  gemessenen Strecke.
- **Zu viel.** Ein HUD, das atmet, glüht und zählt, kann anstrengend werden. Die Sperren:
  Glow ≤ 0,25 Opazität, Atem nur bei fixierter Stille, Wortzahl 700 ms, ein Bounce.
  Ein Schalter „Wortzahl nach dem Diktat anzeigen" (§7) für den, der nur den Ton will.
- **Rekorde aus dünnen Daten.** „Schnellstes Diktat" mit `latency_ms` aus einem kalten
  Modell wäre ein Fehlwert — deshalb ≥ 10 Wörter und nur gesetzte Werte; unter 10
  Samples steht die Zeile nicht (dieselbe Regel wie die Latenz-Karte).
- **Der Wochenrückblick nervt.** Eine Mitteilung pro Woche, unter 100 Wörtern keine,
  ein Schalter. Wenn er trotzdem stört, ist er in einem Klick aus — und die Mitteilung
  sagt das im Untertitel beim ersten Mal.
- **Reduce Motion vergessen.** Ein `ThemeTests`-Fall zählt `accessibilityReduceMotion`-
  Lesungen gegen `Motion.`-Nutzungen je Datei — grob, aber es fängt die Datei, die
  animiert und nie fragt.
- **Der Erfolgsmoment verrät die Wortzahl auf einem fremden Bildschirm** (Screen-Share
  während eines Diktats). Es ist eine Zahl, kein Text; das HUD zeigte bisher nichts, was
  jemand lesen könnte, und tut es mit „42 Wörter" auch nicht.

## 6. Abnahme

1. `LatencyProbeTests` Loslassen → Einfügen: Median vorher/nachher innerhalb 5 ms.
2. `ThemeTests` grün: kein Animations-Literal außerhalb `Theme.swift`; `Motion`
   referenziert ≥ 15×.
3. Handtest HUD (GIF in `docs/images/`): Aufwachsen, Wellenform, Atem nach 3 s Stille
   im fixierten Modus, Fall auf die Linie, ✓ mit Wortzahl, Abbruch-Schrumpfen — in allen
   vier Plätzen. Mit Reduce Motion: nur Opazität, sofortige Zahlen.
4. `DictationOverlayTests`: `canBecomeKey == false` unverändert; `.done` mit Reduce
   Motion erscheint ohne Animation.
5. Statistik: Zahl zählt hoch, Sparkline zeichnet, Tag → Woche morpht; „Rekorde"-Karte
   mit fünf Zeilen aus den Bestandsdaten; Serie als Ring; Jahr-Raster mit Hover.
6. Meilensteine: frische Installation mit Bestand markiert alle überschrittenen still;
   das nächste Diktat über 10 000 Wörter zeigt den Moment einmal, das übernächste nicht.
7. Wochenrückblick: am Montag nach der ersten Aktivität eine Mitteilung mit den Zahlen
   des Statistik-Fensters für „Woche"; Klick öffnet dort; Schalter aus ⇒ keine.
8. Onboarding: der Satz „n Wörter in m s. Getippt: etwa k s." steht nach dem ersten
   Diktat; ohne Diktat steht er nicht.
9. `LocalizationTests` grün für alle neuen Sätze (Wortzahl `%lld`, Dauer `%@`).

## 7. Offene Entscheidungen

- **Wortzahl nach dem Diktat: an in der Vorgabe** (Vorschlag) — es ist die eine Stelle,
  an der Notable sagt, dass es geklappt hat, und der Ton allein sagt nicht, wie viel.
  Oder aus, weil das HUD bisher nach dem Paste nichts zeigte und das eine bewusste
  Zurückhaltung war.
- **„≈ 45 s gespart" im HUD** ab 25 Wörtern — oder nur die Wortzahl, und die gesparte
  Zeit bleibt der Statistik. Vorschlag: nur Wortzahl; die gesparte Zeit beruht auf der
  Tipp-Vorgabe und ist im HUD eine Behauptung, in der Statistik eine Rechnung mit
  `.help`.
- **Wochenrückblick an in der Vorgabe** (Vorschlag) oder aus. Ändert das Verhalten der
  laufenden Installation um eine Mitteilung pro Woche.
- **Menü-Panel statt `NSMenu`** (§3.6): nein (Vorschlag) — oder ja, als Hub mit
  Heute-Ring, letzten Diktaten und Aktionen, dann als eigene Spec, weil es die
  Fokusregeln einer Accessory-App berührt.
- **Serie als Ring** statt Zeile: Vorschlag ja; die Gegenposition steht als Kommentar im
  Code und war nicht falsch.
- **Reihenfolge zu Spec 38:** 38 zuerst (weniger Flächen zu bewegen), dann 37.
  Vorschlag ja.

## 8. Handtests

*Noch nicht gelaufen.* GIFs je HUD-Platz und ein Screenshot der Statistik nach
`docs/images/`; Latenzwerte vorher/nachher hierher.

## 9. Stand des Baus (2026-09-16)

**Gebaut, mit den Vorschlägen aus §7** (Wortzahl an, nur die Wortzahl, Rückblick an,
kein Menü-Panel, Serie als Ring, beide toten Tokens benutzt statt gelöscht).

- **§3.1 Bewegungssystem.** `Theme.Motion` trägt jetzt `appear`, `disappear`, `state`,
  `gentle`, `breathe`, `level` und `appear(delay:)` — dazu dieselben Zahlen als Sekunden
  (`appearSeconds`, `disappearSeconds`, `doneSeconds`, `milestoneSeconds`), weil
  `NSAnimationContext` keine `Animation` nimmt und das Panel die einzige Fläche ist, die
  SwiftUI nicht erreicht. **30 Referenzen in 10 Dateien**; außerhalb von `Theme.swift`
  steht kein Animationsliteral mehr. `Theme.hover` ist der Hover-Hintergrund in Notizen,
  Suche und Letzte Diktate, `Spacing.xl` der Abstand zwischen den Kartengruppen der
  Statistik (5 Stellen zusammen). `ThemeTests` prüft alle drei Regeln am Quelltext, dazu
  die grobe vierte aus §5: **jede Datei, die `Motion` benutzt, liest auch Reduce
  Motion** — genau die Lücke, durch die das Statistik-Hover jahrelang gefallen ist.
- **§3.2 HUD.** Neuer Zustand `done(words:milestone:)`; `flashDone` wird **nach**
  `Paster.insert` **und nach** dem Speichern gerufen (`DictationTextStages.successMoment`
  entscheidet, `DictationPipeline.afterPaste` ist die pure Regel dahinter). Dazu: die
  Kapsel wächst aus der Mitte (0,8 → 1), ein Glow hinter ihr folgt dem Pegel bis 0,25,
  sie atmet bei fixierter Stille, die Wellenform **fällt auf eine Linie und pulsiert**
  statt eines Spinners, „Verbessere…" kippt auf Orange, und ein Abbruch schrumpft
  (`hide(.shrink)`) statt zu faden. `HUDMotion` ist die eine Stelle, an der Reduce Motion
  gelesen wird — überschreibbar, weil ein Test keine Systemeinstellung umlegen kann.
- **§3.3 Statistik.** Die Hero-Zahl zählt hoch, die Sparkline zeichnet sich von links
  (Maske, weil Swift Charts kein Trim hat), die Kacheln kommen 40 ms versetzt, ein
  Wechsel Tag → Woche → Monat morpht die Balken, Delta-Chips kippen numerisch. Neu:
  `RecordsCard` (fünf Rekorde aus `recordings`, „Neu"-Band für die dieser Periode, plus
  die Meilenstein-Leiste „Noch 2.023 bis 10.000 Wörter diktiert"), `StreakCard` (Ring auf
  die nächste Serien-Schwelle, „Bester: n Tage", ohne Strafe) und `YearGridCard`, das bei
  Granularität „Jahr" das Wörter-Balkendiagramm ersetzt. Unter der Hero-Zahl steht
  „3,4× schneller als Tippen" mit `.help`.
- **§3.4 Wochenrückblick.** `WeeklyRecapRules` (pur): Montag, ab 8 Uhr, höchstens einmal
  je Kalenderwoche, unter 100 Wörtern gar nicht. Ausgelöst beim Start und nach jedem
  Diktat — kein Timer. Klick öffnet die Statistik. Schalter „Wochenrückblick" unter
  Allgemein › Mitteilungen, Vorgabe an.
- **§3.5 Meilensteine.** `Milestones` (pur) und `UsageMoments` (der Zwischenspeicher, der
  die Lebenszahlen einmal beim Start aus `recordings` liest und danach nur noch um das
  wächst, was gerade gespeichert wurde — damit der Moment *im* Moment feststeht und nicht
  eine Datenbankabfrage später). **Das Nachholen ist still**: fehlt der Schlüssel
  `milestonesReached`, werden alle überschrittenen Schwellen markiert und keine gefeiert.
- **§3.7 Kleine Stellen.** „Kopieren" → „Kopiert" mit Symbolwechsel und Rückfall nach
  1,5 s, Hover auf den Listenzeilen, Leerzustände blenden ein, der Download-Balken
  bewegt sich, und im Onboarding steht nach dem ersten Diktat „23 Wörter in 6 s.
  Getippt: etwa 35 s."

**Abweichungen:**

1. **Der Schalter „Wortzahl nach dem Diktat" hat keine Oberfläche.** Er gehört auf
   Diktat › Anzeige & Ton, und diese Seite baut gerade Spec 36. Der Schlüssel existiert,
   die Vorgabe ist an, ein gespeichertes `false` wird gelesen — wie bei den anderen
   Schlüsseln ohne Fläche seit Spec 38.
2. **Der Rückblick meldet die Woche, die zu Ende ist**, nicht die laufende. §3.4 nennt
   beides („dieselben Buckets wie das Fenster" und trotzdem 4.210 Wörter am Montagmorgen);
   nur die abgeschlossene Woche ergibt eine Zahl. Der Klick öffnet weiterhin „Woche",
   also die laufende — dort steht dann wenig, und das ist der ehrlichere Widerspruch als
   eine Statistik, die eine andere Woche zeigt als das Fenster.
3. **Kein `matchedGeometryEffect`** für das Fehlersymbol. Die Kapsel ist eine Form, die
   ihren Inhalt tauscht; eine geteilte Geometrie über einen `switch` hinweg braucht zwei
   Views, die es gleichzeitig gibt. Der Zustandswechsel läuft über `Motion.state` auf
   `kindID`.
4. **Das ✓ springt einmal, nicht zweimal.** `.repeat(2)` ist auf dem aktuellen SDK
   abgekündigt; ein Meilenstein unterscheidet sich durch seinen Satz und 1,5 s statt
   700 ms.
5. **Kein Übergang beim Settings-Seitenwechsel** (§3.7, letzter Punkt): `SettingsView`
   gehört in dieser Runde Spec 36.
6. **Die Notch-Variante bekommt die Momente als Text**, nicht als Bewegung: dort steht
   „✓ 42 Wörter" rechts. Die Streifen wachsen nicht aus der Notch — die Notch-Ansicht ist
   bewusst reine Anzeige (kein Maus-Tracking, kein ×), und das bleibt so.
7. **`DictationController.swift` und `project.yml` sind angefasst**, obwohl beide nicht
   auf der Dateiliste standen. Anders ging es nicht: die Reihenfolge Einfügen → Speichern
   → Moment existiert nur im Controller (drei Zeilen: ein `pasted`-Flag, der Aufruf von
   `successMoment`, und `hide(.shrink)` beim Abbruch), und die puren neuen Dateien
   brauchen `path:`-Einträge, um im Test-Bundle zu liegen. `Theme.swift` liegt jetzt
   ebenfalls dort, weil das HUD seine Dauern aus `Motion` nimmt.
8. **Meilensteine aus Meetings warten auf das nächste Diktat.** Der Moment ist das HUD
   (§3.5), und Meetings haben keines. Wer zwischen zwei Diktaten sein 100. Meeting
   aufzeichnet, sieht die Schwelle beim nächsten Diktat — oder gar nicht, wenn der
   Rechner dazwischen neu startet und das stille Nachholen sie markiert.

**Tests:** 163 in elf Klassen grün (`ThemeTests` 7, +3 neu; `DictationOverlayTests` 15,
+4 neu; `DictationPipelineTests` 24, +5 neu; `MilestonesTests` 12, `WeeklyRecapTests` 9,
`UsageRecordsTests` 17 — alle drei neu; dazu `LocalizationTests`, `UsageMetricsTests`,
`UsageDetailMetricsTests`, `MenuUsageLineTests`, `DefaultsKeyTests` unverändert grün).
Keine Modell-Suite lief außer der Latenzprobe.

**Latenz:** `LatencyProbeTests` nach dem Bau: 5 s → 134 ms, 15 s → 170 ms, 30 s → 307 ms,
60 s → 449 ms. **Abnahme 1 ist damit nicht verifiziert**, und zwar aus zwei Gründen, die
beide beim Namen genannt gehören: es gibt keinen Vorher-Wert aus derselben Sitzung, und
die Probe misst ohnehin die Inferenz, nicht die Strecke Loslassen → Einfügen. Was sich
belegen lässt, steht im Code und in den Tests: auf der gemessenen Strecke läuft nichts
Neues, der Erfolgsmoment liegt hinter `Paster.insert` *und* hinter dem Speichern, und
`UsageMoments.dictationSaved` rechnet im Speicher statt in SQLite.

**Nicht verifiziert:** alles, was man sehen muss — Abnahme 3 (GIFs je HUD-Platz,
Aufwachsen, Atem, Fall auf die Linie, Abbruch-Schrumpfen, dasselbe mit Reduce Motion),
5 (Statistik in Bewegung), 6 (Meilenstein einmal, dann nicht mehr), 7 (die Mitteilung am
Montag) und 8 (der Onboarding-Satz). Ein Debug-Build startet nicht neben der
installierten App, also bleibt das ein Handtest an der nächsten Installation.
