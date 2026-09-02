# Spec 14: Notable für iOS/iPadOS — eigenständiger Client mit Sync

Status: **Entwurf, Entscheidung offen** (2026-07-24). Kippt zwei Festlegungen aus
`CLAUDE.md` → *Settled decisions*: „iOS: not pursued" **und** „locally built, ad-hoc
signed". Beide bleiben gültig, bis ausdrücklich anders entschieden wird.
Scope: persönliches Tool, ein Nutzer.
Schlanke Alternative: [`13-ios-capture-companion.md`](13-ios-capture-companion.md).

## 1. Abgrenzung zu Spec 13

Spec 13 macht das iPhone zum Rekorder — der Mac bleibt die einzige Instanz, die
transkribiert und speichert. Diese Spec macht das iPhone zu einem **vollwertigen
zweiten Client**: eigene Transkription auf dem Gerät, eigener Datenbestand,
bidirektionale Synchronisierung. Das ist ungefähr die dreifache Arbeit und bringt
genau drei Dinge dazu:

1. Transkript ist **sofort** da, ohne dass der Mac laufen muss.
2. **Alle** Notizen sind auf dem Telefon lesbar und durchsuchbar, auch die vom Mac.
3. Bearbeitungen (Titel, eigene Notizen, Ordner) gehen in beide Richtungen.

**Empfehlung: erst Spec 13 bauen und einen Monat benutzen.** Wenn sich dann
herausstellt, dass Punkt 1–3 wirklich fehlen, ist Spec 13 kein Wegwurf — sie ist die
Aufnahme- und Projektschicht, auf der diese Spec aufsetzt. Umgekehrt gilt das nicht.

## 2. Was auch im Vollport unmöglich bleibt

Unverändert und nicht verhandelbar — siehe [`13`](13-ios-capture-companion.md) §1.1:
**keine Telefonat-Aufzeichnung, kein System-Audio, keine automatische
Meeting-Erkennung, kein Diktat ins fokussierte Fremd-Textfeld.** Der Vollport
ändert daran nichts; er ändert nur, was mit dem Mikrofonsignal *danach* passiert.

Wer diese Spec baut, weil er Teams-Calls auf dem iPhone mitschneiden will, baut sie
aus dem falschen Grund.

## 3. Code-Aufteilung

Von 10.610 LOC sind **4.735 plattformneutral** (kein AppKit, kein SwiftUI, keine
macOS-only-API). Das ist der Kern, der ein Paket wird.

### 3.1 Neues SPM-Paket `NotableCore`

| Bereich | Dateien | LOC |
|---|---|---|
| Storage | `RecordingStore`, `MarkdownProjector` | 787 |
| Summarization | `SummarizationProvider`, `AnthropicAPIProvider`, `SummarizationService`, `SummaryParser` | 453 |
| Dictation-Kern | `TextPolisher`, `TranscriptionEngine`, `ParakeetTranscriber`, `ParakeetModelCache`, `EnglishStreamingTranscriber`, `WhisperTranscriber`, `IncrementalDictation`, `WordDiff`, `AppCategory`, `PTTStateMachine` | 1.407 |
| Meeting-Kern | `MeetingPipeline`, `SpoolStore`, `SpeakerNameResolver`, `ChatPrompt`, `MeetingConsent`, `MeetingController`¹ | 1.306 |
| Audio | `AudioRecorder`, `PCMDownsampler` | 294 |
| Übriges | `CalendarMonitor`, `KeychainStore`, `UsageMetrics`, `NoteManager` | 568 |

¹ `MeetingController` ist heute AppKit-frei, aber `@MainActor`-UI-nah und hängt an
`NotesFolderManager` (AppKit) und `UserDefaults`-Schlüsseln. Er wird geteilt in einen
puren `MeetingSession`-Kern (Zustandsmaschine, `produceNote`) und je einen dünnen
plattformspezifischen Controller. Das ist der einzige größere Umbau am Bestand.

**Bleibt macOS-only** (ca. 5.900 LOC): gesamte AppKit-UI, `HotkeyMonitor`,
`Paster`, `DictationOverlay`, `SystemAudioTap`, `AudioProcessMonitor`,
`MeetingDetector`, `ConsentPresenter`/`ConsentCoordinator`, `ClaudeCodeCLIProvider`,
`UpdateChecker`/`UpdateInstaller`, `PermissionsManager`.

### 3.2 Was der Umbau am Mac-Build verlangt

- `NotesFolderManager` (`Storage/NotesFolder.swift`) verliert die Annahme aus
  Zeile 6 — „Not sandboxed, so a plain path in UserDefaults is sufficient". Es
  entsteht ein Protokoll `NotesFolderLocating`; macOS behält den freien Pfad, iOS
  bekommt den App-/iCloud-Container. `NSOpenPanel` wandert in die macOS-Schicht.
- `NotableTests` zieht heute 28 Quelldateien per Pfad ins Test-Target
  (`project.yml:34-71`). Mit `NotableCore` als Paket wird daraus ein
  `@testable import NotableCore` — eine echte Vereinfachung, kein Nebenschaden.
  Die Tests, die Modelle laden, bleiben unverändert.

## 4. ASR auf dem Gerät

### 4.1 Modellgrößen — gemessen, nicht geschätzt

Aus dem lokalen FluidAudio-Cache (`~/Library/Application Support/FluidAudio/Models`):

| Modell | Größe | auf iOS nötig |
|---|---|---|
| `parakeet-tdt-0.6b-v3` (mehrsprachig, Default) | **461 MB** | ja |
| `speaker-diarization` | 13 MB | ja |
| `silero-vad` | 1 MB | ja |
| `parakeet-unified-en-0.6b` (Englisch-Streaming) | 581 MB | nein — Diktat entfällt (§5) |

**~475 MB** Erstdownload. Das ist beherrschbar, aber kein Beiwerk: es braucht eine
Modellverwaltung in den iOS-Einstellungen (Download nur über WLAN, Fortschritt,
Löschen, Speicherbedarf sichtbar). Auf dem Mac ist der Download heute unsichtbar —
auf einem Telefon darf er das nicht sein.

### 4.2 Speicher

`CLAUDE.md` misst auf dem Mac ~120 MB RSS mit warm geladenen Modellen — CoreML
mappt die Gewichte, sie liegen nicht als Kopie im RSS. Das ist die gute Nachricht
für iOS: das Jetsam-Limit (grob 1,4 GB im Vordergrund auf älteren Geräten) ist
weit weg. **Ungemessen** bleibt: ANE-Durchsatz und thermisches Verhalten auf einem
iPhone gegenüber M2 Pro. Realistische Erwartung 2–4× langsamer, plus Drosselung bei
langen Meetings.

**Konsequenz für den Bauplan:** Ein 60-Minuten-Meeting auf dem iPhone verarbeiten
ist ein Messpunkt *vor* dem UI-Bau, kein Detail danach. Falls die Verarbeitung
länger dauert als die Aufnahme, ist der Vollport für lange Meetings wertlos und
Spec 13 die einzig sinnvolle Variante — für kurze Aufnahmen bliebe er trotzdem gut.

### 4.3 Hintergrundverarbeitung

Nach dem Stopp läuft ASR + Diarisierung + Zusammenfassung minutenlang. Auf iOS
heißt das `BGProcessingTaskRequest` (`requiresExternalPower` je nach Messung) plus
`beginBackgroundTask` für die ersten ~30 s Übergang. Ein Abbruch durch das System
darf nichts verlieren — der Spool bleibt bis zum Erfolg liegen, exakt wie die
Crash-Recovery auf dem Mac.

## 5. Diktat auf iOS — bewusst gestrichen

Der Vollständigkeit halber die Analyse, damit sie nicht erneut geführt wird:

| Weg | Bewertung |
|---|---|
| Custom Keyboard Extension mit Full Access | Speicherbudget einer Keyboard-Extension liegt bei einigen zehn MB, bevor das System sie abschießt. Ein CoreML-Parakeet darin ist nicht vertretbar riskant. Verworfen. |
| Keyboard-Extension als reiner Auslöser, Host-App transkribiert | Extensions können die Host-App nicht zuverlässig starten; der übliche Responder-Chain-Trick ist fragil und store-untauglich. Verworfen. |
| Share-Sheet / App Intent („Diktat einfügen") | Funktioniert, aber der Nutzer muss die App wechseln — das ist langsamer als iOS' eingebaute Diktierfunktion. |
| In-App-Diktat (Text landet in der Zwischenablage) | Funktioniert, sinnvoll für Notizen *in* Notable. |

**Entscheidung dieser Spec:** iOS bekommt **In-App-Diktat** für die eigenen Notizfelder
und sonst nichts. Der Push-to-Talk-Mechanismus aus `CLAUDE.md` — Hotkey halten,
sprechen, Text erscheint im fokussierten Feld — ist auf iOS nicht nachbaubar, und
eine schlechtere Kopie der System-Diktierfunktion ist es nicht wert.
`HotkeyMonitor`, `PTTStateMachine`, `Paster`, `DictationOverlay` bleiben macOS.

## 6. Synchronisierung

### 6.1 Die Falle zuerst

Die SQLite-Datei (WAL) darf **nicht** in iCloud Drive liegen. Der File Provider
synchronisiert `-wal`/`-shm` nicht transaktionskonsistent mit der Hauptdatei; das
Ergebnis ist irgendwann eine korrupte Datenbank. Das ist kein Restrisiko, das ist
der erwartete Ausgang.

### 6.2 Gewählter Weg: CloudKit mit `CKSyncEngine`

`CKSyncEngine` gibt es ab macOS 14 / iOS 17 — deckungsgleich mit den
Deployment-Targets. Architektur:

- **SQLite bleibt pro Gerät die lokale Wahrheit**, wie in
  `README.md` §Querschnitts-Prinzipien Nr. 3. Nichts an `RecordingStore` ändert sich
  strukturell.
- **CKRecord ist das Übertragungsformat**, nicht der Speicher. Ein Record-Typ je
  Tabelle: `Recording`, `Segment`, `ChatMessage`.
- **Markdown wird pro Gerät projiziert.** Die `.md`-Dateien werden **nicht**
  synchronisiert — das würde nur zwei Wahrheiten erzeugen. Auf dem Mac liegen sie
  wie heute im Notizen-Ordner, auf iOS im App-Container (über die Dateien-App
  sichtbar, wenn `LSSupportsOpeningDocumentsInPlace` gesetzt ist).
- **Audio wird nicht synchronisiert.** 115–230 MB pro Stunde gehören nicht in
  CloudKit; das Roh-Audio bleibt auf dem aufnehmenden Gerät, der Record trägt
  `audioOnDevice: String`.

### 6.3 Konflikte

Ein Nutzer, zwei Geräte, selten gleichzeitig — Last-Writer-Wins pro Feld über
`CKRecord.recordChangeTag` reicht für alles außer einem Feld: `user_notes`. Wenn
beide Geräte offline am selben Notiztext geschrieben haben, wird nicht verworfen,
sondern **angehängt**, mit Trennzeile und Gerätename. Verlust von getipptem Text ist
der einzige Fehler, den man in einem persönlichen Werkzeug nicht verzeiht.

Neue Spalten in `recordings` (idempotentes `migrateAddColumn`-Muster,
`RecordingStore.swift:609-614`):

- `recordings.ck_change_tag TEXT`
- `recordings.audio_on_device TEXT`
- `recordings.sync_state INTEGER NOT NULL DEFAULT 0` (0 = lokal, 1 = gesendet, 2 = bestätigt)

### 6.4 Verworfene Alternative

**Nur der Markdown-Ordner in iCloud Drive**, ohne CloudKit: deutlich billiger
(2–3 Tage), aber Suche, Statistiken und Chat auf dem iPhone hätten keinen
Datenbestand — sie müssten Markdown parsen, also die Projektion zur Wahrheit
erklären. Das widerspricht dem Prinzip „SQLite ist die Wahrheit". Für **Spec 13** ist
dieser Weg richtig, für einen Vollport nicht.

## 7. Zusammenfassung auf dem iPhone

`ClaudeCodeCLIProvider` gibt es auf iOS nicht — kein CLI. Damit bleibt
`AnthropicAPIProvider`, und der braucht den Key im Keychain des Telefons.
Zwei Wege:

- **A (Vorschlag):** Key mit `kSecAttrSynchronizable = true` speichern, dann liegt er
  über den iCloud-Schlüsselbund auf beiden Geräten. `KeychainStore` (50 LOC) bekommt
  ein Flag.
- **B:** iOS fasst **gar nicht** zusammen. Es transkribiert, markiert den Record als
  „Zusammenfassung ausstehend", und der Mac erledigt es beim nächsten Sync — dort stehen
  auch die CLI-Anbieter zur Verfügung, die es auf dem Telefon nicht gibt.

**B ist die bessere Voreinstellung** (kein Schlüssel auf dem Telefon, keine zweite
Anbieter-Konfiguration), A als Schalter für „ich brauche die Zusammenfassung sofort".

## 8. Projektstruktur und Signierung

```
Packages/NotableCore/           neues SPM-Paket (§3.1)
Sources/Notable/                macOS-App, hängt von NotableCore ab
Sources/NotableiOS/             iOS/iPadOS-App, hängt von NotableCore ab
Tests/NotableCoreTests/         die heutigen 35 Tests, per @testable import
```

`project.yml` bekommt Targets `Notable` (macOS), `NotableiOS` (iOS 17+) und ein
lokales Paket. Die 28 Einzelpfad-Einträge im Test-Target entfallen.

Signierung — Ausgangslage wie in Spec 13 §6, hier aber **härter**: CloudKit braucht
`com.apple.developer.icloud-services` auf beiden Seiten. Der Ausweichweg aus
Spec 13 §10.2 (normaler iCloud-Drive-Ordner ohne Entitlement) existiert hier
**nicht** — CloudKit ohne Entitlement gibt es nicht.

**Damit ist Schritt 0 aus Spec 13 §9 für diese Spec ein echtes K.-o.-Kriterium.**
Fällt er negativ aus, weil Developer-ID-Verteilung iCloud-Entitlements nicht trägt,
bleibt nur der Wechsel des Mac-Builds auf Sandbox + App-Store-/TestFlight-Verteilung —
und das kollidiert frontal mit `HotkeyMonitor`s CGEventTaps und `SystemAudioTap`.
Dann ist diese Spec tot und Spec 13 die einzige iOS-Option.

TCC-Grants auf dem Mac hängen am Bundle-Pfad, nicht an der Signatur — der Pfad
`/Applications` bleibt also gültig; **Neusignierung kann aber Keychain-ACLs
invalidieren**: den Anthropic-Key vorher notieren.

## 9. Phasen und Aufwand

| Phase | Inhalt | Aufwand |
|---|---|---|
| **0** | **Machbarkeitsmessung**: Parakeet v3 auf dem Zielgerät, 60-min-Audio, Zeit + Thermik. Entscheidet über die ganze Spec (§4.2). Dafür reicht ein Wegwerf-Target. | 1 Tag |
| 1 | `NotableCore` herauslösen, `MeetingController` aufteilen, `NotesFolderLocating`, Tests migrieren — **Mac-Build muss danach identisch funktionieren** | 3 Tage |
| 2 | iOS-App-Gerüst: Aufnahme, `AVAudioSession`, Unterbrechungen, Hintergrund (identisch zu Spec 13 §4.3) | 2 Tage |
| 3 | On-Device-Verarbeitung: Modellverwaltung, `BGProcessingTask`, Fortschritt, Abbruchfestigkeit | 2 Tage |
| 4 | iOS-UI: Aufnahme, Notizliste, Notizdetail, Suche, Einstellungen | 4 Tage |
| 5 | CloudKit: Schema, `CKSyncEngine`, Migrationen, Konfliktbehandlung, Erstabgleich eines vollen Bestands | 5 Tage |
| 6 | Signierung, Container, TestFlight, Geräteeinrichtung | 1 Tag |
| 7 | Feldtest beidseitig, Offline-/Konfliktfälle, Abnahme §11 | 2 Tage |
| | **Summe** | **~20 Tage ≈ 4 Wochen** |

Das liegt über der ersten Grobschätzung (2–3 Wochen). Der Unterschied ist Phase 5:
CloudKit-Sync ist realistisch eine ganze Arbeitswoche, wenn er den ersten
Offline-Konflikt überleben soll.

## 10. Risiken

| Risiko | Auswirkung | Gegenmaßnahme |
|---|---|---|
| ASR auf dem iPhone langsamer als Echtzeit für lange Meetings | Kernnutzen weg | **Phase 0 vor allem anderen**; Rückfall auf Spec 13 |
| `NotableCore`-Extraktion bricht den laufenden Mac-Build | tägliches Werkzeug kaputt | Phase 1 auf eigenem Branch, 35 Tests + manueller Diktat-/Meeting-Durchlauf als Gate |
| CloudKit-Erstabgleich mit vollem Bestand | Rate-Limits, halb migrierte Daten | Erstabgleich in Stapeln, `sync_state` als Fortschrittsmarke, wiederaufsetzbar |
| Neusignierung invalidiert Keychain-Zugriff | Anthropic-Key weg | vor Phase 6 sichern |
| **iCloud-/CloudKit-Entitlement mit Developer-ID-Verteilung nicht erhältlich** (§8) | Spec tot — kein Ausweichweg wie in Spec 13 | Schritt 0 aus Spec 13 §9 **vor** Phase 0 klären |
| Zwei Geräte bearbeiten dieselbe Notiz offline | Textverlust | §6.3 Anhängen statt Überschreiben |
| Aufwand entgleist, Spec 13 wäre gereicht | Wochen für wenig Nutzen | Reihenfolge: erst Spec 13 leben, dann entscheiden |

## 11. Abnahmekriterien

1. Mac-Build nach Phase 1 verhaltensgleich: Diktatlatenz im Rahmen der in
   `CLAUDE.md` dokumentierten Werte, Meeting-Durchlauf unverändert, 35 Tests grün.
2. iPhone nimmt 60 min auf und liefert Transkript **ohne** Mac.
3. Eine auf dem iPhone erzeugte Notiz erscheint auf dem Mac im Notizen-Ordner —
   und umgekehrt eine Mac-Notiz in der iOS-Liste.
4. Titeländerung auf dem iPhone erreicht den Mac; die Markdown-Datei wird dort
   korrekt umbenannt (Kollisionsschutz `MarkdownProjector.uniqueFileName` greift).
5. Beide Geräte offline am selben `user_notes` → nach Sync ist **kein Text weg**.
6. Erstabgleich des kompletten Bestands läuft durch und ist nach Abbruch
   wiederaufsetzbar.
7. Suche auf dem iPhone findet ein Wort aus einem Mac-Meeting.
8. Modelldownload lässt sich abbrechen und fortsetzen; kein Download über Mobilfunk.

## 12. Offene Entscheidungen

1. **Überhaupt?** — Empfehlung ist Spec 13 zuerst, Entscheidung über Spec 14
   frühestens nach einem Monat Praxis.
2. **Signierungs-/Verteilungsweg** (§8) — betrifft auch den Mac-Build und ist
   K.-o.-Kriterium; hängt an [`release-and-signing.md`](release-and-signing.md) §419.
3. **Zusammenfassung auf iOS**: Weg B (Mac erledigt es) als Default — bestätigen?
4. **Audio-Sync** bleibt aus (§6.2) — bestätigen? Alternative wäre On-Demand-Abruf
   einzelner Aufnahmen, das wäre eine eigene kleine Spec.
5. **iPadOS gleichwertig oder nur mitlaufend?** Vorschlag: dasselbe Binary, kein
   eigenes Layout in v1.
