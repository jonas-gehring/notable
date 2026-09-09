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

- **Notable pinnt die Paket-Version, nicht die Modell-Revision.** `project.yml` sagt
  `FluidAudio: from: 0.15.0` (aufgelöst auf 0.15.5) und `WhisperKit: from: 0.9.0`.
  *Welches* HF-Repo in welcher Revision dahinter liegt, entscheidet die Bibliothek. Ein
  Modellwechsel passiert also, wenn FluidAudio ihn beschließt, beim nächsten kalten
  Cache, ohne Ankündigung und ohne dass irgendwo steht, was vorher da war.
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

### 3.4 Stufe 2 — Modelle ans Release hängen

Die eigentliche Antwort auf „kann das nicht nativ über die App":

- Die CoreML-Bundles werden als Assets neben `Notable-x.y.z.zip` ans GitHub-Release
  gehängt und über **denselben Pfad geladen wie das App-Update** — inklusive der
  Signatur-/Team-ID-Prüfung aus `UpdateInstaller.verifySignature`.
- Damit ist die Modell-Revision an die App-Version gebunden: ein Modellwechsel ist ein
  Release, kein stiller Nebeneffekt eines Paket-Updates.
- HuggingFace fällt als Laufzeit-Abhängigkeit weg. Das ist kein Datenschutzgewinn (es
  ging nie Audio dorthin, nur ein GET), sondern ein Reproduzierbarkeits-Gewinn: heute
  kann derselbe App-Build auf zwei Rechnern zwei verschiedene Modelle benutzen.
- **Nicht** ins `.app`-Bundle einbacken: 1,1 GB App, jede Notarisierung um eine
  Größenordnung länger, und jeder Patch lädt alles neu.

Stufe 2 ist eine eigene Entscheidung — sie bedeutet Release-Assets von rund einem
Gigabyte und macht `scripts/release.sh` zum Modell-Publisher. Stufe 1 ist unabhängig
davon sinnvoll und geht ihr voraus.

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

## 6. Abnahme

- Die Belegungs-Seite nennt jedes Modell mit Zustand und Größe; die Summe stimmt mit
  `du -sh` überein.
- Ein von Hand halbierter Modellordner wird als `incomplete` gemeldet und lässt sich neu
  laden.
- Ein von Hand angelegter Ordner mit unbekanntem Namen wird als `orphaned` gemeldet und
  nach Bestätigung entfernt; ein benutzter wird es nie.
- `ModelInventoryTests` deckt alle vier Zustände gegen ein temporäres Verzeichnis ab —
  ohne echte Modelle.
- Stufe 2: ein Release trägt die Modell-Assets, ein frischer Start lädt sie von dort,
  und `codesign`-Prüfung greift auf demselben Weg wie beim App-Update.

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

**Stufe 2 ist nicht gebaut** und bleibt eine eigene Entscheidung: sie hängt rund ein
Gigabyte an jedes Release und macht `scripts/release.sh` zum Modell-Publisher.
