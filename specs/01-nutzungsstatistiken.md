# Spec 01 — Nutzungsstatistiken

> **Aufwand: M.** Diktat- und Meeting-Zahlen pro Zeitraum, mit der gesparten Zeit als
> Leitmetrik. Rein additiv — kein Eingriff in den heißen Diktatpfad.

## 1. Ziel

Ein eigenes **Statistik-Fenster** (und eine kompakte Zusammenfassung im Settings-Tab
„Diktat"/neuer Tab „Statistik"), das dem Nutzer zeigt, was Notable für ihn tut:

- **Gesparte Zeit** insgesamt und pro Zeitraum — der emotionale Kern der ganzen Ansicht.
- **Diktierte Wörter** insgesamt und pro Zeitraum.
- **Anzahl Diktate** und **durchschnittliche Diktatlänge**.
- **Anzahl Meetings** pro **Tag / Woche / Monat / Jahr** und **Meeting-Gesamtzeit**.
- **Charts**: Balken pro Tag/Woche/Monat; Trend über die Zeit.
- Sekundär: Latenz-Verlauf (ersetzt die heutige Einzelwert-Anzeige in Settings → Diktat).

Heute existiert nur `dictation.lastLatencyMillis` / `lastAudioSeconds` als flüchtiger
Einzelwert (`SettingsView.swift:197`). Alle Rohdaten für echte Statistiken liegen aber
**bereits in SQLite** (`recordings.started_at/ended_at/kind`, `segments.text`) — es
fehlt nur Aggregation, eine Wortzahl-Spalte und die UI.

## 2. Kennzahlen — Definitionen

Präzise Definitionen, damit die Zahlen stabil und erklärbar sind.

### 2.1 Diktierte Wörter
`word_count` eines Diktats = Anzahl whitespace-getrennter Tokens des **polierten**
Transkripts (das, was tatsächlich eingefügt wurde). Pure Funktion:

```swift
static func wordCount(_ text: String) -> Int {
    text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
}
```

Gilt für Diktate. Für Meetings zählen wir Wörter **nicht** als „diktiert" (der Nutzer
hat sie nicht getippt-ersetzt) — Meetings bekommen eigene Kennzahlen (§2.3).

### 2.2 Gesparte Zeit
Annahme: Sprechen ist schneller als Tippen. Zeitersparnis pro Diktat:

```
zeit_ersparnis_sekunden = max(0, (word_count / TIPP_WPM) * 60  −  diktat_dauer_sekunden)
```

- `TIPP_WPM` = **konfigurierbare Tippgeschwindigkeit**, Default **40 WPM** (übliche
  Default-Annahme; einstellbar 20–120 in Settings, damit die Zahl ehrlich bleibt).
- `diktat_dauer_sekunden` = `ended_at − started_at` (bereits gespeichert).
- Untergrenze 0: ein Ein-Wort-Diktat „spart" nie negative Zeit.

Die Formel und `TIPP_WPM` gehören in eine **pure, getestete** `UsageMetrics`-Funktion,
damit die Zahl reproduzierbar ist. Optional (transparenz): zweite Lesart „gesparte Zeit
ggü. Tippen deiner Diktate" ist die Default; wir zeigen einen Tooltip mit der Annahme.

### 2.3 Meeting-Kennzahlen
- **Anzahl Meetings** je Zeitraum = `COUNT(*)` über `recordings WHERE kind='meeting'`
  gruppiert nach Kalendertag/Woche/Monat/Jahr (lokale Zeitzone!).
- **Meeting-Gesamtzeit** = `SUM(ended_at − started_at)` derselben Menge.
- **Durchschnittliche Meeting-Länge**, **längstes Meeting**.
- Sekundär: **Meetings mit Zusammenfassung** (`summary IS NOT NULL`) als Qualitätsquote.

### 2.4 Aggregations-Buckets
Alle „pro Zeitraum"-Werte werden nach **lokalen Kalendergrenzen** gebildet
(`Calendar.current`), nicht nach rollierenden 24h/7d-Fenstern — „diese Woche" muss
Montag–Sonntag heißen, nicht „letzte 168 Stunden". Das ist der häufigste Fehler bei
solchen Statistiken; hier explizit festgelegt.

## 3. Datenmodell & Migration

### 3.1 Neue Spalte
`recordings.word_count INTEGER` (nullable). Migriert idempotent im bestehenden Muster
in `RecordingStore.ensureOpen()`:

```swift
migrateAddColumn(handle, table: "recordings", column: "word_count", type: "INTEGER")
```

- **Vorwärts:** `saveDictation` und `insertMeeting` setzen `word_count` beim Insert
  (Diktat: Wortzahl des Textes; Meeting: Summe der Segment-Wortzahlen — für §2.3-Erweiterungen,
  optional).
- **Backfill (einmalig):** beim ersten Öffnen nach dem Update ein
  `UPDATE recordings SET word_count = … WHERE word_count IS NULL`. Da SQLite kein
  Wort-Split kann, läuft der Backfill in Swift: Segmente laden, zählen, schreiben, in
  einer Transaktion. Für ein Personal-Tool (hunderte bis wenige tausend Zeilen) ist das
  Millisekunden. Guard über eine `UserDefaults`-Flag `didBackfillWordCount`, damit es
  genau einmal läuft.

`saveDictation` erweitern (heute `RecordingStore.swift:78`):

```swift
func saveDictation(text: String, startedAt: Date, duration: TimeInterval) throws {
    let recording = Recording(
        id: UUID().uuidString, kind: .dictation,
        startedAt: startedAt, endedAt: startedAt.addingTimeInterval(duration),
        wordCount: UsageMetrics.wordCount(text)      // NEU
    )
    …
}
```

(`Recording` bekommt ein `var wordCount: Int? = nil`; `insert`/`readRecording`/
`recordingColumns` entsprechend um die Spalte erweitern — dem bestehenden Muster folgen.)

### 3.2 Keine separate Stats-Tabelle
Bewusst **nicht** vorberechnen/materialisieren. Aggregation läuft on-demand per SQL über
`recordings`. Begründung: Datenmenge ist klein, die Wahrheit bleibt an einer Stelle,
kein Invalidierungs-Problem. Wenn es je zu langsam wird (unrealistisch), ist ein Index
auf `started_at` der erste Schritt (`CREATE INDEX idx_recordings_started ON recordings(started_at)`).

## 4. Aggregations-API (`RecordingStore`)

Neue Actor-Methoden, alle als reine Reads. Buckets werden **in Swift** aus rohen Zeilen
gebildet (Zeitzonen-korrekt über `Calendar`), nicht per SQLite-`strftime` (das kennt die
lokale Zeitzone nicht zuverlässig).

```swift
struct UsageTotals: Sendable {
    var dictationCount: Int
    var dictationWords: Int
    var dictationSeconds: TimeInterval
    var savedSeconds: TimeInterval        // §2.2, mit übergebener TIPP_WPM berechnet
    var meetingCount: Int
    var meetingSeconds: TimeInterval
}

struct UsageBucket: Sendable, Identifiable {
    let id: Date            // Bucket-Startdatum (lokaler Tages-/Wochen-/Monatsbeginn)
    let dictationWords: Int
    let dictationCount: Int
    let savedSeconds: TimeInterval
    let meetingCount: Int
    let meetingSeconds: TimeInterval
}

enum Granularity { case day, week, month, year }

/// Alle Recordings in [from, to) roh laden (nur die Felder, die Stats braucht).
func usageRows(from: Date, to: Date) throws -> [(kind: Kind, startedAt: Date,
                                                 endedAt: Date?, wordCount: Int?)]
```

Die Aggregation zu `UsageTotals` / `[UsageBucket]` und die Zeitersparnis-Formel liegen in
einem **puren** `enum UsageMetrics` (nicht im Actor), das `usageRows` als Eingabe nimmt.
So sind Buckets, Ersparnis, WPM-Formel unit-testbar ohne DB.

```swift
enum UsageMetrics {
    static func wordCount(_ text: String) -> Int
    static func savedSeconds(words: Int, dictationSeconds: TimeInterval, typingWPM: Double) -> TimeInterval
    static func totals(_ rows: [UsageRow], typingWPM: Double) -> UsageTotals
    static func buckets(_ rows: [UsageRow], by: Granularity,
                        calendar: Calendar, typingWPM: Double) -> [UsageBucket]
}
```

## 5. UI

### 5.1 Eigenes Statistik-Fenster
Neues `Window(id: "stats")` in `NotableApp.swift` (Muster wie „notes"/"recent"), geöffnet
über einen Menüpunkt **„Statistik…"** in `MenuContentView` (mit
`NSApp.activate(ignoringOtherApps: true)` wie die anderen Fenster). Default-Größe ~640×560.

Aufbau (SwiftUI + **Swift Charts**, ab macOS 14 verfügbar — kein Zusatzpaket):

1. **Kopf-Kacheln (KPI-Row)** — vier große Zahlen:
   - „⏱ Gesparte Zeit" (gesamt, z. B. „14 h 22 min") — die Hero-Zahl.
   - „✍️ Wörter diktiert" (gesamt).
   - „🎙 Diktate" (gesamt) + Ø Länge.
   - „👥 Meetings" (gesamt) + Meeting-Gesamtzeit.
2. **Zeitraum-Umschalter** (Segmented Control): Tag / Woche / Monat / Jahr. Steuert die
   Bucket-Granularität der Charts **und** eine „in diesem Zeitraum"-KPI-Zeile
   (z. B. „Diese Woche: 3.410 Wörter, 5 Meetings, 48 min gespart").
3. **Chart 1 — Wörter/Zeitersparnis über die Zeit**: Balkendiagramm, x = Bucket,
   y = diktierte Wörter (oder umschaltbar gesparte Minuten). Das Kernbild der Ansicht.
4. **Chart 2 — Meetings über die Zeit**: Balken (Anzahl) + Linie (Meeting-Stunden) im
   selben Zeitraster.
5. **Latenz-Panel** (ersetzt den Einzelwert in Settings → Diktat): letzte N Latenzen als
   kleine Sparkline + Median/Min/Max. Datenquelle siehe §6.

Für die dataviz-Details (Farben, Achsen, Light/Dark) beim Bau die **`dataviz`-Skill**
laden — die Charts sollen als ein System lesbar sein.

### 5.2 Kompakt-Ansicht in Settings
Der bestehende Settings-Tab „Diktat" verliert den nackten Latenz-Einzelwert
(`SettingsView.swift:197–204`) und bekommt stattdessen eine kleine
**„Diese Woche"-Zusammenfassung** + Button **„Alle Statistiken öffnen…"** (öffnet das
Fenster aus §5.1). Optional stattdessen ein eigener Settings-Tab „Statistik".

### 5.3 Tippgeschwindigkeit-Einstellung
Settings → Diktat (oder Statistik-Fenster-Fuß): Slider/Stepper **„Deine Tippgeschwindigkeit"**
(20–120 WPM, Default 40), `@AppStorage("typingWPM")`. Tooltip erklärt, dass die
Zeitersparnis auf diesem Wert basiert — Ehrlichkeit vor Angeberei.

## 6. Latenz-Verlauf (Sekundärdaten)

Latenz gehört nicht in `recordings` (sie ist keine Eigenschaft der Aufnahme, sondern der
Verarbeitung). Zwei Optionen:

- **A (empfohlen, minimal):** Ringpuffer der letzten N (z. B. 50) Latenzen in
  `UserDefaults` als `[Int]` (JSON), geschrieben in
  `DictationController.finishRecording` direkt nach `lastLatencyMillis = …`
  (`DictationController.swift:343`). Kein Schema, kein DB-Write im heißen Pfad.
- **B:** eigene Tabelle `latency_samples(ts, millis, audio_seconds)`. Mehr Overhead,
  nur nehmen, wenn wir Latenz je gegen Audio-Länge korrelieren wollen.

Default: **A**. Median/Min/Max sind pure Rechnung darüber.

## 7. Edge Cases & Entscheidungen

- **Laufende/abgebrochene Aufnahmen:** `ended_at IS NULL` (Crash mitten im Meeting) →
  aus allen Dauer-Summen ausschließen, in Zählungen optional mitnehmen. Nie negative
  Dauer.
- **Zeitzonen/Sommerzeit:** Buckets über `Calendar.current`; ein Tag mit DST-Umstellung
  hat 23/25 h — `Calendar` behandelt das korrekt, `strftime` nicht. Test dafür schreiben.
- **Leere Historie:** freundlicher Empty-State („Noch keine Diktate — halt die
  Diktattaste und leg los.") statt leerer Charts.
- **Sehr kurze Diktate:** zählen mit; Zeitersparnis kann 0 sein (Untergrenze greift).
- **Wortzahl-Sprachen:** whitespace-Split ist für DE/EN korrekt; CJK würde falsch zählen —
  für dieses Personal-Tool irrelevant, dokumentieren statt lösen.
- **„Streaks":** Tagesserien. Optional als späterer Zusatz (längste Serie
  aufeinanderfolgender Tage mit ≥1 Diktat) — pure Funktion über die Tages-Buckets, klein
  nachrüstbar. In v2 nice-to-have, nicht Pflicht.

## 8. Tests

Alle gegen `UsageMetrics` (pur, kein DB):

- `wordCount`: leerer String → 0; „hallo welt" → 2; Mehrfach-Whitespace/Newlines.
- `savedSeconds`: negatives Ergebnis → 0; Standardfall bei 40 WPM; WPM-Variation.
- `buckets`: korrekte Tages-/Wochen-/Monatsgrenzen; DST-Tag; Wochengrenze Montag;
  Jahreswechsel.
- `totals`: Meetings mit `ended_at=nil` fließen nicht in Sekundensummen; Trennung
  Diktat/Meeting sauber.
- `RecordingStore`-Integrationstest (temp-DB): Insert dreier Diktate + zweier Meetings →
  `usageRows` liefert genau die Zeilen im Fenster; Backfill setzt `word_count`.

## 9. Umsetzungsschritte

1. `UsageMetrics` (pur) + Tests — zuerst, definiert die Wahrheit.
2. Schema: `word_count`-Spalte + Migration + Backfill-Flag; `saveDictation`/`insertMeeting`
   schreiben die Wortzahl.
3. `RecordingStore.usageRows(from:to:)` + kleiner Integrationstest.
4. Latenz-Ringpuffer (Variante A) in `finishRecording`.
5. Statistik-Fenster (`Window id:"stats"`, Menüpunkt, KPI-Kacheln, Zeitraum-Umschalter).
6. Charts mit `dataviz`-Skill (Wörter/Ersparnis, Meetings).
7. Settings: Latenz-Einzelwert → „Diese Woche"-Kompaktbox + „Statistiken öffnen"; WPM-Setting.
8. Empty-States, VoiceOver-Labels, Light/Dark.

## 10. Nicht-Ziele

- Kein Cloud-Dashboard, kein Sync, kein Teilen der Statistik.
- Keine Gamification über Streaks hinaus.
- Keine „words per app"-Auswertung, solange Spec 03 (`source_app`) nicht umgesetzt ist —
  danach fällt sie fast geschenkt ab (dann optional ergänzen).
