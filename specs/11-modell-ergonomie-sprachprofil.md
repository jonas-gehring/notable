# Spec 11 — Modell-Ergonomie am Picker & Sprachprofil

> **Aufwand: S.** Zwei Dinge am Auswahlpunkt: der Engine-Picker zeigt Downloadgröße,
> Status und Live-Fortschritt, und ein Sprachprofil sagt dem Polisher, welche Sprachen
> überhaupt in Frage kommen.
> **Eine Qualitätsstufen-Benennung der Engines ist bewusst gestrichen** (§4).

## 1. Ausgangslage (Fakten aus dem Code)

- Der Engine-Picker (`SettingsView.swift:256-266`) listet drei Engines mit Labels aus
  `ASREngineID.label` („Parakeet v3 — mehrsprachig (Standard)" usw.), darunter bei Whisper
  ein zweiter Picker für die Modellgröße (`:265`).
- **Downloadgrößen stehen nur bei Whisper** im Label (`WhisperModelSize.label`, „~75 MB" …
  „~1,5 GB"). Für Parakeet v3/Unified erfährt man nichts — weder Größe noch Fortschritt;
  der Download läuft schweigend in FluidAudio.
- Der Ladezustand erscheint als **eine Textzeile im Menü** (`NotableApp.swift:237-238`,
  `dictation.modelState.label`) — nicht im Settings-Fenster, wo man die Engine umschaltet.
- Ein fehlgeschlagener Ladevorgang (`.failed`) wird erst beim **nächsten Diktat** implizit
  erneut versucht (`DictationController.swift:341-349`). Es gibt keinen „nochmal versuchen"-Knopf.
- `TextPolisher.isEnglish` (`TextPolisher.swift:90-94`) fragt `NLLanguageRecognizer` **ohne
  Einschränkung** nach `dominantLanguage == .english` und entscheidet damit über
  englische Filler-Entfernung (`:49`, `:60-62`) und ITN (`:64-66`).
- `WhisperTranscriber.transcribe` (`:67`) nutzt `DecodingOptions(task: .transcribe,
  detectLanguage: true)` — freie Spracherkennung pro Clip.

## 2. Teil A — Zustand & Fortschritt dort, wo man wählt

Am Engine-Picker in Settings → Diktat, je Engine:

- **Größe** („Parakeet v3 — mehrsprachig, ~2,4 GB"; Zahl vor dem Bau an einem echten
  Download verifizieren, nicht schätzen).
- **Status**: „geladen" / „lädt: 42 %" / „nicht geladen" / „Fehler: …". Die Fortschrittszahl
  kommt aus dem `progressHandler`, den Spec 10 §4 durchreicht — beide Specs teilen sich diese
  Leitung, und ohne Spec 10 §8.1 gibt es hier nur „lädt".
- **„Nochmal versuchen"** bei `.failed`, statt auf das nächste Diktat zu warten.
- Kennzeichnung, welche Engine gerade **aktiv** ist, falls sie von der gewählten abweicht
  (Bootstrap, Spec 10 §3).

Damit sieht man, was ein Umschalten kostet, bevor man umschaltet.

## 3. Teil B — Sprachprofil (`de`, `en`)

Eine Sprachliste kann bei Whisper direkt `lang_detect` einschränken. In Notable ist der
Hebel ein anderer, weil Parakeet v3 selbst erkennt und keinen Knopf dafür hat:

Neu: `@AppStorage("spokenLanguages")` — Default `["de", "en"]`, Mehrfachauswahl in
Settings → Diktat („Sprachen, die ich diktiere").

Wirkung, in der Reihenfolge des Nutzens:

1. **`TextPolisher.isEnglish` wird angeleitet statt zu raten.** `NLLanguageRecognizer`
   kennt `languageConstraints` — auf `[.german, .english]` gesetzt, kann ein kurzes
   „Ok, weiter so" nicht mehr als Niederländisch/Dänisch durchgehen und in der falschen
   Filler-Klasse landen. Das ist der einzige Teil dieser Spec, der den **Kernpfad** berührt
   (Polishing läuft bei jedem Diktat) — also mit Tests, nicht nebenbei.
2. **Whisper**: Bei genau **einer** gewählten Sprache `DecodingOptions(language:)` fest setzen
   statt `detectLanguage: true` — spart die Erkennungsrunde und schließt Fehlerkennung aus.
   Bei mehreren Sprachen bleibt es bei `detectLanguage: true` (WhisperKit kennt keine
   Kandidatenliste wie whisper.cpp).
3. **Parakeet v3/Unified**: **keine Wirkung.** Das muss im UI-Hinweistext stehen, sonst
   erwartet man einen Effekt, den es nicht gibt („wirkt auf Textnachbearbeitung; Whisper
   zusätzlich auf die Erkennung").

## 4. Gestrichen: Tier-Umbenennung („Fast / Standard / Accurate")

Modelle nach Qualitätsstufen zu benennen wäre für Notable eine **Falschaussage**:
die drei Engines unterscheiden sich in der *Art*, nicht im Qualitätsgrad — Unified ist
englisch-only und streaming-fähig, v3 ist mehrsprachig, Whisper ist die Fremdvergleichs-Option
mit eigener Größenwahl. Ein Qualitätsschieber würde genau die Einschränkung verstecken, die man
beim Umschalten kennen muss („Unified = Accurate?" — nein, „Unified = kein Deutsch").

Gebaut wird deshalb nur die Ergonomie: Größe, Status und Fortschritt am Auswahlpunkt.

## 5. Edge Cases

- **Leere Sprachauswahl** ist unmöglich: die letzte Sprache lässt sich nicht abwählen —
  mindestens eine, Fallback `de`.
- **Sprachprofil ohne Englisch** (`["de"]`): englische Filler und ITN werden dann nie
  angewandt — das ist gewollt und muss getestet sein, nicht überraschen.
- **Fortschritt bei warmem Cache**: kein Download, kein Balken — Status springt direkt auf
  „geladen". Kein Phantom-0-%-Zustand anzeigen.
- **Meetings**: Das Sprachprofil wirkt auf das Polishing der Meeting-Segmente mit (gleicher
  `TextPolisher`). Das ist konsistent und gewollt; die Meeting-ASR selbst bleibt v3, also
  unberührt.

## 6. Tests

- `TextPolisherTests` erweitern: mit Profil `["de","en"]` verhält sich die Erkennung wie heute
  bei klaren Fällen; ein kurzes deutsches „Ok, dann machen wir das" behält „er"/„um" nicht
  fälschlich entfernt; mit Profil `["en"]` werden englische Filler entfernt, mit `["de"]` nicht.
  Die Sprach-Constraints als Parameter in `Options` durchreichen, damit die Tests keine
  `UserDefaults` brauchen (Muster: `Options.fromDefaults()`, `:29`).
- Ein Test, der belegt, dass eine einzige Profilsprache bei Whisper zu `DecodingOptions.language`
  führt (Reine Options-Konstruktion in eine testbare Funktion ziehen — `pipe.transcribe` bleibt
  ungetestet).
- UI-Zustände einmal manuell durchlaufen: nicht geladen → lädt (%) → geladen → Fehler → Retry.

## 7. Umsetzungsschritte

1. Status + Größe + Retry am Picker (ohne Prozentzahl, falls Spec 10 §8.1 noch nicht steht).
2. Fortschritt anschließen, sobald der `progressHandler` läuft.
3. Sprachprofil: Speicher + UI + Durchreichen in `TextPolisher.Options`.
4. Whisper-Sonderfall (eine Sprache → fest setzen).

## 8. Nicht-Ziele

- Keine Umbenennung der Engines (§4).
- Keine Sprachliste mit 100 Einträgen. Notable diktiert Deutsch und Englisch; die Auswahl
  bleibt auf die Sprachen begrenzt, die `TextPolisher` überhaupt unterscheidet.
- Kein Eingriff in Parakeets interne Spracherkennung.
