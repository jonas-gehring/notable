# Spec 30 — HUD und Fehlerfläche

> **Aufwand: Stufe 1 = S–M (2 Tage), Stufe 2 = S, Stufe 3 = S.** Das HUD springt ohne
> Übergang auf und weg und trägt zwei unverwandte Gesichter; Fehler sind rohe
> `localizedDescription`, zwei Zeilen, drei Sekunden, dann weg — und das Audio dazu ist
> weg. Das ist das, was von außen als „nicht ausgereift" gelesen wird. Kein Kernpfad
> wird angefasst; alles hier ist Anzeige, Ton und Aufbewahrung.
> Quelle: `docs/analyse-wispr-flow-paritaet-2026-09-14.md` §5.1, §5.3, §5.5, A8, A9.

## 1. Ausgangslage (Fakten aus dem Code)

- **Kein Ein-/Ausblenden.** `panel.orderFrontRegardless()` (`DictationOverlay.swift:73`)
  und `panel?.orderOut(nil)` (`:68, :122`) — die Kapsel erscheint und verschwindet in
  einem Frame. Die einzigen Animationen sind eine Feder auf `locked` (`:255`) und ein
  Ease-Out auf der Wellenform-Historie (`:342`).
- **Zwei Identitäten.** Unten: `Color.black.opacity(0.78)`, weißer Rand 10 %, weißer
  Text (`:248-254`) — fest, passt sich nicht an. Notch: `.regularMaterial` und
  `.primary` (`:396, :412`) — adaptiv. Kein Bezug auf `Theme`.
- **Wellenform mit 10 Hz.** Der Pegel kommt aus dem Level-Timer alle 0,1 s
  (`DictationController.swift:462-465`); `PCMDownsampler.append` berechnet den RMS
  je Puffer (`PCMDownsampler.swift:138-140`), also weit öfter — der Timer sampelt das
  nur. 18 Balken, 0,12 s Ease-Out gegen ein 60/120-Hz-Display: die Balken stufen.
- **`reduceMotion` als `static let`** (`:226, :330`) — einmal gelesen, gilt bis zum
  Neustart.
- **Spinner für 120 ms.** `.transcribing` zeigt `ProgressView` + „Transkribiere…"
  (`:279-283`) auch für ein Diktat, das in 119 ms fertig ist.
- **Fehler.** `flashError(String)` (`:127-134`), 3 s, `lineLimit(2)` (`:295`). Elf
  Aufrufer in `Sources`; im Diktatpfad rohes `error.localizedDescription` bei
  `DictationController.swift:441, :703, :738` und `NotableApp.swift:158, :607`.
  Kein Wiederholen, keine Historie des Fehlers.
- **Nicht klickbar.** `ignoresMouseEvents = true` (`:156`). Abbruch nur per Esc, und
  nur mit Bedienungshilfe-Recht; fehlt es, verschwindet der Hinweis (`:275`).
- **Töne.** Zwei Systemklänge (`NSSound(named: "Tink")`, `"Pop"`,
  `DictationController.swift:457, :689`) hinter `dictationSounds`, Fallback `false`.
- **Audio ist RAM-only.** Ein Diktat existiert nur als `[Float]` im Task; bei
  `notConfigured` (`:764-777`), einem Transkriptionsfehler oder einem blockierten Paste
  ist es weg. Die Historie (`DictationHistory`) liest nur gespeicherte Erfolge
  (`RecordingStore.recentDictations`, `:555`).
- **Vier Lokalisierungslecks**, die `LocalizationTests` nicht sieht:
  `NotificationCenterService.swift:69, :81` (`title: "Aufnehmen"` als `String`),
  `NoteListView.swift:89` (`Text(note.title ?? "Ohne Titel")`),
  `RecentDictationsList.swift:76` (`Text(text.isEmpty ? "(kein Text)" : text)`),
  `MeetingChat.swift:136`. „Ohne Titel" und „(kein Text)" fehlen in `en.lproj`.

## 2. Ziel

Ein HUD, das in beiden Stilen dasselbe Ding ist, kommt und geht wie ein Objekt und
nicht wie ein Schalter, dem Nutzer bei Erfolg ein Signal gibt und bei Misserfolg drei
Dinge sagt: was, warum, was jetzt — und das Diktat dabei nicht verliert.

## 3. Konzept

### Stufe 1 — Das HUD

**3.1 Ein Gesicht.** Beide Stile bauen auf derselben Kapsel: `.regularMaterial`
(Notch: `.thickMaterial`, weil dort kein Rand ist), `Theme.textEmphasis` /
`Theme.textSubtle`, `Theme.radiusCard`. Die schwarze Kapsel geht. Wer sie behalten
will, bekommt sie nicht als Option — ein HUD, zwei Themes, ist genau das, was als
„aus zwei Händen" gelesen wird.

**3.2 Ein- und Ausblenden.** Erscheinen: Alpha 0 → 1 und Scale 0,96 → 1 in 120 ms,
Ease-Out. Verschwinden: Alpha 1 → 0 in 160 ms, dann `orderOut`. Umsetzung am Panel
(`NSAnimationContext` auf `panel.animator().alphaValue`), nicht in SwiftUI — der
`orderOut` muss **nach** der Animation kommen, und SwiftUI-Transitions wissen nichts
vom Fenster. Zustandswechsel innerhalb der Kapsel (Wellenform → „Transkribiere…"):
`contentTransition(.opacity)` und eine Feder auf die Breite, 200 ms. Bei
`accessibilityDisplayShouldReduceMotion`: alles sofort — gelesen **live** über
`NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`, nicht als `static let`.

**3.3 Spinner erst ab 300 ms.** `show(.transcribing)` startet einen 300-ms-Task; ist
der Job vorher fertig, sieht der Nutzer: Wellenform → weg. Erst danach erscheint
„Transkribiere…". Bei Bootstrap-Modell oder `.loadingModel` sofort — dort ist Warten
die Wahrheit.

**3.4 Wellenform aus dem Audio.** `AudioRecorder` bekommt `onLevel: ((Float) -> Void)?`,
vom Consumer-Thread je Puffer gerufen und mit `CADisplayLink`-Kadenz (bzw. 30 Hz)
zusammengefasst; der 0,1-s-Timer bleibt nur für Idle-Timeout und Maximaldauer. 18
Balken decken damit 0,6 s statt 1,8 s ab — die Form der Sprache, nicht ihr Verlauf
über zwei Sekunden. Gain 8 und Exponent 0,7 bleiben (gemessen, `:355`).

**3.5 Töne.** Vier eigene, kurze Klänge (< 150 ms, gebündelte `.caf`, Lautstärke an
den Systemton gekoppelt): `start` (aufsteigend), `done` (kurz, tief), `cancelled`
(abfallend), `failed` (zwei tiefe Töne). Lock: `start` zweimal. Systemklänge „Tink"
und „Pop" fallen weg — sie gehören anderen Apps. Auslösung als Pipeline-Effekt
(Spec 29 §3.8). Vorgabe **an** (Spec 29 §7).

### Stufe 2 — Fehlerfläche

**3.6 `DictationFailure`** (Spec 29 legt die Aufzählung an) trägt je Fall `title`
(ein Satz, was) und `hint` (ein Satz, was jetzt). Beispiele:

| Fall | Titel | Hinweis |
|---|---|---|
| `microphoneDenied` | Mikrofonzugriff fehlt. | Systemeinstellungen → Datenschutz → Mikrofon. |
| `secureInput` | Sicheres Eingabefeld aktiv. | In ein normales Textfeld klicken. |
| `nothingHeard(device)` | Nichts gehört über „AirPods". | Anderes Mikrofon wählen oder Deckel öffnen. |
| `nothingRecognized` | Nichts verstanden. | — |
| `targetChanged(app)` | App gewechselt — Text in der Zwischenablage. | ⌘V im richtigen Fenster. |
| `pasteBlocked` | Einfügen braucht die Bedienungshilfe. | Text liegt in der Zwischenablage. |
| `modelMissing` | Modell fehlt — Diktat aufbewahrt. | Menü → Letztes Diktat wiederholen. |
| `deviceLost` | Mikrofon verschwunden. | Text bis hierhin wird transkribiert. |

Die Kapsel zeigt `title` (eine Zeile) und `hint` in `Theme.textSubtle` darunter;
Sichtdauer 4 s, bei zwei Zeilen 6 s. `flashError(String)` bleibt für die
Nicht-Diktat-Aufrufer, wird im Diktatpfad aber nicht mehr mit `localizedDescription`
gefüttert: jeder `catch` dort landet in einem `DictationFailure`-Fall, der System-Text
geht ins Log (`os.Logger`), nicht in die Kapsel. Die Aufrufer außerhalb (`NotableApp`,
`MeetingController`, Settings) bekommen dasselbe Muster in ihrer eigenen Spec — hier nur
die zwei in `NotableApp.swift:158, :607`, weil sie das Diktat betreffen.

**3.7 Der letzte Clip bleibt.** Nach `recorder.stop()` schreibt der Controller die
Samples als `.i16` nach `Application Support/Notable/spool-dictation/last.i16`
(`SpoolAudio.encode`, ein File, überschrieben) — ~32 KB/s, ein 60-s-Diktat unter 2 MB.
Bei Erfolg wird die Datei nach dem Speichern gelöscht. Bei Misserfolg
(`transcriptFailed`, `modelMissing`, `pasteBlocked`, `targetChanged`) bleibt sie und
bekommt `last.json` daneben: Zeitstempel, Dauer, Fehlerfall, Zielapp, und — wenn ein
Transkript existiert — der Text. `DictationHistory.recent` bekommt daraus eine erste
Zeile „Fehlgeschlagen · 14:02 · Mikrofonzugriff fehlt" mit **Wiederholen** (Clip erneut
durch die Pipeline, als Job) und **Kopieren** (wenn Text da ist). Kein Schema: die
Historie ist ohnehin ein Lesemodell, und der Eintrag verschwindet mit der Datei. Die
Datei zählt in `StorageFootprint` nicht als eigener Posten — sie ist maximal zwei
Megabyte und hat ihre Lebensdauer im Namen.

**3.8 Die vier Lecks.** `title: String(localized: "Aufnehmen")` (zweimal);
`Text(note.title ?? String(localized: "Ohne Titel"))`; `Text(text.isEmpty ?
String(localized: "(kein Text)") : text)`; `MeetingChat` analog. Dazu eine dritte
Form im Scanner von `LocalizationTests`: `Text(<ausdruck> ?? "…")` und
`Text(<bedingung> ? "…" : <variable>)` — der Fall, in dem eine Seite ein `String` ist
und das Literal deshalb wörtlich gerendert wird. Der Test findet damit, was heute nur
das Lesen fand.

### Stufe 3 — Abbrechen mit der Maus (optional)

**3.9** Wispr Flows Bar hat Abbrechen/Stopp. Notables Panel ignoriert die Maus, weil
ein Klick in ein Panel, das Fokus nehmen könnte, den Paste-Mechanismus bricht. Ein
`.nonactivatingPanel` mit `canBecomeKey == false` **kann** Klicks annehmen, ohne key zu
werden; `ignoresMouseEvents` wäre dann nur für die transparente Fläche wahr (per
`NSView.hitTest`-Override, das außerhalb der Kapsel `nil` liefert). Ein „×" links in der
Kapsel während Aufnahme und Verarbeitung; Klick = Esc. `DictationOverlayTests`
prüft weiterhin `canBecomeKey == false` und dass `NSApp.keyWindow` nach dem Klick
derselbe ist. Erst bauen, wenn Stufe 1 und 2 stehen, und nur mit diesem Test.

## 4. Integration

| Stelle | Änderung |
|---|---|
| `DictationOverlay.swift` | eine `DictationOverlayView` für beide Stile (Notch-Layout als Modifier, nicht als zweite View); Alpha/Scale am Panel; 300-ms-Schwelle; Live-`reduceMotion`; `title`/`hint`-Darstellung |
| `Theme.swift` | `Theme.hudMaterial`, `Theme.Duration.appear/disappear` (Spec 33 zieht die Dauern in ein Token-Set) |
| `AudioRecorder.swift`, `PCMDownsampler.swift` | `onLevel`-Callback, 30-Hz-Koaleszenz |
| `Resources/Sounds/*.caf` (neu) | vier Klänge; `SoundCue` mit `NSSound(contentsOf:)`, einmal geladen |
| `DictationController.swift` | Clip-Aufbewahrung, `last.json`, Fehlerfälle statt `localizedDescription` |
| `DictationHistory.swift`, `RecentDictationsList.swift`, `NotableApp.swift` (Menü) | die Fehlgeschlagen-Zeile mit Wiederholen/Kopieren |
| `StorageFootprint`/`RetentionPlanner` | `spool-dictation/` ist kein Posten und wird nie aufgeräumt — es gibt nur eine Datei |
| `NotificationCenterService.swift:69, :81`, `NoteListView.swift:89`, `RecentDictationsList.swift:76`, `MeetingChat.swift:136`, `en.lproj` | die Lecks |
| `LocalizationTests.swift` | dritte Musterform |
| `DictationOverlayTests` | Stil-Schleife über `allCases`; Alpha nach `show` = 1, nach `hide` + 200 ms `isVisible == false`; bei Reduce-Motion sofort |

## 5. Risiken

- **Material auf einem Video.** `.regularMaterial` über einem hellen Fenster hat weniger
  Kontrast als die schwarze Kapsel. Der Text bleibt `Theme.textEmphasis` (Label-Farbe,
  adaptiv), und `.thickMaterial` ist die Reserve, wenn die Messung an einem weißen
  Dokument nicht reicht.
- **Animation und Latenz.** Das Ausblenden (160 ms) läuft **nach** dem Paste, nicht
  davor: `hide()` wird vor `Paster.insert` gerufen (`:686`) — der `orderOut` darf nicht
  auf die Animation warten, sonst liegt die Kapsel während des Pastes noch da. Also:
  `hide()` startet die Animation und kehrt zurück; das Panel ist ab dem ersten Frame
  nicht mehr im Weg, weil es ohnehin nie key ist.
- **Der letzte Clip ist Audio auf der Platte.** Eine einzelne Datei, überschrieben,
  bei Erfolg gelöscht — kein Archiv, keine Aufbewahrungsfrage. Wer das nicht will,
  hat keinen Schalter; der Nutzen (ein Diktat, das nicht verloren ist) ist größer als
  der Nachteil (bis zu 2 MB Sprache bis zum nächsten Diktat).
- **Stufe 3** ist der einzige Teil, der die Panel-Invariante berührt. Deshalb zuletzt
  und mit dem Test als Wächter.

## 6. Abnahme

1. Beide Stile: dieselbe Kapsel, adaptiv hell/dunkel, `Theme`-Farben; kein `Color.black`
   im HUD-Code.
2. Erscheinen und Verschwinden animiert; mit Reduce-Motion sofort, ohne Neustart nach
   dem Umschalten der Systemeinstellung.
3. Ein 5-s-Diktat zeigt keinen Spinner; ein 60-s-Diktat zeigt ihn nach 300 ms.
4. Wellenform bewegt sich bei jedem Frame; `LatencyProbeTests` unverändert.
5. Vorgabe-Installation: Start, Ende, Abbruch und Fehler sind hörbar und unterscheidbar.
6. Mikrofon entziehen, diktieren: Kapsel sagt „Mikrofonzugriff fehlt." und
   „Systemeinstellungen → Datenschutz → Mikrofon."; Historie zeigt die Zeile
   „Fehlgeschlagen"; nach Erteilen: **Wiederholen** fügt den Text ein.
7. `grep -rn 'flashError(error.localizedDescription' Sources/Notable/Dictation` leer.
8. Englisches Fenster: Consent-Mitteilung „Record", Notizliste „Untitled", Historie
   „(no text)". `LocalizationTests` schlägt fehl, wenn man eines davon zurückbaut.

## 7. Offene Entscheidungen

- **Kontrast-Reserve:** `.regularMaterial` oder `.thickMaterial` als Grundlage — am
  weißen Dokument und am Video messen, dann festlegen.
- **Klangsprache:** vier Klänge sind ein Gestaltungsauftrag; ob selbst gebaut oder aus
  einer freien Bibliothek, entscheidet der Owner.
- **Stufe 3** überhaupt: ein klickbares HUD ist die einzige Änderung hier mit einem
  echten Risiko im Paste-Mechanismus.
