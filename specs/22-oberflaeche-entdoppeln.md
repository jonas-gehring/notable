# Spec 22 — Oberfläche entdoppeln

> **Aufwand: M.** Kein neues Verhalten, keine gestrichene Funktion. Dieselbe App mit
> weniger Code, weniger Schaltern und genau einer Implementierung je Begriff.
> Die einzige Spec hier, deren Erfolg man daran misst, dass *nichts* passiert.

## 1. Ausgangslage (Fakten aus dem Code)

Gezählt am 2026-09-07, 90 Swift-Dateien, 19 664 Zeilen:

| | |
|---|---|
| `@AppStorage`-Schlüssel (eindeutig) | 24 |
| `Toggle` in `Settings/` | 28 |
| Fenster in `NotableApp.swift` | 12 |
| Einstellungsseiten | 7 |
| `SettingsView.swift` | 898 Zeilen, 7 Top-Level-Views + `RememberedConsentSection` |

Drei Dinge sind zweimal gebaut, und die Kopien sind bereits auseinandergelaufen:

- **„Letzte Diktate"** existiert als eigenes Fenster (`RecentDictationsView`, mit
  Zeitraum-Filter, Korrigieren-Sheet, Kopieren) **und** als Abschnitt in den
  Einstellungen (`SettingsView.swift:533-565`, `recentDictations(limit: 8)`, ohne all
  das). Zwei Listen desselben Inhalts, die verschieden viel können.
- **Der Tippgeschwindigkeits-Stepper** steht in `SettingsView.swift:77` und in
  `StatsView.swift:117` — zweimal `@AppStorage("typingWPM")`, zweimal derselbe Regler.
- **Die Known-App-Tabelle** steht in `MeetingDetector.swift:110` (Bundle-ID → Name →
  Klasse) und ist in `SettingsView.swift:708-716` als `displayName(for:)` von Hand
  nachgebaut. Ein neuer Meeting-Client muss heute an zwei Stellen eingetragen werden,
  und die zweite fällt niemandem auf, bis ein Eintrag als roher Bundle-Identifier in
  den Einstellungen steht.

Dazu die Beobachtung aus dem Code-Review vom 3. September, die dort bewusst liegen
blieb (`docs/code-review-2026-09-03.md` §7.16): `relaunch()` stand dreimal — inzwischen
`AppRelauncher`, aber das war eine von vier gleichartigen Stellen.

## 2. Ziel

Nach dieser Spec verhält sich Notable **identisch**. Was sich ändert:

- Ein Begriff hat eine Implementierung. Wer „letzte Diktate" ändert, ändert sie überall.
- Eine neue Meeting-App wird an einer Stelle eingetragen.
- `SettingsView.swift` ist keine Datei mehr, in der man sucht.

Explizit **kein** Ziel: Funktionen streichen. Die Frage „braucht das jemand" ist eine
andere Diskussion und gehört nicht in einen Umbau — ein Umbau, der nebenbei Features
entfernt, ist nicht mehr überprüfbar.

## 3. Konzept

### 3.1 Eine Datei je Einstellungsseite

`Settings/SettingsView.swift` wird zum Rahmen (Tab-Auswahl, `Pane`-Enum) und gibt die
sieben Seiten ab: `GeneralSettings.swift`, `DictationSettings.swift`,
`MeetingsSettings.swift`, `MenuBarSettings.swift`, `SummarizationSettings.swift`,
`StorageSettingsView.swift` (existiert schon), `PermissionsSettings.swift`.

Das verschachtelte `enum Section` (`:10`) heißt `Pane` — es beschattet heute
`SwiftUI.Section`, was in einer Settings-Datei die denkbar unglücklichste Kollision ist,
und sein Kommentar spricht von sechs Seiten bei sieben Fällen.

### 3.2 Ein Ort je Begriff

| Heute zweimal | Künftig |
|---|---|
| „Letzte Diktate" (Fenster + Settings-Abschnitt) | `RecentDictationsList` als View, von beiden benutzt — der Settings-Abschnitt zeigt sie gekürzt, kann aber dasselbe |
| Tippgeschwindigkeits-Stepper | `TypingSpeedStepper`, ein `@AppStorage` darin |
| Known-App-Tabelle | `MeetingApps.displayName(for:)` neben der Tabelle in `MeetingDetector` |

### 3.3 `DefaultsKey` — die Schlüssel an einen Ort

24 `@AppStorage`-Schlüssel stehen heute als String-Literale in Views *und* Controllern:
`"summarizationProvider"` an vier Stellen, `"typingWPM"`, `"showNextMeeting"`,
`"showUsageInMenu"`, `"meetingNotesFloating"`, `"didCompleteOnboarding"` je zweimal.
`HotkeySpec`, `RetentionPolicy` und `MediaInterrupter` machen es bereits richtig und
halten ihre Schlüssel als statische Konstanten neben der Logik, die sie liest.

Ein `enum DefaultsKey` mit statischen Konstanten, **und der Default steht daneben**.
Der Grund ist nicht Ästhetik: ein Schlüssel an zwei Stellen ist ein Default an zwei
Stellen, und die driften. Ein Tippfehler in einem Literal ist heute kein Compilerfehler,
sondern ein Schalter, der stillschweigend seinen Wert vergisst.

### 3.4 Eine Regel für neue Schalter

28 Toggles für ein Werkzeug mit einem Nutzer. Die Regel für alles Neue, festgehalten
damit sie zitierbar ist:

> Ein Schalter kommt nur dazu, wenn beide Stellungen für **denselben** Nutzer
> vertretbar sind. Wo eine Stellung offensichtlich richtig ist, ist sie der Default und
> es gibt keinen Schalter.

Diese Spec wendet die Regel **nicht** rückwirkend an — das wäre Featurestreichung
(§2). Sie schreibt sie auf, damit die Zahl nicht weiter wächst.

## 4. Integration

Reihenfolge, weil ein Umbau ohne Verhaltensänderung nur in kleinen Schritten prüfbar ist:

1. `MeetingApps.displayName` — kleinste Änderung, sofort testbar gegen beide alten
   Tabellen.
2. `TypingSpeedStepper` + `DefaultsKey` für die doppelt belegten Schlüssel.
3. `RecentDictationsList` aus dem Fenster herausziehen, im Settings-Abschnitt einsetzen.
4. `SettingsView` aufteilen — reines Verschieben, ein Commit je Seite.

Jeder Schritt einzeln committet, `xcodebuild … test` dazwischen.

## 5. Risiken

- **Ein reiner Umbau hat kein Testkriterium außer „vorher genauso".** Die 524 Tests
  decken Kernlogik ab, nicht SwiftUI-Layout: dass ein Abschnitt nach dem Verschieben
  noch an der richtigen Stelle steht, sagt nur das Fenster. Also klein schneiden und
  jede Seite einmal öffnen.
- **`@AppStorage` an einen neuen Ort zu ziehen ist gefährlicher als es aussieht.** Ein
  geänderter *Schlüssel* (nicht nur seine Deklarationsstelle) verliert eine Einstellung
  des Nutzers still. `DefaultsKey` darf ausschließlich bestehende Strings umziehen, nie
  aufräumen — `"dictationEnhancementEnabled"` bleibt hässlich und bleibt.
- **Die Versuchung, unterwegs etwas zu verbessern.** Genau das macht den Umbau
  unprüfbar. Verbesserungen gehen in einen eigenen Commit *nach* dem Verschieben.

## 6. Abnahme

- `SettingsView.swift` unter 150 Zeilen, keine Datei in `Settings/` über 400.
- `grep -c '@AppStorage("' Sources/Notable` findet jeden Schlüssel genau einmal
  außerhalb von `DefaultsKey`.
- Kein Bundle-Identifier eines Meeting-Clients steht an zwei Stellen.
- Die 524 Tests laufen unverändert durch; kein Test musste angepasst werden. Muss doch
  einer angepasst werden, war es kein reiner Umbau — dann gehört die Änderung in einen
  eigenen Commit mit eigener Begründung.
- Jede der sieben Seiten wurde einmal geöffnet und zeigt dieselben Abschnitte wie vorher.
