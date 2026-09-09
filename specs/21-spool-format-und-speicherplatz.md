# Spec 21 — Spool-Format und sichtbarer Speicherplatz

> **Aufwand: Stufe 1 = S, Stufe 2 = S–M, Stufe 3 = S.** Notable belegt auf der
> produktiven Installation 5,1 GB und sagt es nirgends. Die Hälfte davon ist Format,
> nicht Inhalt: das Spool schreibt Float32, wo Int16 dasselbe bedeutet.

## 1. Ausgangslage (Fakten aus dem Code und von der Platte)

Gemessen am 2026-09-07:

```
3,9 GB  spool-archive     16 Sitzungen, älteste vom 19. Juli
 80 MB  spool-failed       6 Sitzungen
1,1 GB  FluidAudio/Models  (siehe Spec 20)
─────────────────────────────────────────
5,1 GB  gesamt — an keiner Stelle der Oberfläche sichtbar
```

Die größte archivierte Sitzung: **823 MB für 112 Minuten** — `mic.pcm` und `system.pcm`
zu je 411 MB.

- **Das Spool ist Float32.** `PCMDownsampler` arbeitet in `.pcmFormatFloat32` bei
  16 kHz mono (`:5, :12`) und schreibt die Puffer roh weg
  (`spoolHandle.write(contentsOf: Data(buffer: chunk))`, `:146`).
  `SpoolStore.readSamples` liest sie zurück, indem es die Dateigröße durch
  `MemoryLayout<Float>.size` teilt (`:93-99`). Das Format steht nirgends in einer
  Datei — es ist die Annahme auf beiden Seiten.
- **16 kHz mono Float32 sind 64 KB/s.** Int16 wären 32 KB/s bei identischer
  Verständlichkeit: die ASR-Modelle sind auf 16-Bit-Audio trainiert, und die Kette
  davor (`AVAudioConverter` aus dem Mikrofon-/Tap-Format) liefert nichts, was 24 Bit
  Dynamik rechtfertigen würde.
- **Das Archiv wird von Notable nie gelesen.** `spool-archive` taucht an genau vier
  Stellen auf: geschrieben in `SpoolStore.archive` (`:135-139`), *vermessen* von
  `StorageSettingsView` (`:176-181`) und `RetentionPolicy` (`:270`), und benannt in
  `RetentionPolicy.Klasse` (`:97`). Die Absturz-Wiederherstellung liest `spool/`, nicht
  das Archiv. Das Archiv existiert ausschließlich, damit ein Mensch eine misslungene
  Aufnahme von Hand retten kann.
- **Die Aufbewahrung ist aus.** `retentionEnabled` ist auf der produktiven Installation
  nicht gesetzt, also aus — so entworfen, und die Entscheidung bleibt richtig
  (`CLAUDE.md`: „deleting someone's meeting audio unasked … is not a default"). Nur:
  die Konsequenz wurde nie ausgesprochen. Sieben Wochen Nutzung, 3,9 GB, keine Meldung.
- **Die Belegungs-Seite kennt zwei Zeilen** (`StorageSettingsView:36-39`), und man
  findet sie nur, wenn man bereits ahnt, dass etwas nicht stimmt.

## 2. Ziel

Derselbe Inhalt, ein Viertel der Bytes, und die Zahl an einer Stelle, an der man sie
sieht, ohne sie zu suchen. **Kein** Ziel: automatisch löschen. Die Aufbewahrung bleibt
opt-in; diese Spec sorgt dafür, dass man die Entscheidung überhaupt trifft.

## 3. Konzept

### 3.1 Stufe 1 — Int16 im Spool (Faktor 2, kein Verhaltensunterschied)

- `PCMDownsampler` schreibt beim Spoolen Int16 statt Float32. Der In-Memory-Pfad
  (Diktat, `snapshot()`, `drain()`) bleibt Float32 — dort geht es um Latenz, nicht um
  Bytes, und die ASR-API nimmt `[Float]`.
- **Das Format muss in der Datei stehen, nicht in einer Annahme.** Neue Dateien heißen
  `mic.i16` / `system.i16`; `readSamples` entscheidet nach Dateiname, welche Deutung
  gilt. Bestandsdateien (`mic.pcm`) bleiben Float32 und bleiben lesbar — die
  Absturz-Wiederherstellung eines Spools, der über ein Update hinweg liegen bleibt,
  darf nicht davon abhängen, welche Version ihn geschrieben hat.
- Die Umrechnung ist `Int16(clamping: Int(sample * 32767))` beim Schreiben und
  `Float(value) / 32767` beim Lesen. Der Rundungsfehler liegt bei 3·10⁻⁵ — vier
  Größenordnungen unter `TrackSilence.peakThreshold` (1e-4), die Stille-Erkennung
  bleibt also unberührt.

### 3.2 Stufe 2 — verlustfrei komprimieren beim Archivieren (Faktor ~2 obendrauf)

Weil das Archiv **nie zurückgelesen wird**, hat es keine Formatpflicht gegenüber dem
Rest des Codes. `SpoolStore.archive` schreibt die beiden Spuren beim Verschieben in
eine ALAC-`.m4a` (`AVAudioFile`, `kAudioFormatAppleLossless`) — verlustfrei, vom Finder
und von QuickTime abspielbar, was für „von Hand retten" ein Fortschritt gegenüber einer
rohen `.pcm` ist.

Bei 16 kHz Sprache liegt ALAC erfahrungsgemäß bei 50–60 % von Int16. Zusammen mit
Stufe 1 werden aus 3,9 GB grob **0,9–1,2 GB** — ohne dass irgendwer etwas entscheidet
oder etwas verliert.

**Verlustbehaftet wäre hier falsch.** Das Archiv existiert, um eine Aufnahme zu retten,
bei der die Erkennung versagt hat; sie danach durch einen Codec zu schicken, der genau
die leisen Passagen wegwirft, um die es dabei geht, wäre der falsche Tausch.

### 3.3 Stufe 3 — die Zahl sichtbar machen

- **„Belegung" wird vollständig**: Meeting-Audio, fehlgeschlagene Aufnahmen, Modelle
  (Spec 20), Datenbank. Heute fehlen zwei von vier.
- **Eine Zeile im Menü**, nach dem Muster der Statistikzeile (`UsageSummary`, die schon
  gepusht statt gepollt wird) — aber **nur oberhalb einer Schwelle**. Eine dauerhafte
  „2,1 GB"-Zeile im Menü ist Lärm; eine, die ab 5 GB erscheint, ist eine Antwort auf
  eine Frage, die man sonst nie stellt. Klick öffnet die Belegungs-Seite.
- Die Schwelle ist eine Konstante im Code, keine Einstellung. Ein Schalter für „ab wann
  darfst du mir sagen, dass du 5 GB belegst" wäre genau die Art Frage, die niemand
  beantworten will.

### 3.4 Bestand umrechnen: angeboten, nicht erzwungen

Ein Knopf in der Belegungs-Seite rechnet vorhandene Archive um — mit vorher angezeigtem
Plan („16 Sitzungen, 3,9 GB → ca. 1,1 GB"), wie das Aufräumen es schon macht. Nicht
beim Start, nicht im Hintergrund: es ist stundenlanges I/O über Dateien, die der Nutzer
für den Notfall aufbewahrt.

## 4. Integration

- **`PCMDownsampler`** — Schreibpfad auf Int16, `spoolURL` bekommt die neue Endung.
  Der Ringpuffer und der Consumer-Thread aus v1.1.0 bleiben unangetastet; die
  Umrechnung passiert im Consumer, nie im IO-Proc.
- **`SpoolStore`** — `readSamples` entscheidet nach Endung; `archive` komprimiert.
  `Session` bekommt die beiden Dateinamen als Eigenschaft statt sie zu konstruieren.
- **`SpoolInventory` / `RetentionPolicy`** — arbeiten über Verzeichnisgrößen und sind
  formatblind; sie brauchen nichts.
- **`StorageSettingsView`** — Belegung vervollständigen, Umrechnen-Knopf, Modellzeilen
  aus Spec 20.
- **`UsageSummary` / `NotableApp`** — die Schwellenzeile im Menü.

## 5. Risiken

- **Ein Formatfehler zerstört die Notfallkopie.** Deshalb ist die Endung Teil des
  Vertrags und nicht ein Feld in `meta.json`, das fehlen kann — und deshalb bleibt der
  Float32-Lesepfad, statt „ab jetzt ist alles Int16" anzunehmen.
- **ALAC muss nachweislich verlustfrei sein.** Ein Test schreibt eine bekannte Spur,
  liest sie zurück und vergleicht Sample für Sample. Fällt der durch, entfällt Stufe 2
  und Stufe 1 steht allein — die trägt bereits den Faktor 2.
- **Die Menüzeile darf nicht zum Dauerzustand werden.** Erscheint sie und der Nutzer
  räumt nicht auf, steht sie für immer da. Deshalb öffnet ihr Klick die Seite, auf der
  man die Aufbewahrung *einschaltet* — die Zeile ist ein Weg zur Entscheidung, nicht
  ihr Ersatz.

## 6. Abnahme

- Eine neue Meeting-Aufnahme erzeugt `mic.i16`/`system.i16`; die Bytes pro Sekunde
  liegen bei 32 KB je Spur.
- Ein Bestands-Spool mit `mic.pcm` wird nach einem Update noch korrekt
  wiederhergestellt (`SpoolStoreTests` mit beiden Formaten).
- Int16-Round-Trip verändert `TrackSilence.isSilent` an keiner Stelle: eine stille Spur
  bleibt stumm, eine leise bleibt hörbar.
- ALAC-Round-Trip ist sample-identisch.
- „Belegung" nennt vier Posten und ihre Summe stimmt mit `du -sh` auf beiden
  Verzeichnissen plus Modellen überein.
- Die Menüzeile erscheint oberhalb der Schwelle und verschwindet nach dem Aufräumen.
