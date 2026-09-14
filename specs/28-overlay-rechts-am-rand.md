# Spec 28 — Diktat-Anzeige rechts am Bildschirmrand

> **Aufwand: S (½ Tag).** Ein vierter Platz für die Diktat-Anzeige: rechts am Rand
> statt unten mittig. Alles, was das Panel gefährlich macht (nie key, Maus ignorieren,
> auf dem Bildschirm unter dem Zeiger), bleibt unangetastet — es kommt nur ein
> Rechteck dazu, und das ist pur und testbar.

## 1. Ausgangslage (Fakten aus dem Code)

- **Drei Stile, ein Picker.** `OverlayStyle` kennt `.bottom` (Standard), `.notch` und
  `.off` (`NotchGeometry.swift:5-29`); die Einstellung liegt unter dem Key
  `overlayStyle`, ein unbekannter Wert fällt auf `.bottom` zurück (`:16-18`). Der
  Picker „Anzeige während der Aufnahme" iteriert `allCases`
  (`DictationSettingsView.swift:70-74`) — ein neuer Fall erscheint dort von selbst.
- **Die Geometrie ist pur.** `NotchGeometry.placement(for:size:style:)` bekommt einen
  gemessenen `Screen` (Frame, sichtbarer Frame, Safe-Area, Notch-Streifen) und gibt ein
  `Placement` zurück (`:53-81`). `clamped` hält jedes Rechteck im sichtbaren Frame und
  schrumpft, bevor es verschiebt (`:115-121`). Neun Tests in `NotchGeometryTests`
  decken Notch, Pill, schmale Displays, ausgeblendete Menüleiste und den versetzten
  zweiten Bildschirm ab.
- **Das Panel ist 380 × 68 pt und durchsichtig; der Pill schwimmt darin.**
  `DictationOverlayView` zentriert die Kapsel mit `.frame(maxWidth: .infinity,
  maxHeight: .infinity)` (`DictationOverlay.swift:228-233`); die Kapsel selbst hüllt
  ihren Inhalt ein — nur die Wellenform beim Aufnehmen, Text in jedem anderen Zustand
  (`:259-300`). Ein Schatten mit Radius 10 liegt um die Kapsel (`:254`).
- **Positioniert wird auf dem Bildschirm unter dem Mauszeiger**, nicht auf
  `NSScreen.main` (`:203-212`), bei jedem `show()` neu (`:71-72`). Für `.bottom` und
  `.notch`-ohne-Notch übernimmt `position` nur den Ursprung und behält die Panelgröße
  (`:197-200`).
- **Was das Panel nie darf, ist getestet.** `DictationOverlayTests` baut das Panel und
  prüft `canBecomeKey == false`, dass `NSApp.keyWindow` unberührt bleibt, und den Rest
  der Konfiguration (`.borderless`, `.nonactivatingPanel`, `ignoresMouseEvents`).
- **Vorbild.** Wispr Flows „Flow Bar" ist eine kleine Blase, die an den unteren, linken
  oder rechten Bildschirmrand schnappt und dort bleibt; die Position ist eine
  Einstellung des Nutzers. Notables Panel ignoriert die Maus absichtlich, also gibt es
  kein Ziehen — die Wahl ist ein Picker, kein Griff.

## 2. Ziel

Ein neuer Eintrag im Picker, **„Rechts am Rand"**: die Kapsel sitzt an der rechten
Kante des sichtbaren Bildschirmbereichs, vertikal in der Mitte, und wächst nach links,
wenn ein Zustand mehr zu sagen hat als die Wellenform. Verhalten, Zustände, Ton und
Erreichbarkeit bleiben exakt die des unteren Stils. Standard bleibt `.bottom`; wer nichts
ändert, merkt nichts.

## 3. Konzept

### 3.1 Der Fall

`OverlayStyle.right` mit `rawValue = "right"`, Label „Rechts am Rand" (englisch
„Right edge"). Reihenfolge in `allCases` und damit im Picker: unten, rechts, Notch, aus
— die beiden Rand-Optionen nebeneinander, „Aus" bleibt zuletzt.

### 3.2 Die Geometrie (pur)

Neuer Placement-Fall `.rightEdge(CGRect)` und eine Funktion `rightEdgeFrame`:

```
maxX  = visibleFrame.maxX − rightInset        // rightInset = 4 pt, s. u.
midY  = visibleFrame.midY
width = min(size.width, visibleFrame.width)
→ clamped(…, to: visibleFrame)
```

- **`visibleFrame`, nicht `frame`**: ein Dock am rechten Rand verschiebt den sichtbaren
  Bereich, und die Kapsel soll neben dem Dock stehen, nicht dahinter.
- **Vertikal mittig** als Vorgabe (siehe §7 für die Alternative). Oben rechts liegen
  die Mitteilungen von macOS, unten rechts ist auf einem breiten Display der Punkt, den
  der Blick am seltensten streift.
- **Der Abstand zur Kante teilt sich in zwei Zahlen**, weil das Panel durchsichtig ist und
  der Schatten *innerhalb* des Panels gezeichnet wird: die Geometrie rückt das Panel
  4 pt von der Kante ab (`rightInset`), die View gibt der Kapsel 12 pt Trailing-Padding
  (`edgePadding`) — sichtbarer Abstand 16 pt, und der Schatten mit Radius 10 wird
  nicht an der Panelkante abgeschnitten. Beides sind Startwerte; ein Test pinnt die
  Summe, nicht die Aufteilung.
- `.off` behält wie bisher den Bottom-Frame — Fehler werden auch bei „Aus" gezeigt,
  und die stehen dann dort, wo sie immer standen.

### 3.3 Die View

`DictationOverlayView` bekommt eine `alignment` (aus dem `Model`, vom Controller gesetzt
wie heute `notchCutout`): `.center` für unten, `.trailing` für rechts. Nur die
`.frame(…, alignment:)`-Zeile und das Trailing-Padding ändern sich; Zustände, Farben,
Wellenform, „vorläufig"-Badge und `accessibilityLabel` sind dieselben.

**Warum Trailing-Ausrichtung mehr ist als Kosmetik:** die Kapsel wechselt zwischen den
Zuständen ihre Breite (Wellenform ≈ 90 pt, „Transkribiere…" ≈ 160 pt, ein Fehler bis
zur Panelbreite). Unten mittig springt dabei jede Kante symmetrisch; an einer
Bildschirmkante muss die *Kante* stehen bleiben und die Kapsel nach innen wachsen —
sonst rutscht sie beim Zustandswechsel vom Rand weg und wieder hin.

`content(for:)` liefert für `.right` dieselbe `DictationOverlayView` wie für `.bottom`;
die `NotchOverlayView` bleibt allein dem Notch-Stil.

### 3.4 Der Controller

`position(_:style:)` behandelt `.rightEdge` wie `.bottomCenter`: Ursprung übernehmen,
Panelgröße behalten, `notchCutout = nil`, zusätzlich `model.alignment` setzen. Da
`ensurePanel` bei einem Stilwechsel nur die gehostete View tauscht (`:138-144`), greift
die Einstellung beim nächsten Diktat ohne Neustart — wie heute.

## 4. Integration

| Stelle | Änderung |
|---|---|
| `NotchGeometry.swift` | `OverlayStyle.right`, Label; `Placement.rightEdge`; `rightEdgeFrame`; `rightInset` |
| `DictationOverlay.swift` | `Model.alignment`; `DictationOverlayView` liest sie; `content(for:)` und `position` kennen `.right`; `edgePadding` |
| `Resources/en.lproj/Localizable.strings` | `"Rechts am Rand" = "Right edge";` — `LocalizationTests` erzwingt den Eintrag, weil das Label über `case .right: String(localized:)` läuft |
| `DictationSettingsView.swift` | nichts — der Picker iteriert `allCases` |
| `README.md` / `README.de.md` | die Aufzählung der Plätze um „rechts am Rand" ergänzen |

Kein Schema, kein neuer Defaults-Key, keine Migration: `overlayStyle` bekommt nur einen
weiteren gültigen Wert, und ein älterer Build, der ihn nicht kennt, fällt auf `.bottom`.

## 5. Risiken

- **Zweiter Bildschirm rechts vom ersten.** Die Kante ist die des Bildschirms unter dem
  Zeiger, nicht die des Gesamtdesktops — `currentScreen()` macht das schon richtig, und
  der bestehende Test „versetzter Bildschirm" wird für den neuen Stil wiederholt.
- **Dock rechts.** Abgedeckt durch `visibleFrame`; ein Test simuliert ein 70 pt breites
  Dock rechts und prüft, dass das Panel links davon endet.
- **Fensterinhalt am rechten Rand.** Viele Apps haben dort Seitenleisten und
  Scrollbalken; das Panel ignoriert die Maus, also kann es nichts blockieren — es kann
  aber etwas *verdecken*, für die Dauer eines Diktats. Das ist der Preis jeder Rand-
  Position und der Grund, warum es eine Wahl bleibt und kein neuer Standard wird.
- **Nichts am Panel selbst.** `DictationOverlayTests` läuft über den neuen Stil mit —
  wenn die Testschleife heute nur `.bottom` und `.notch` baut, wird `.right` ergänzt.

## 6. Abnahme

1. Picker zeigt vier Einträge; „Rechts am Rand" gewählt ⇒ nächstes Diktat zeigt die
   Kapsel rechts, vertikal mittig, 16 pt von der Kante, ohne Neustart.
2. `NotchGeometryTests`: auf dem 14"-Profil `maxX == visibleFrame.maxX − 4` und
   `midY == visibleFrame.midY`; mit Dock rechts endet das Panel am sichtbaren Frame;
   auf dem versetzten externen Display bleibt das Panel auf diesem Display; ein Panel
   breiter als der Bildschirm wird geschrumpft, nicht verschoben.
3. Zustandswechsel Aufnahme → Transkribiere → Fehler: die rechte Kante der Kapsel
   bewegt sich nicht, die Kapsel wächst nach links.
4. `DictationOverlayTests`: das Panel im Stil `.right` kann nicht key werden und nimmt
   `NSApp.keyWindow` nichts weg.
5. `LocalizationTests` grün; das englische Fenster zeigt „Right edge".
6. `.off` unverändert: kein Panel, Fehler erscheinen unten wie bisher.

## 7. Offene Entscheidungen

- **Vertikaler Anker.** Mitte (Vorschlag) oder unteres Drittel? Die Mitte ist auf jedem
  Display gleich gut zu finden; das untere Drittel ist näher an dem, was „unten" heute
  bietet, und verdeckt seltener Inhalt. Ein Startwert, den ein Tag Benutzung
  entscheidet — die Zahl steht an einer Stelle.
- **Links als Spiegelbild.** `.left` wäre dieselbe Geometrie mit `minX` statt `maxX`
  und `.leading` statt `.trailing`, etwa zwanzig Zeilen und zwei Tests. Nicht gefordert;
  günstig, solange die Spec frisch ist. Entscheidung des Owners.

## 8. Stand des Baus (2026-09-14)

Gebaut mit den Vorschlägen aus §7: **vertikal mittig, kein Links-Spiegel.** Beides ist
eine Zahl bzw. ein Fall und bleibt billig nachzuziehen.

Eine Abweichung vom Konzept: das Trailing-Padding liegt nicht als Konstante in
`DictationOverlayView` (die ist `private` und aus Tests nicht erreichbar), sondern als
`NotchGeometry.rightEdgePadding` neben `rightInset` — beide Hälften der 16 pt an einer
Stelle, und der Test pinnt ihre Summe.

Abnahme: `NotchGeometryTests` +6 (Kante und Mitte, 16 pt, Dock rechts, versetzter
Bildschirm, zu schmales Display, Picker-Reihenfolge), `DictationOverlayTests` iteriert
die Nie-key-Invariante über alle sichtbaren Stile, `LocalizationTests` grün. Punkt 1
und 3 (sichtbar im Diktat, Kante steht beim Zustandswechsel) sind Handtests an der
installierten App und noch offen.
