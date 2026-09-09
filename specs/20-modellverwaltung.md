# Spec 20 — Modellverwaltung: sichtbar, reparierbar, versioniert

> **Aufwand: Stufe 1 = S, Stufe 2 = M.** Notable lädt 1,1 GB Modelle von HuggingFace,
> zeigt sie nirgends an, prüft sie nie und räumt nie auf. Stufe 1 macht sie sichtbar und
> aufräumbar; Stufe 2 bindet ihre Version an die App-Version und nimmt HuggingFace aus
> dem Laufzeitpfad.

## 1. Ausgangslage (Fakten aus dem Code und von der Platte)

Drei Aufrufe laden Modelle, alle erst zur Laufzeit und alle von HuggingFace:

| Aufruf | Datei | Ziel auf der Platte |
|---|---|---|
| `AsrModels.downloadAndLoad(progressHandler:)` | `ParakeetTranscriber.swift:19` | `~/Library/Application Support/FluidAudio/Models` |
| `DiarizerModels.downloadIfNeeded()` | `MeetingPipeline.swift:192` | dito |
| `VadManager()` | `MeetingPipeline.swift:152` | dito |
| `WhisperKit(model:)` | `WhisperTranscriber.swift:66` | WhisperKit-eigener Cache |

- **Es gibt überhaupt keine Modell-Revision.** `project.yml` sagt
  `FluidAudio: from: 0.15.0` (aufgelöst auf 0.15.5) und `WhisperKit: from: 0.9.0` —
  das sind Paket-Versionen. *Welches* HF-Repo dahinter liegt, entscheidet die
  Bibliothek; in welchem Stand, entscheidet niemand: `ModelRegistry.swift:57` lädt
  von `<baseURL>/<repoPath>/**resolve/main**/<filePath>`. Wer nach dem Repo pusht,
  ändert damit, was eine frische Installation bekommt — jederzeit, ohne
  Versionssprung, und auch bei exakt gepinnter FluidAudio-Version. Der naheliegende
  billige Ausweg („dann pinn eben `exactVersion`") trägt hier also nicht.
- **Es gibt keine Integritätsprüfung.** `AsrModels.modelsExist(at:version:)`
  (`ParakeetTranscriber.swift:27`) prüft *Anwesenheit*, nicht Vollständigkeit. Ein
  abgebrochener Download hinterlässt ein Verzeichnis, das „existiert".
- **Es gibt keine Oberfläche.** `StorageSettingsView`s Abschnitt „Belegung"
  (`:36-39`) kennt genau zwei Zeilen: Meeting-Audio und fehlgeschlagene Aufnahmen. Der
  mit Abstand größte Posten, den Notable auf die Platte legt, kommt darin nicht vor.
- **Es räumt niemand auf.** Gemessen am 2026-09-07 auf der produktiven Installation:

```
1,1 GB  FluidAudio/Models
  461M  parakeet-tdt-0.6b-v3           in Benutzung
  581M  parakeet-unified-en-0.6b       nur bei ASR-Engine „Parakeet Unified"
   23M  parakeet-tdt-0.6b-v3-coreml    nur Encoder+Decoder — abgebrochener Download
   13M  speaker-diarization            ┐ byte-gleicher Dateisatz,
   13M  speaker-diarization-coreml     ┘ zweimal auf der Platte
  1,0M  silero-vad         (v6.2.1)    ┐ FluidAudio hat die Verzeichnisnamen
  1,0M  silero-vad-coreml  (v6.0.0)    ┘ zwischen zwei Versionen geändert
```

  Das `-coreml`-Suffix ist eine Namensänderung zwischen zwei FluidAudio-Versionen.
  Weder FluidAudio noch Notable entfernt den alten Satz — er bleibt liegen, für immer.

- **Der Ordner heißt `FluidAudio`, nicht `Notable`.** Er trägt den Namen einer
  Bibliothek, von der der Nutzer nie gehört hat, weil
  `MLModelConfigurationUtils.defaultModelsDirectory()` das so entscheidet und
  Notable nie ein Ziel übergeben hat — obwohl `AsrModels.downloadAndLoad(to:)`
  und `DiarizerModels.load(from:)` eines entgegennehmen. Siehe [§3.4](#der-ordner-heißt-dann-notable).

- Daneben liegen 724 MB `~/.cache/huggingface/hub` mit `aufklarer/Parakeet-*` vom
  2026-06-19. **Das stammt nicht aus Notable** (`git log --all -S"aufklarer"` ist leer),
  ist aber totes Parakeet-CoreML in exakt der Größenordnung, in der Notable selbst
  Müll produziert — und der Grund, warum diese Spec nicht nur die eigenen Verzeichnisse
  betrachtet, sondern *meldet*, was sie findet.

## 2. Ziel

Ein Modell ist etwas, das man sehen, reparieren und entfernen kann — und dessen Version
man kennt. Explizit **kein** Ziel: bessere Erkennung. Diese Spec ändert nichts an der
Qualität, nur daran, dass 1,1 GB heute unsichtbar und unbeherrschbar sind.

## 3. Konzept

### 3.1 `ModelInventory` (pur, testbar)

Ein Verzeichnisscan über `AsrModels`-Wurzel + WhisperKit-Cache, der jedem Fund einen
Zustand gibt:

- **`inUse`** — von der aktuell gewählten Engine bzw. vom Meeting-Pfad gebraucht.
- **`available`** — vollständig, aber gerade nicht gewählt (z. B. Parakeet Unified).
- **`orphaned`** — kein aktueller Code-Pfad kennt diesen Namen mehr.
- **`incomplete`** — Verzeichnis da, aber die in `config.json` genannten `.mlmodelc`
  fehlen ganz oder teilweise.

Die Zuordnung „welcher Name ist aktuell" ist eine **Liste im Code**, keine Heuristik:
FluidAudio benennt seine Verzeichnisse selbst, und etwas zu löschen, weil ein Muster
nicht passte, wäre der falsche Fehlermodus. Die Liste steht neben den Aufrufen, die sie
erzeugen, und ist beim nächsten FluidAudio-Update mit anzufassen — genau wie die
API-Preise neben `model` (`CLAUDE.md`, Summarization).

### 3.2 In die vorhandene Seite, nicht in eine neue

Die Modelle bekommen **keinen eigenen Einstellungs-Tab**. Sie gehören in „Belegung" in
`StorageSettingsView`, unter die zwei Zeilen, die es schon gibt — eine Zeile je Modell
mit Zustand und Größe. Ein achter Tab wäre genau die Art Zuwachs, gegen die
[Spec 22](22-oberflaeche-entdoppeln.md) angeschrieben ist.

### 3.3 Aufräumen nach demselben Muster wie die Aufbewahrung

`StorageSettingsView` hat bereits die richtige Form dafür: **erst den Plan zeigen, dann
löschen** (`:80-96`). Verwaiste und unvollständige Modelle werden genauso behandelt —
„3 verwaiste Modellordner, 37 MB" mit einem Knopf daneben. Nie automatisch, aus
demselben Grund, aus dem die Aufbewahrung opt-in ist: einen Gigabyte ungefragt zu
löschen ist irreversibel.

**Ein unvollständiges Modell darf neu geladen werden** — Verzeichnis weg, Slot neu
laden. Das ist heute nur über „App löschen und neu installieren" erreichbar.

### 3.4 Stufe 2 — eigener Bezug, eigener Ordner, kein aufgeblähtes Release

Der ursprüngliche Entwurf hier lautete „die CoreML-Bundles als Assets an jedes
`Notable-x.y.z`-Release hängen". Das ist verworfen: rund ein Gigabyte an jeder
Veröffentlichung, auch an einem Patch, der eine Textzeile ändert.

#### Warum es überhaupt sein muss

`ModelRegistry.swift:57` in FluidAudio baut die Download-URL so:

```swift
let urlString = "\(baseURL)/\(repoPath)/resolve/main/\(filePath)"
```

**`resolve/main`.** Es gibt keine Revision, nirgends. Wer nach
`FluidInference/parakeet-tdt-0.6b-v3-coreml` pusht, ändert damit, was eine
frische Notable-Installation bekommt — jederzeit, ohne Versionssprung, auch bei
exakt gepinnter FluidAudio-Version. Der naheliegende billige Ausweg („dann pinn
eben `exactVersion`") trägt also nicht: die Paketversion sagt nichts darüber,
welche Gewichte hinter dem Namen liegen.

#### Der Weg

1. **Ein eigenes, selten wechselndes Modell-Release** am selben Repo, Tag etwa
   `models-2026.09`, mit den Bundles als Assets. Es wird veröffentlicht, wenn
   sich die Modelle ändern — nicht, wenn sich die App ändert. Die App-Releases
   bleiben so klein, wie sie sind.
2. **Der Tag und eine SHA-256 je Datei stehen im App-Build.** Damit ist die
   Modellfassung an die App-Version gebunden: ein Modellwechsel ist ein Release,
   kein stiller Nebeneffekt eines fremden Pushes.
3. **Notable lädt selbst**, auf Anforderung, nur für die gewählte Engine — genau
   wie heute, nur von woanders — und übergibt FluidAudio fertige Dateien. Die
   download-freien Einstiegspunkte gibt es alle:

   | | Weg ohne Download |
   |---|---|
   | Parakeet | `AsrModels.load(from: directory)` |
   | Diarisierung | `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:)` — dokumentiert mit „No models are downloaded" |
   | VAD | `VadManager(config:vadModel: MLModel)` |
   | Whisper | `WhisperKit(modelFolder:, download: false)` |

#### Der Ordner heißt dann Notable

Heute liegen die Modelle unter `~/Library/Application Support/**FluidAudio**/Models`,
weil `MLModelConfigurationUtils.defaultModelsDirectory()` das so entscheidet und
Notable nie ein Ziel übergeben hat. Seit Whisper nach `Notable/Models` lädt, ist
der Bestand sogar auf zwei Wurzeln verteilt — die schlechteste aller Fassungen.

Das ist **keine Frage von Stufe 2**: `AsrModels.downloadAndLoad(to:)` und
`AsrModels.download(to:)` nehmen ein Verzeichnis entgegen, `DiarizerModels`
ebenso. Ein Zielverzeichnis zu übergeben ist eine Zeile. Was dazugehört, ist ein
einmaliges Verschieben des vorhandenen Verzeichnisses, damit niemand 461 MB neu
lädt, nur weil ein Ordner umbenannt wurde — und ein Rückfall auf „dann eben neu
laden", falls das Verschieben scheitert.

Danach gilt: **alles, was Notable auf die Platte legt, liegt unter `Notable/`.**
Ein Anwendungsunterordner, der den Namen einer Bibliothek trägt, die der Nutzer
nicht kennt, ist auch dann falsch, wenn die Bibliothek ihn angelegt hat.

#### Integrität: nicht über `verifySignature`

Der frühere Entwurf schrieb, die Assets würden „über denselben Pfad geladen wie
das App-Update — inklusive der Signatur-/Team-ID-Prüfung aus
`UpdateInstaller.verifySignature`". Das trägt nicht.
`UpdateInstaller.swift:205` macht `codesign --verify --deep --strict` auf ein
**App-Bundle** und vergleicht dessen `TeamIdentifier` mit dem der installierten
App. Ein `.mlmodelc` ist keine Software, sondern Gewichte; es gibt dort keine
Team-ID zu vergleichen.

Die passende Antwort ist eine **SHA-256 je Datei, im App-Build festgeschrieben**,
nach dem Download verglichen, und bei Abweichung: verwerfen, nicht laden. Das ist
strikt mehr, als HuggingFace heute liefert — dort wird gar nichts geprüft.

#### Was es nicht ist

- **Kein Datenschutzgewinn.** Dorthin ging nie Audio, nur ein GET. Es geht um
  Reproduzierbarkeit und darum, nicht von einem fremden `main` abzuhängen.
- **Kein Ende der HuggingFace-Beziehung.** Die Dateien stammen weiterhin von
  dort; sie werden einmal geholt und ans Modell-Release gehängt. Weg ist die
  Abhängigkeit *im laufenden Betrieb*.
- **Nicht ins `.app`-Bundle einbacken.** 1,1 GB App, jede Notarisierung um eine
  Größenordnung länger, und jeder Patch lädt alles neu.

#### Verworfene Abkürzung

`ModelRegistry.baseURL` ist öffentlich überschreibbar und ausdrücklich „for a
different model registry or mirror" gedacht — eine Zeile beim Start, und alles
andere bliebe. Nur müsste der Spiegel die HuggingFace-Pfadform *und* deren
Listing-API (`api/models/…`) nachbilden, und GitHub Pages scheidet mit rund
einem Gigabyte an seinem Größenlimit aus. Ein eigener Host wäre wieder etwas,
das am Leben gehalten werden muss. Für ein Werkzeug mit einem Nutzer ist das
der schlechtere Tausch.

#### Aufwand

**Nicht M, sondern M–L.** Der Kern ist nicht der Bezug, sondern dass Notable das
Herunterladen übernimmt: Fortschrittsanzeige (Onboarding und Engine-Picker
zeigen sie und hängen daran), Wiederaufnahme nach Abbruch, atomares Ablegen,
und das Ablegen im Layout, das FluidAudio erwartet. Letzteres ist entschärft,
weil `ModelInventory` die erwarteten Dateinamen bereits aus `ModelNames` liest
statt sie zu raten — die Layout-Kenntnis kommt aus der Bibliothek.

Stufe 2 ist eine eigene Entscheidung und Stufe 1 geht ihr voraus.

## 4. Integration

- **Neu:** `Sources/Notable/Storage/ModelInventory.swift` — der Scan und die
  Zustandslogik, pur (Verzeichnisliste rein, `[ModelEntry]` raus), damit sie ohne
  Modelle auf der Platte testbar ist.
- **`StorageSettingsView`** — „Belegung" um die Modellzeilen erweitern, den
  Aufräum-Abschnitt um verwaiste Modelle. Kein neuer Tab, keine neue `@AppStorage`.
- **`ParakeetTranscriber` / `WhisperTranscriber`** — eine Möglichkeit, einen Slot
  gezielt zu verwerfen und neu zu laden. `retryLoad(_:)` in `DictationController` ist
  bereits der halbe Weg; heute löscht es nur den Task, nicht das Verzeichnis.
- **`CLAUDE.md`** — der Absatz über Modelle muss sagen, wo sie liegen und wer über ihre
  Version entscheidet. Steht heute nirgends.

## 5. Risiken

- **Die Namensliste kann veralten.** Wird FluidAudio umbenannt und die Liste nicht
  nachgezogen, meldet Notable ein *benutztes* Modell als verwaist. Deshalb: löschen nur
  nach Bestätigung, und die Liste steht im selben Commit wie das Paket-Update.
- **Größe ≠ Vollständigkeit.** Die `incomplete`-Prüfung liest `config.json` und schaut
  nach, ob die genannten `.mlmodelc` da sind. Wo es keine `config.json` gibt (WhisperKit),
  bleibt es bei „vorhanden" — lieber keine Aussage als eine falsche.
- **Stufe 2 verschiebt eine Abhängigkeit, sie entfernt sie nicht.** Statt HuggingFace
  ist GitHub der Single Point of Failure. Für ein persönliches Werkzeug, dessen Updates
  ohnehin von dort kommen, ist das der bessere Tausch — aber es ist einer.
- **Der eigene Downloader ist der eigentliche Risikoträger.** FluidAudios Version
  kann wiederaufnehmen, meldet Fortschritt und legt korrekt ab; unsere muss das
  alles neu können, und ein Fehler darin trifft den ersten Start eines neuen
  Nutzers — den Moment, in dem die App am wenigsten Vertrauen hat.
- **Das Verschieben des Modellordners darf nichts verlieren.** Scheitert es, ist
  der richtige Ausgang „neu laden", nicht „halb hier, halb dort". Ein Modell an
  zwei Orten ist genau der Zustand, gegen den Stufe 1 angeschrieben ist.

## 6. Abnahme

- Die Belegungs-Seite nennt jedes Modell mit Zustand und Größe; die Summe stimmt mit
  `du -sh` überein.
- Ein von Hand halbierter Modellordner wird als `incomplete` gemeldet und lässt sich neu
  laden.
- Ein von Hand angelegter Ordner mit unbekanntem Namen wird als `orphaned` gemeldet und
  nach Bestätigung entfernt; ein benutzter wird es nie.
- `ModelInventoryTests` deckt alle vier Zustände gegen ein temporäres Verzeichnis ab —
  ohne echte Modelle.
- Stufe 2: ein frischer Start lädt die Modelle vom Modell-Release, nicht von
  HuggingFace; eine manipulierte Datei fällt an der SHA-256 durch und wird
  verworfen statt geladen.
- Stufe 2: nach einem Update liegt kein Modell mehr unter `FluidAudio/`, und der
  Bestand wurde verschoben, nicht neu geladen.
- Stufe 2: ein Netzwerkabbruch mitten im Download endet in einem Zustand, den der
  nächste Versuch fortsetzen oder sauber verwerfen kann — nie in einem
  Verzeichnis, das `modelsExist` für vollständig hält.

## 7. Stand (2026-09-09)

**Stufe 1 ist gebaut.** `ModelInventory` klassifiziert beide Modellwurzeln, die
Belegungs-Seite zeigt jedes Modell mit Zustand und Größe, verwaiste und
unvollständige lassen sich nach Bestätigung entfernen. `ModelInventoryTests` deckt
alle vier Zustände gegen ein temporäres Verzeichnis ab.

Drei Dinge sind anders gekommen, als hier stand:

- **Die `config.json` taugt nicht als Manifest.** Gemessen: in *jedem*
  Modellverzeichnis steht buchstäblich `{}`. Die Vollständigkeitsprüfung liest
  stattdessen FluidAudios eigene `ModelNames.ASR.requiredModelsV3()`,
  `ModelNames.Diarizer.requiredModels`, `ModelNames.VAD.requiredModels` und
  `ModelNames.ParakeetUnified.requiredModels(variant:)`.
- **Die Namensliste ist keine eigene mehr.** Sie kommt aus `Repo.folderName`. Damit
  erledigt sich Risiko §5 weitgehend: benennt FluidAudio ein Verzeichnis um, wandert
  „aktuell" von selbst mit, und der alte Ordner wird von allein verwaist — genau
  das, was `silero-vad-coreml` und `speaker-diarization-coreml` passiert ist.
- **WhisperKit lud nach `~/Documents/huggingface`.** Stand in keiner Spec, ist aber
  der Ordner hinter einer eigenen TCC-Abfrage und der, den Leute in die Cloud
  synchronisieren — für bis zu 1,5 GB Modellgewichte der falsche Ort, und eine
  Einstellungsseite, die zum Zählen einen Dokumente-Dialog auslöst, wäre schlimmer.
  `downloadBase` zeigt jetzt auf `Application Support/Notable/Models`. Ein
  bestehender Download dort bleibt liegen und ist von Notable aus nicht lesbar; das
  ist der Preis und er ist einmalig.

**Stufe 2 ist nicht gebaut** und wurde am 2026-09-09 neu gefasst (§3.4). Der
ursprüngliche Entwurf — Modelle als Assets an jedes App-Release — ist verworfen:
rund ein Gigabyte an jeder Veröffentlichung, auch an einem Patch, der eine
Textzeile ändert. Stattdessen ein eigenes, selten wechselndes Modell-Release,
das die App per Tag und SHA-256 festnagelt, während sie weiterhin selbst und auf
Anforderung nur das gewählte Modell lädt.

Zwei Dinge sind dabei aufgefallen, die den früheren Text widerlegen:

- **`resolve/main`** — es gibt gar keine Modell-Revision, nirgends. Der Text hier
  behauptete, ein Modellwechsel passiere, „wenn FluidAudio ihn beschließt";
  tatsächlich beschließt niemand etwas, und auch eine exakt gepinnte
  Paketversion hilft nicht.
- **`UpdateInstaller.verifySignature` taugt nicht für Gewichte** — es prüft eine
  Code-Signatur und eine Team-ID an einem App-Bundle. Die Integrität muss über
  SHA-256 laufen.

Der Modellordner heißt weiterhin `FluidAudio` (§1). Das ist unabhängig von
Stufe 2 behebbar — `AsrModels.downloadAndLoad(to:)` nimmt ein Verzeichnis
entgegen —, gehört aber sinnvollerweise in denselben Durchgang: Stufe 2 fasst
den Bezug ohnehin an, und den Bestand zweimal zu verschieben wäre albern.
