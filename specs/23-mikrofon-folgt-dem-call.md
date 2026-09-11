# Spec 23 — Das Mikrofon folgt dem Call

> **Aufwand: Stufe 0 = S (½ Tag), Stufe 1 = M, Stufe 2 = S.** Seit dem 12. August fehlt
> in **jeder** Call-Aufnahme die eigene Stimme: die Mikrofonspur ist exakt 0,0000, und
> zwar über ganze Stunden. Notable nimmt das System-Standardmikrofon auf. Der Call
> benutzt ein anderes Gerät. Das ist der kritischste Punkt dieser Runde und die
> Voraussetzung für Spec 24: die Sprecherbenennung läuft nur, wenn das Mikrofon etwas
> geliefert hat, und das hat es seit einem Monat nicht.
>
> Anforderung im Wortlaut: *„externes Audio wird nicht erkannt"*. Diese Spec liest das
> als „mein externes Mikrofon wird nicht aufgenommen" — die Messung unten stützt genau
> das. Sollte etwas anderes gemeint sein, bitte vor dem Bau sagen.

## 1. Ausgangslage (Fakten von der Platte und aus dem Code)

### 1.1 Gemessen am 2026-09-11

Spitzenpegel über **alle** Samples der Rohspuren in `spool-archive/` und `spool-failed/`,
dazu die `Ich`-Segmente aus SQLite:

| Beginn | Meeting | Dauer | Mikrofon-Peak | System-Peak | `Ich`-Segmente |
|---|---|---|---|---|---|
| 10.09. 10:03 | Sync – Hausmeister App | 30,4 min | **0,0000** | 0,79 | 0 |
| 10.09. 08:59 | Interview with Payhawk | 54 min | stumm¹ | laut | 0 |
| 07.09. 17:01 | Gehaltsverhandlung | 2,6 min | 0,82 | 0,0000 | 19 |
| 04.09. 13:00 | Interview Senior Consultant | 39,8 min | **0,0000** | 0,80 | 0 |
| 04.09. 10:01 | Jonas Gehring and Maria Wendler | 28,1 min | **0,0000** | 1,00 | 0 |
| 27.08. 16:00 | Statusabgleich | 5,1 min | **0,0000** | 0,88 | 0 |
| 27.08. 09:01 | Jahresabschlusszahlen | 11,4 min | **0,0000** | 0,85 | 0 |
| 19.08. 09:30 | Konditionen Fördermittel | 57,1 min | **0,0000** | 1,02 | 0 |
| 19.08. 08:01 | Coaching-Session | 61,8 min | **0,0000** | 0,66 | 0 |
| 13.08. 09:10 | Forschungszulage | 42,1 min | **0,0000** | 0,97 | 0 |
| 13.08. 09:00 | Meeting | 9,6 min | **0,0000** | 0,26 | 0 |
| bis 07.08. | 9 Meetings | | — | — | 3 … 685 je Meeting |

¹ Bereits nach ALAC umgeschrieben: `mic.m4a` 330 KB gegen `system.m4a` 35 MB für
dieselben 54 Minuten. So komprimiert nur Stille.

Das Muster ist eindeutig: **Jeder Call hat eine stumme Mikrofonspur, das einzige
Gespräch ohne Call-App (Gehaltsverhandlung, Systemspur stumm) hat eine funktionierende.**
Die Berechtigung ist also in Ordnung, und die Systemspur auch.

### 1.2 Der Zustand des Rechners bei der Messung

- `ioreg … AppleClamshellState = Yes` — **der Deckel ist zu**, am Samsung C34H89x
  (DisplayPort, *nur Ausgang*, kein Mikrofon).
- Standard-Eingang: `MacBook Pro Microphone`. Weitere Eingänge: `iPhone_Jonas Microphone`
  (Continuity), `Microsoft Teams Audio` (virtuell). Zwei AirPods-Paare sind gekoppelt.
- Apple-Silicon- und T2-Laptops **trennen das eingebaute Mikrofon bei geschlossenem
  Deckel in Hardware** (Apple Platform Security, „Hardware microphone disconnect"). Das
  Gerät bleibt aufgelistet und bleibt Standard — es liefert nur Nullen. Genau das ist
  0,0000, nicht „leise".
- Call-Apps wählen ihr Eingabegerät **selbst** (Teams/Zoom: Geräteauswahl in der App),
  unabhängig vom Systemstandard. Teams hört also das Headset, Notable den zugeklappten
  Deckel.

### 1.3 Im Code

- **`AudioRecorder` wählt kein Gerät.** `engine.inputNode` (`AudioRecorder.swift:73`) ist
  der Systemstandard. `kAudioOutputUnitProperty_CurrentDevice` kommt in `Sources/`
  nicht vor (grep). Diktat und Meeting teilen diesen Pfad.
- **Die Diagnose nennt die falsche Ursache.** Der Wächter während des Calls sagt
  „Mikrofon-Berechtigung für Notable prüfen" (`MeetingController.swift:325-327`), die
  Abschlussmeldung ebenso (`:734-735`). Mit dieser Meldung kann niemand den Fehler
  beheben — die Berechtigung *ist* erteilt.
- **Nirgends steht, welches Gerät aufgenommen wurde.** `SpoolStore.Meta` kennt
  `startedAt`, `eventTitle`, `eventID` (`SpoolStore.swift:9-13`). Ein Monat stummer
  Aufnahmen lässt sich im Nachhinein nur über den Umweg dieser Spec rekonstruieren.
- **Folgeschaden:** `produceNote` überspringt die Sprecherbenennung bei stummem Mikrofon
  (`MeetingController.swift:761`) — zu Recht, siehe Spec 24 —, also hat seit dem 12.08.
  keine einzige Notiz einen Namen bekommen.
- **Beobachtung, kein Beweis:** Seit dem 04.09. ist kein einziges Diktat gespeichert
  (03.09.: 37). Diktat nimmt über denselben Weg auf. Ob es versucht wurde und leer
  blieb, sagt die Datenbank nicht.

### 1.4 Nebenbefund `SystemAudioTap`

Der Samplerate-Listener hängt am **System-Objekt** (`SystemAudioTap.swift:201-208`).
`kAudioDevicePropertyNominalSampleRate` ist aber eine Eigenschaft von *Geräten*; der
Rückgabewert von `AudioObjectAddPropertyListenerBlock` wird ignoriert. Der Listener
feuert also vermutlich nie. Die Systemspur war in allen Messungen intakt, einen
sichtbaren Schaden gibt es nicht — wird im Vorbeigehen korrigiert: Listener am
aktuellen Ausgabegerät registrieren und nach jedem Gerätewechsel neu setzen.

## 2. Ziel

Die eigene Stimme wird von dem Gerät aufgenommen, in das man spricht, ohne dass man
wissen muss, dass es einen Unterschied zwischen „Systemstandard" und „Gerät in Teams"
gibt. Wo das nicht geht, sagt Notable es **während des Calls**, mit der echten Ursache
und den echten Gerätenamen.

**Kein Ziel:** den Systemstandard umstellen. Das wäre ein Eingriff außerhalb von
Notable (gleiche Begründung wie beim `MediaInterrupter`).

## 3. Konzept

### 3.1 Stufe 0 — die Ursache belegen und sichtbar machen (vor allem anderen)

Die Hypothese aus 1.2 ist stark, aber nicht gemessen: **welches Gerät Teams benutzt hat,
steht nirgends.** Stufe 0 schließt diese Lücke, bevor Stufe 1 gebaut wird.

- **`CaptureDiagnostics`** (pure, `Codable`) wird bei Start und bei jedem Gerätewechsel
  in `meta.json` geschrieben:
  - aufgenommenes Eingabegerät: Name, UID, Transport (`kAudioDevicePropertyTransportType`)
  - Standard-Eingang, Standard-Ausgang
  - Deckel-Zustand (`AppleClamshellState` aus der IORegistry — lesbar ohne TCC)
  - der erkannte Call-Prozess und **seine** Eingabegeräte
    (`kAudioProcessPropertyDevices`, Scope Input, macOS 14+, im SDK vorhanden)
  - Echo-Unterdrückung an/aus

  `Meta` bekommt das Feld optional: alte `meta.json` bleiben lesbar (Wiederherstellung
  eines Spools über ein Update hinweg, wie in Spec 21).
- **`SilenceDiagnosis`** (pure) ersetzt die Berechtigungs-Vermutung in beiden Meldungen:

  | Fall | Meldung |
  |---|---|
  | eingebautes Mikro + Deckel zu | „Deckel geschlossen — das eingebaute Mikrofon ist dann abgeschaltet. {App} benutzt ‚{Gerät}'." |
  | Call-Prozess nutzt anderes Gerät | „Notable hört ‚{A}', {App} benutzt ‚{B}'." |
  | TCC nicht `authorized` | die heutige Berechtigungs-Meldung — **nur** dann |
  | sonst | Gerätename, keine Vermutung |

- **Ein echter Call** mit zugeklapptem Deckel, dann `meta.json` lesen. Bestätigt sich
  die Hypothese nicht, wird Stufe 1 neu gefasst, bevor sie gebaut wird.

### 3.2 Stufe 1 — Eingabegerät wählen statt erben

**`InputDevicePolicy.choose(_ context:) -> Choice`** (pure, tabellengetestet). Regeln in
dieser Reihenfolge, die erste passende gewinnt:

1. **Festgelegtes Gerät** aus den Einstellungen, falls vorhanden und angeschlossen.
2. **Meeting: das Eingabegerät des Call-Prozesses** — der Prozess, auf den
   `MeetingDetector` eingerastet ist (`activeCandidate.processBundleIDs`, Präfix-Match
   wie in `AudioProcessSnapshot`). Transporte `virtual` und `aggregate` werden
   übersprungen: „Microsoft Teams Audio" ist kein Mikrofon, und Notables eigenes
   Aggregat erst recht nicht.
3. **Systemstandard** — außer: eingebautes Mikrofon **und** Deckel zu.
4. Wurde 3 übersprungen: **ein anderes lebendes Eingabegerät**, Vorrang USB > bereits
   laufendes Bluetooth-Headset > Continuity > Rest. **Bluetooth nur, wenn es schon
   aufnimmt** (`kAudioDevicePropertyDeviceIsRunningSomewhere`): ein AirPods-Mikrofon
   zu öffnen, das der Call nicht benutzt, schaltet die AirPods in den
   Headset-Modus und ruiniert dem Nutzer die Wiedergabe.
5. Nichts davon → eingebautes Mikrofon **und sofort** die Warnung aus 3.1, nicht erst
   nach 20 s.

Diktat benutzt die Regeln 1, 3, 4, 5 (es gibt keinen Call-Prozess).

**`AudioRecorder.start(device:)`** setzt `kAudioOutputUnitProperty_CurrentDevice` auf
`engine.inputNode.audioUnit`, **bevor** das Format gelesen und die Engine gestartet
wird. `resume()` bekommt dasselbe Gerät erneut.

**Während der Aufnahme** wird die Policy neu ausgewertet, entprellt um 1 s, bei:

- Änderung von `kAudioProcessPropertyDevices` am Call-Prozess (Nutzer wechselt in Teams),
- `kAudioHardwarePropertyDevices` (Gerät an-/abgesteckt),
- `kAudioHardwarePropertyDefaultInputDevice`,
- dem Wächter aus Stufe 0.

Ein Wechsel läuft über den bestehenden Pfad `resume()` + `padGapToWallClock()`; die Spur
bleibt wanduhrlang.

**Selbstheilung:** meldet der Wächter nach 20 s Stille und liefert die Policy ein
anderes lebendes Gerät, wird **ohne Rückfrage** umgeschaltet und gesagt: „Mikrofon
gewechselt auf ‚AirPods Pro' — die ersten 20 s fehlen." Das ist kein Eingriff nach
außen, nur eine Korrektur der eigenen Wahl.

**Echo-Unterdrückung (VPIO)** ist per Default aus. Ob VPIO auf macOS ein anderes als
das Standardgerät akzeptiert, ist unbelegt und wird im Bau gemessen. Geht es nicht,
wird VPIO für diese Aufnahme abgeschaltet und über den bestehenden Warnpfad
(`voiceProcessingError`) gemeldet — das Gerät hat Vorrang vor der Echo-Unterdrückung,
weil eine stumme Spur schlimmer ist als ein Echo.

### 3.3 Stufe 2 — Einstellung und Sichtbarkeit

- **Einstellungen → Meetings → „Mikrofon":** `Automatisch` (Default) oder ein
  bestimmtes Gerät. Daneben ein Pegel (vorhandener Meter) und „Zuletzt aufgenommen von:
  AirPods Pro".
- **Menü während der Aufnahme:** eine Zeile mit dem Gerätenamen unter dem Status.
  Wer sieht „MacBook Pro Mikrofon" bei zugeklapptem Deckel, braucht keine Diagnose mehr.

## 4. Integration

- **`AudioRecorder`** — `start(device:)`, `resume()` behält das Gerät; Gerät per
  `AudioUnitSetProperty`.
- **Neu `Dictation/InputDevicePolicy.swift`** (pure) + **`Support/AudioDevices.swift`**
  (CoreAudio-Auflistung: Name, UID, Transport, läuft-irgendwo, Deckel-Zustand).
- **`AudioProcessMonitor`** — `inputDevices(ofBundleIDs:)` über
  `kAudioProcessPropertyDevices`.
- **`MeetingDetector`** — gibt den eingerasteten Kandidaten heraus; auch ein manueller
  Start während eines laufenden Calls fragt ihn.
- **`MeetingController`** — Policy vor `micRecorder.start`, Listener, Selbstheilung,
  `SilenceDiagnosis` in `startMicWatchdog` und `produceNote`.
- **`DictationController`** — Policy vor dem Start (ohne Call-Regel).
- **`SpoolStore.Meta`** — optionales `diagnostics`.
- **`SystemAudioTap`** — Samplerate-Listener am Gerät statt am System-Objekt.
- **`MeetingsSettingsView`**, Menü — Stufe 2. `en.lproj` für jede neue Meldung
  (`LocalizationTests`).

## 5. Risiken

- **`kAudioProcessPropertyDevices` ist neu und dünn dokumentiert.** Ob der Input-Scope
  für Chromium-Helper und für Teams das tatsächlich benutzte Gerät liefert, wird in
  Stufe 0 gemessen, nicht angenommen. Liefert es nichts, bleiben Regeln 3–5 — die
  allein lösen bereits den Fall „Deckel zu".
- **Eine falsche Wahl ist schlimmer als der Standard.** Deshalb ist die Wahl immer
  sichtbar (Menüzeile), festlegbar (Regel 1) und die Bluetooth-Regel konservativ.
- **Diktat-Latenz.** Das Gerät wird einmal beim Start gesetzt; die Auflistung kostet
  Mikrosekunden. Kein Listener läuft im Diktatpfad.
- **Bluetooth-HFP liefert 16 kHz schmalbandig.** Für die ASR unkritisch (die Modelle
  arbeiten mit 16 kHz); der Formatwechsel beim Umschalten löst die bestehende
  `AVAudioEngineConfigurationChange` aus.

## 6. Abnahme

- Deckel zu, Call über AirPods/Headset: Mikrofonspur nicht stumm, `Ich`-Segmente im
  Transkript, Sprecherbenennung läuft (Spec 24).
- Deckel offen, eingebautes Mikrofon: unverändert.
- Gerätewechsel mitten im Call: die Spur läuft weiter, ihre Länge entspricht der
  Wanduhr ± 100 ms (wie heute nach `resume()`).
- Die Stille-Meldung nennt die Ursache; der Berechtigungstext erscheint nur bei
  fehlender Berechtigung.
- `meta.json` enthält `diagnostics`; eine alte `meta.json` ohne das Feld wird
  wiederhergestellt (`SpoolStoreTests`).
- `InputDevicePolicyTests`: jede Regel, jede Ausnahme, die Bluetooth-Regel.
- Diktat bei zugeklapptem Deckel mit externem Mikrofon liefert Text.
