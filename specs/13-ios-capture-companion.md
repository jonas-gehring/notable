# Spec 13: iOS-Capture-Companion — unterwegs aufnehmen, der Mac transkribiert

Status: **Entwurf, Entscheidung offen** (2026-07-24). Kippt die Festlegung
„iOS: not pursued" in `CLAUDE.md` → *Settled decisions* — die bleibt gültig, bis der
ausdrücklich anders entschieden wird.
Scope: persönliches Tool, ein Nutzer (siehe `CLAUDE.md` → „Scope").
Alternative mit größerem Zuschnitt: [`14-ios-vollport.md`](14-ios-vollport.md).

## 1. Ziel in einem Satz

Das iPhone/iPad wird ein **dummer, robuster Rekorder**: Mikro aufnehmen, als
spool-kompatibles Paket nach iCloud legen. Der Mac holt es sich und schickt es durch
**exakt dieselbe** Verarbeitungskette wie eine abgestürzte lokale Aufnahme —
`MeetingController.produceNote(...)`. Kein ASR-Modell auf dem Telefon, kein
zweiter Datenbestand, keine Sync-Semantik.

### 1.1 Was das kann — und was nicht

| | |
|---|---|
| ✅ Präsenzgespräch, Interview, Sprachnotiz unterwegs aufnehmen (auch bei ausgeschaltetem Display) | |
| ✅ Kalender-Event des Termins wird schon auf dem iPhone zugeordnet | |
| ✅ Transkript + Zusammenfassung landen im gewohnten Notizen-Ordner auf dem Mac | |
| ⛔ **Telefonate mitschneiden** — es gibt auf iOS keine API für Anruf-Audio. CallKit liefert Metadaten, nie den Stream. Apples eigene Anrufaufzeichnung ist systemexklusiv. | |
| ⛔ **Teams/Zoom-Gegenseite auf demselben iPhone** — kein CoreAudio-Prozess-Tap auf iOS. ReplayKit-Broadcast (App-Audio + Mic) wäre der einzige theoretische Weg: 50 MB Speicherlimit, zeichnet den Bildschirm mit, wird von VoIP-Apps unterdrückt. Verworfen. | |
| ⛔ Automatische Meeting-Erkennung — keine Prozessliste, kein „wer hält das Mikro" auf iOS. Start ist manuell. | |
| ⛔ Diktat mit Einfügen ins fokussierte Textfeld — kein globaler Hotkey, kein `CGEvent`. Siehe Spec 14 §5. | |

Der ehrliche Satz für die Erwartungshaltung: **Was auf dem Tisch liegt und ins Mikro
spricht, wird erfasst. Was durchs Telefonnetz oder durch eine andere App läuft, nicht.**

## 2. Warum dieser Schnitt (und nicht der Vollport)

`MeetingController.recoverOrphanedRecordings()` (`MeetingController.swift:256-314`)
existiert bereits und tut genau das Richtige: es nimmt ein Spool-Verzeichnis
(`mic.pcm`, `system.pcm`, `meta.json`), erzeugt Notiz + Zusammenfassung, archiviert
oder markiert `spool-failed`. Ein iPhone, das ein solches Verzeichnis nach iCloud
schreibt, ist aus Sicht des Macs **eine abgestürzte Aufnahme, die auf einem anderen
Gerät passiert ist**. Damit entfallen:

- ASR/VAD/Diarisierung auf dem Telefon (Modell-Download, ANE-Tuning, RAM-Limits),
- ein zweiter Notiz-/Datenbestand mit Konfliktauflösung,
- der Anthropic-Key auf dem Telefon,
- jede Änderung an `RecordingStore`.

Preis: die Transkription ist erst da, wenn der Mac gelaufen ist. Für „unterwegs mal
was mitschneiden" ist das der richtige Handel.

## 3. Transportformat — spool-kompatibel, mit drei Zusätzen

Ein Paket ist ein Verzeichnis `<UUID>/`, wie `SpoolStore.Session` es erwartet:

```
<UUID>/
  meta.json     SpoolStore.Meta + neue optionale Felder (siehe unten)
  mic.pcm16     NEU: Int16-LE, 16 kHz, mono   (statt Float32 mic.pcm)
  done.json     NEU: Fertig-Sentinel mit Byte-Anzahl + SHA-256 (Kurzhash)
```

`system.pcm` fehlt **absichtlich** — auf iOS gibt es keine zweite Spur.
`recoverOrphanedRecordings` verträgt das schon (`SpoolStore.readSamples` liefert
`[]` für eine fehlende Datei; die Längenprüfung nutzt `max(mic.count, system.count)`).

### 3.1 Warum Int16 statt des lokalen Float32-Spools

| Format | Rate | 1 h | 3 h |
|---|---|---|---|
| Float32 16 kHz mono (heutiger Spool) | 64 KB/s | 230 MB | 690 MB |
| **Int16 16 kHz mono** | 32 KB/s | **115 MB** | 345 MB |
| ALAC in `.caf` (optional, später) | ~16 KB/s | ~58 MB | ~173 MB |

Über iCloud und potenziell über Mobilfunk sind 230 MB/h nicht vertretbar. Int16 ist
die native Bittiefe des Mikrofons — die Konvertierung kostet keine ASR-Qualität und
sind 15 Zeilen. ALAC halbiert nochmal, braucht aber `AVAudioConverter` auf beiden
Seiten; als spätere Option offenhalten, nicht in v1.

### 3.2 `SpoolStore.Meta` — additive Erweiterung

```swift
struct Meta: Codable, Sendable {
    var startedAt: Date
    var eventTitle: String?
    var eventID: String?
    // NEU — alle optional, damit alte Spools unverändert decodieren und
    // ein älterer Mac-Build unbekannte Schlüssel schlicht ignoriert.
    var source: String?              // "ios" | nil (= lokal, wie bisher)
    var deviceName: String?          // "iPhone von Alex" — für die Notiz-Herkunft
    var micIsMultiSpeaker: Bool?     // true ⇒ Mic-Spur diarisieren statt "Ich"
    var micSampleFormat: String?     // "int16" | nil (= float32)
}
```

### 3.3 `micIsMultiSpeaker` — der einzige echte Pipeline-Eingriff

Heute ist die Mic-Spur per Definition **ich**: `MeetingPipeline.process`
(`MeetingPipeline.swift:110-115`) VAD-segmentiert sie und beschriftet alles mit
„Ich"; diarisiert wird nur die System-Spur. Bei einer iPhone-Tischaufnahme sprechen
aber **alle** ins Mikro — ohne Änderung landet das komplette Gespräch als ein
einziger Sprecher „Ich".

Änderung in `MeetingPipeline.process`, minimal-invasiv:

```swift
static func process(
    micSamples: [Float],
    systemSamples: [Float],
    transcriber: any TranscriptionEngine,
    micIsMultiSpeaker: Bool = false     // NEU, Default = heutiges Verhalten
) async throws -> [MeetingTranscriptSegment]
```

Bei `true` durchläuft die Mic-Spur **denselben** Pfad wie heute die System-Spur:
VAD → kompaktieren → diarisieren → `mapToOriginal`. Das ist genau die in
`CLAUDE.md` festgehaltene Regel („**Never diarize the raw system track**") — sie gilt
hier ebenso, und der Grund entfällt nicht: auch eine Tischaufnahme hat Pausen. Der
bestehende Code-Pfad wird also **wiederverwendet**, nicht dupliziert:
Track-Beschriftung „Sprecher n" statt „Ich".

Guard in `MeetingConversationTests` erweitern: eine Ein-Spur-Aufnahme mit zwei
Stimmen muss zwei Sprecher liefern.

### 3.4 Fertig-Sentinel und die Teil-Upload-Falle

Der File Provider lädt Dateien einzeln hoch. Der Mac darf ein Paket **nie**
verarbeiten, solange `mic.pcm16` noch wächst oder nur teilweise heruntergeladen ist.
Regeln:

1. Das iPhone schreibt die Session zuerst in sein **lokales** `Application Support`,
   nicht in den iCloud-Container.
2. Nach `stop()`: `done.json` schreiben (`{"micBytes": …, "sha256Prefix": …, "durationSeconds": …}`),
   dann das **gesamte Verzeichnis** per `FileManager.setUbiquitous(_:itemAt:destinationURL:)`
   in den Container verschieben.
3. Der Mac akzeptiert ein Paket nur, wenn **alle** gelten:
   - `meta.json` **und** `done.json` sind vorhanden und decodierbar,
   - `mic.pcm16` hat exakt `micBytes` Bytes,
   - `URLResourceValues.ubiquitousItemDownloadingStatus == .current` für alle drei,
   - `ubiquitousItemIsUploading == false`.
   Sonst: überspringen und beim nächsten Query-Update erneut prüfen. Kein Timeout,
   kein Löschen — ein unfertiges Paket ist kein Fehler, nur ein „noch nicht".

## 4. iOS-Seite

### 4.1 Wiederverwendet, unverändert

`AudioRecorder.swift` und `PCMDownsampler.swift` importieren ausschließlich
`AVFoundation` + `Foundation` — sie kompilieren auf iOS ohne Änderung. Damit ist
der gesamte Aufnahmepfad inklusive 16-kHz-Downsampling und RMS-Pegel geschenkt.

`CalendarMonitor.swift` (EventKit, 106 LOC) ebenso — nur der
Berechtigungsaufruf unterscheidet sich (`requestFullAccessToEvents`, ab iOS 17
zwingend getrennt von Write-only).

### 4.2 Neu

| Datei | Zweck | ~LOC |
|---|---|---|
| `Sources/NotableiOS/NotableiOSApp.swift` | App-Entry, `AVAudioSession`-Konfiguration | 80 |
| `Sources/NotableiOS/CaptureController.swift` | Start/Stop, Spool schreiben, Unterbrechungen | 220 |
| `Sources/NotableiOS/ICloudOutbox.swift` | Container-URL, `setUbiquitous`-Übergabe, Upload-Status | 160 |
| `Sources/NotableiOS/CaptureView.swift` | Aufnahmeknopf, Pegel, Laufzeit, Event-Auswahl | 200 |
| `Sources/NotableiOS/OutboxView.swift` | Liste: wartend / lädt hoch / übergeben | 120 |
| `Sources/NotableiOS/SettingsView.swift` | iCloud-Status, Gerätename, Mehrsprecher-Default | 100 |
| `Sources/Notable/Support/PCMInt16.swift` | `[Float] ↔ Int16`-Konvertierung, **geteilt** | 40 |

### 4.3 AVAudioSession — die drei Dinge, die schiefgehen

Das ist der Teil, der auf iOS wirklich Arbeit macht, nicht die UI:

1. **Kategorie**: `.record` mit `.allowBluetooth` reicht; `.playAndRecord` nur, wenn
   später Wiedergabe dazukommt. `setActive(true)` vor `engine.start()`.
2. **Hintergrund**: `UIBackgroundModes: [audio]` im Info.plist. Ohne das wird die
   Aufnahme beim Sperren des Displays nach Sekunden suspendiert. Mit dem Modus läuft
   sie weiter — Apple akzeptiert das für Rekorder (bei einer Store-Einreichung
   begründungspflichtig; für ein persönliches Tool via TestFlight/Ad-hoc irrelevant).
3. **Unterbrechungen**: `AVAudioSession.interruptionNotification` **muss** behandelt
   werden. Ein eingehender Anruf, Siri oder eine andere App mit
   `.record`-Session unterbricht die Aufnahme. Verhalten:
   - `.began` → Engine anhalten, Spool-Datei offen lassen, UI zeigt „unterbrochen".
   - `.ended` mit `.shouldResume` → `AudioRecorder.resume()` (existiert bereits,
     `AudioRecorder.swift:55`) und **Stille in Höhe der Lücke einfügen**, damit die
     Zeitachse nicht verrutscht — sonst laufen Diarisierung und
     `MeetingPipeline.mapToOriginal` auf falsche Offsets.
   - `.ended` ohne `.shouldResume` → sauber beenden, Paket trotzdem übergeben.
   `AVAudioEngineConfigurationChange` (AirPods rein/raus) ist in `AudioRecorder`
   bereits verdrahtet (`:45`) — auf iOS feuert das deutlich häufiger als auf dem Mac.

### 4.4 Was die iOS-App *nicht* bekommt

Keine Transkript-Ansicht, keine Suche, keine Zusammenfassung, kein Anthropic-Key,
kein `RecordingStore`. Wer das Ergebnis lesen will, öffnet die Markdown-Datei in der
Dateien-App oder auf dem Mac. Genau diese Enthaltsamkeit macht die Spec klein.

## 5. Mac-Seite

### 5.1 `SpoolStore` — Inbox als zweite Basis

`SpoolStore.orphans(base:)` nimmt bereits eine Basis-URL entgegen
(`SpoolStore.swift:48`). Neu dazu:

```swift
extension SpoolStore {
    /// Übergabepunkt aus iCloud: <ubiquity>/Documents/Inbox
    /// nil, wenn der Container (noch) nicht bereitsteht — dann still nichts tun.
    static var inboxURL: URL? { … }

    /// Wie `orphans(base:)`, filtert aber auf vollständig übertragene Pakete
    /// (§3.4) und liefert Meta mit den neuen Feldern.
    static func readyInboxPackages() -> [(session: Session, meta: Meta)]
}
```

### 5.2 `MeetingController` — ein Zwilling zur Crash-Recovery

```swift
/// Holt fertige iPhone-Pakete herein — dieselbe Kette wie
/// `recoverOrphanedRecordings`, nur eine andere Quelle.
func ingestInboxRecordings()
```

Unterschiede zur Crash-Recovery, alles andere identisch:

- Samples kommen aus `mic.pcm16` (Int16 → `[Float]`), `systemSamples: []`.
- `micIsMultiSpeaker` aus der Meta an `produceNote` durchreichen.
- Erfolg → Paket aus dem iCloud-Container **löschen** (nicht nur archivieren; sonst
  wächst der Container unbegrenzt). Das Roh-Audio wandert vorher lokal nach
  `spool-archive`, damit die Entscheidung „Meeting-Audio behalten" aus
  `Specs/`-Wave-2 unberührt bleibt.
- Fehler → in `spool-failed` lokal, Paket im Container mit `error.json` markieren,
  damit es nicht in einer Schleife erneut gezogen wird.
- Statusmeldung/Notification: „Aufnahme von *iPhone von Alex* verarbeitet".

**Serialisierung**: `ingestInboxRecordings` und `recoverOrphanedRecordings` teilen
sich `state == .idle` als Wächter und rufen sich am Ende gegenseitig auf — es darf
nie zwei parallele ASR-Läufe geben.

### 5.3 Auslöser

`NSMetadataQuery` mit Scope `NSMetadataQueryUbiquitousDocumentsScope` und einem
Prädikat auf `done.json`. **Nicht** FSEvents/`DispatchSource` — die feuern für
File-Provider-Ordner unzuverlässig. Zusätzlich ein Aufruf beim App-Start
(neben `container.meeting.recoverOrphanedRecordings()` in `NotableApp.swift:58`) und
ein 5-Minuten-Sicherheitsnetz-Timer.

## 6. Projektstruktur und Signierung

`project.yml` bekommt ein zweites Target `NotableiOS` (`platform: iOS`,
`deploymentTarget: 17.0`, wegen FluidAudio-Kompatibilität und EventKit-API — die
iOS-App braucht FluidAudio zwar nicht, das Target teilt aber `project.yml`).
Geteilte Dateien werden per Pfad in **beide** Targets aufgenommen — dasselbe
Muster, das `NotableTests` schon nutzt (`project.yml:34-71`). Ein eigenes SPM-Paket
ist bei sieben geteilten Dateien Overkill; das kommt erst mit Spec 14.

Nicht verhandelbar drumherum:

- **Bezahlte Apple-Developer-Program-Mitgliedschaft (99 $/Jahr).** Ohne sie läuft die
  App auf dem Gerät 7 Tage und muss dann neu signiert werden — für ein Werkzeug, das
  man unterwegs braucht, untauglich.
  **Diese Frage ist nicht neu und nicht spezifisch für iOS:**
  [`release-and-signing.md`](release-and-signing.md) §6 führt sie bereits als offene
  Entscheidung, und `project.yml` zielt schon heute auf `Developer ID Application` für
  Notarisierung und DMG. **Wenn die Mitgliedschaft für die Notarisierung ohnehin kommt,
  sind die iOS-Zusatzkosten null.** Diese Spec erzeugt den Bedarf nicht, sie erbt ihn.
- **iCloud-Container** (`iCloud.de.dashboard.notable`) muss im Developer-Portal
  angelegt und in *beiden* Targets als Entitlement geführt werden. Zu klären:
  trägt eine `Developer ID`-Signatur (kein Sandbox, kein App Store) das
  Entitlement `com.apple.developer.icloud-container-identifiers` überhaupt? Für
  Developer-ID-verteilte Mac-Apps ist iCloud-Zugriff **nicht** vorgesehen — Apple
  koppelt iCloud an App-Store-/Sandbox-Verteilung. **Das ist das echte Risiko dieser
  Spec, nicht die 99 $** (§7, und §10 Punkt 2 nennt den Ausweichweg).
- Mikrofon- und Kalender-Nutzungsbeschreibungen im iOS-Info.plist.

## 7. Risiken

| Risiko | Auswirkung | Gegenmaßnahme |
|---|---|---|
| iCloud liefert das Paket verzögert (Stunden, bei Stromsparmodus/Mobilfunk) | Notiz erscheint spät | Erwartung setzen: Outbox-Liste zeigt Upload-Status ehrlich; kein „fertig", solange nicht übergeben |
| **Developer-ID-Verteilung schließt iCloud-Entitlements aus** (§6) | Transport über App-Container unmöglich | **Vorab verifizieren** (§9, Schritt 0); Ausweichweg: normaler iCloud-Drive-Ordner ohne Entitlement (§10.2) — die Spec überlebt, das Sentinel wird schwächer |
| Unterbrechung durch echten Anruf mitten in der Aufnahme | Zeitachse verrutscht, Diarisierung zerfällt | §4.3, Stille-Auffüllung + Test mit erzwungener Unterbrechung |
| Tischaufnahme akustisch zu schlecht für Diarisierung | „Sprecher 1" für alles | Akzeptieren; Transkript bleibt brauchbar. Kein Hardware-Workaround im Scope |
| Paket verwaist im Container (Mac wochenlang aus) | Container läuft voll | Outbox zeigt Alter; iOS warnt ab 7 Tagen unbestätigt |

## 8. Abnahmekriterien

1. Aufnahme über 30 min bei gesperrtem Display läuft durch; Paket ist vollständig.
2. Ein eingehender Anruf während der Aufnahme unterbricht sauber, die Aufnahme
   setzt danach fort, und die Sprecher-Zeitstempel im Ergebnis stimmen (±1 s) mit
   der Uhr überein.
3. Ein Paket, das während des Uploads inspiziert wird, wird vom Mac **nicht**
   verarbeitet — und nach Abschluss des Uploads sehr wohl.
4. Ein Zwei-Personen-Tischgespräch ergibt zwei Sprecher, nicht einen („Ich").
5. Der Mac erzeugt daraus eine Notiz im gewohnten Ordner, mit Kalendertitel, wenn
   das iPhone einen Termin zugeordnet hat.
6. Zwei Pakete gleichzeitig im Container werden nacheinander verarbeitet, nie parallel.
7. Bestehende lokale Crash-Recovery ist unverändert (Regressionstest).
8. Flugmodus während der Aufnahme: Paket bleibt lokal, geht hoch, sobald Netz da ist.

## 9. Aufwand

| Schritt | Inhalt | Aufwand |
|---|---|---|
| **0** | **Vorabprüfung**: Trägt der Developer-ID-signierte Mac-Build ein iCloud-Container-Entitlement? Wenn nein → Ausweichweg §10.2 statt Abbruch. Entscheidet die Architektur, nicht das Ob | 0,5 Tag |
| 1 | `project.yml`: iOS-Target, geteilte Dateien, Entitlements | 0,5 Tag |
| 2 | `CaptureController` + `AVAudioSession`/Unterbrechungen | 1,5 Tage |
| 3 | `ICloudOutbox` + Sentinel-Protokoll (§3.4) | 1 Tag |
| 4 | iOS-UI (3 Screens) | 1 Tag |
| 5 | Mac: `readyInboxPackages` + `ingestInboxRecordings` + `NSMetadataQuery` | 1 Tag |
| 6 | `micIsMultiSpeaker` in `MeetingPipeline` + Tests | 0,5 Tag |
| 7 | Feldtest, Unterbrechungsfälle, Abnahme §8 | 1 Tag |
| | **Summe** | **~7 Tage** |

Das ist mehr als die 4–6 Tage aus der ersten Einschätzung — der Aufschlag ist das
Sentinel-Protokoll und die Unterbrechungsbehandlung, die beide nicht optional sind.
Maßstab: S ≈ 1 Tag, M ≈ 2–4 Tage, L ≈ 1 Woche, wie in [`README.md`](README.md).

## 10. Offene Entscheidungen

1. **Bezahlte Developer-Program-Mitgliedschaft** — dieselbe offene Frage wie in
   [`release-and-signing.md`](release-and-signing.md) §419; wird sie dort mit „ja"
   beantwortet, ist hier nichts mehr zu entscheiden.
2. **Transportweg**, falls Schritt 0 negativ ausfällt (§9): Alternative wäre ein
   Transport über einen normalen iCloud-Drive-Ordner statt eines App-Containers —
   ohne Entitlement, dafür ohne Upload-Statusabfrage (`ubiquitousItemIsUploading`),
   also mit schwächerem Sentinel. Machbar, aber schlechter.
3. **Roh-Audio der iPhone-Aufnahmen behalten** (wie bei lokalen Meetings) oder nach
   erfolgreicher Verarbeitung löschen?
4. **Mehrsprecher als Default?** Vorschlag: ja für iPhone-Pakete
   (`micIsMultiSpeaker = true`), pro Aufnahme umschaltbar.
