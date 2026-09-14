# Spec 31 — Regeln nachziehen: Satzanfänge, deutsche Zahlen, Füllwörter, Apps, Pausen

> **Aufwand: S + M + S + S + S–M (zusammen etwa eine Woche).** Fünf Lücken im
> regelbasierten Polish, die ein Nutzer täglich merkt und die kein Modell brauchen.
> Alles pur, offline, mit dem bestehenden Testmuster. Die fünfte Zeile — Absätze an
> Sprechpausen — stand als „ohne Protokolländerung nicht zu haben" in
> `specs/README.md:112`; das Feld, das dafür fehlt, kommt beim Ganzclip-Aufruf bereits mit.
> Quelle: `docs/analyse-wispr-flow-paritaet-2026-09-14.md` §4.1.

## 1. Ausgangslage (Fakten aus dem Code)

- **Großschreibung nur am Anfang.** `tidy` ruft `capitalizingFirstWord` genau einmal
  auf das ganze Ergebnis (`TextPolisher.swift:224-225`); `ParagraphFormatter` tut es
  für den ersten Block nach einem Kommando (`ParagraphFormatter.swift:295-296`). Ein
  Satzanfang mitten im Text kommt so vom ASR, wie er kommt. Setzt Parakeet nach einem
  Punkt klein fort — oder lässt den Punkt weg —, bleibt es so.
- **ITN nur englisch.** `if options.applyITN, english { EnglishITN.normalize }`
  (`:99-101`). `EnglishITN` (`:465-800`) ist eine echte, konservative Implementierung:
  Zeit, Datum, Währung, Prozent, Dezimal, Ordinal, Kardinal, mit ausdrücklichen
  Rückziehern bei Mehrdeutigkeit (März/Mai ausgeschlossen, `:559`; bare „one"–„nine"
  nicht gewandelt, `:793`; Idiome, `:750-772`). Eine deutsche Entsprechung existiert
  nicht. Der Schalter heißt in den Einstellungen „Zahlen & Daten formatieren (nur
  Englisch)" (`DictationSettingsView.swift:87`).
- **Füllwörter.** Universell `ähem, ähm, ähh, äh, mhm, hmm`; englisch `uhm, um, uh,
  erm, er` (`:63-65`). Kein „sozusagen", „quasi", kein „you know", „I mean". Das
  Muster `(^|\s)filler,?(?=[\s.!?;:]|$)` (`:77`) kennt keine Position — es gibt keine
  Regel „nur am Satzanfang" oder „nur zwischen Kommas". Wiederholungen („ich ich")
  werden nie angefasst.
- **App-Tabelle.** 20 Bundle-IDs (`AppCategory.swift:33-61`): fünf Chat, drei Mail,
  sieben Code, fünf Prosa. **Kein Browser**, kein Notion, Linear, Teams, Zoom, Cursor,
  Zed, Ghostty, Warp, Sublime, Nova, BBEdit. `of(bundleID:overrides:)` (`:70`) wird an
  der einzigen Produktionsstelle ohne `overrides` gerufen
  (`DictationController.swift:627`); Spec 03 §5 (Tabelle + Picker) ist ungebaut.
- **Absätze nach Satzzahl.** `ParagraphFormatter` bricht nach drei Sätzen
  (`ParagraphFormatter.swift:27`), begründet mit fehlenden Wortzeiten (`:13-17`).
  `ParakeetTranscriber.transcribe` verwirft alles außer `result.text`
  (`ParakeetTranscriber.swift:41-42`). FluidAudios `ASRResult` trägt aber
  `tokenTimings: [TokenTiming]?` mit `token`, `startTime`, `endTime`, `confidence`
  (`AsrTypes.swift:142-147` im Checkout unter `build/SourcePackages`). Das Protokoll
  `TranscriptionEngine.transcribe` liefert `String`.

## 2. Ziel

Nach dieser Spec liest sich ein deutsches Diktat wie ein deutsches Diktat: Satzanfänge
groß, „22,50 €" statt „zweiundzwanzig Euro fünfzig", ohne „sozusagen", mit Absätzen
dort, wo der Sprecher Luft geholt hat. Und die Ziel-App-Erkennung trifft die Apps, die
tatsächlich benutzt werden. Alles ohne eine Millisekunde messbarer Zusatzlatenz.

## 3. Konzept

### 3.1 Satzanfänge (S)

Nach `tidy`, vor `ParagraphFormatter`: Satzgrenzen mit `NLTokenizer(.sentence)` —
derselbe Tokenizer, den der Formatter schon benutzt (`ParagraphFormatter.swift:277`).
Für jeden Satz `capitalizingFirstWord` mit demselben Schutz (nur wenn das Wort komplett
klein ist; iPhone, macOS, eBay bleiben). Gilt nur, wenn `capitalizeStart` wahr ist —
das Chat-Profil setzt es auf `false` (`:267`) und bleibt so, weil ein kleiner Satzanfang
dort Absicht sein kann. Verbatim kommt nie hierher.

**Was nicht gemacht wird:** fehlende Satzzeichen erfinden. Ein ASR-Text ohne Punkt ist
ein Satz, und die Regel kann nicht wissen, wo er endet. Das ist Modellarbeit (Spec 32).

### 3.2 `GermanITN` (M)

Spiegel von `EnglishITN`, gleiche Struktur (Tokens, `match*`-Funktionen, leftmost
längster Treffer), gleiche Haltung: **im Zweifel nicht wandeln**. Läuft, wenn die
Spracherkennung Deutsch sagt; der Einstellungs-Schalter verliert sein „(nur Englisch)".

| Form | Beispiel | Regel |
|---|---|---|
| Kardinal | „zweiundzwanzig" → 22, „dreihundertfünf" → 305, „zweitausendvierundzwanzig" → 2024 | deutsche Zahlwörter sind **ein Token**: Zerlegung an `und`, `hundert`, `tausend`; „ein/eine/einer" sind Artikel und werden nie gewandelt; „eins" nur in Zusammensetzungen; zwei bis zwölf allein bleiben Wörter (Duden-Konvention), ab dreizehn Ziffern |
| Ordinal | „dritter März" → „3. März", „am zweiten" → „am 2." | nur vor Monatsnamen oder nach „am/den/vom/bis zum"; „erstens" bleibt (Kommando in `ParagraphFormatter`) |
| Datum | „dritter März zweitausendvierundzwanzig" → „3. März 2024" | Monat bleibt Wort — „3.3.2024" wäre eine Formatentscheidung, die die Ziel-App treffen soll |
| Uhrzeit | „halb drei" → 2:30, „viertel nach acht" → 8:15, „acht Uhr dreißig" → 8:30 Uhr, „um acht" → „um 8 Uhr" | „halb/viertel" nur mit Stundenwort; „um acht" nur mit „um"; „Uhr" wird angehängt, wenn es gesprochen war |
| Währung | „zweiundzwanzig Euro fünfzig" → „22,50 €", „fünf Cent" → „5 Cent" | nur mit gesprochenem Euro/Cent/Dollar/Pfund; Cent allein bleibt Wort |
| Prozent | „zwanzig Prozent" → „20 %" | mit geschütztem Leerzeichen |
| Dezimal | „drei Komma fünf" → „3,5" | nur mit gesprochenem „Komma" |
| Nicht gewandelt | „ein paar", „zu zweit", „die ersten drei", „dreieinhalb" (→ Bruch bleibt), Telefonnummern | ausdrücklich getestet |

Zahlwörter-Zerlegung ist der schwierige Teil und wird eigenständig getestet
(`GermanNumberTests`: 60 Fälle, darunter „einhundertelf", „neunzehnhundert",
„zweiundzwanzigtausend").

### 3.3 Füllwörter mit Position, Wiederholungen (S)

`FillerRule { word, position }` mit `position ∈ { anywhere, sentenceStart,
commaBounded }`. Die heutigen Listen bleiben `anywhere`. Neu:

- Deutsch, `commaBounded` oder `sentenceStart`: „sozusagen", „quasi", „also" (nur am
  Satzanfang **mit** folgendem Komma: „Also, ich denke" → „Ich denke"; „also ist es"
  bleibt), „halt" (nur `commaBounded`).
- Englisch, nur bei erkanntem Englisch: „you know", „I mean", „sort of", „kind of"
  (`commaBounded`); „like" **nicht** — zu oft ein Verb oder Vergleich.

Wiederholungen: unmittelbar doppelte Wörter werden zu einem, wenn beide klein
geschrieben sind und das Wort in einer festen Liste von Funktionswörtern steht
(`ich, das, die, der, und, wir, es, ist, dass, the, I, and, it, that, we`). „Sehr
sehr" und „ja ja" bleiben — Betonung ist Inhalt. Fehlstarts („ich hab— ich habe")
werden nicht erkannt; das ist Modellarbeit.

### 3.4 App-Tabelle und Picker (S + S)

`defaultMapping` wächst um die Apps, die in `recordings.source_app` dieser
Installation tatsächlich vorkommen (die Spalte existiert seit Spec 03 — eine Abfrage
sagt, welche fehlen), plus die naheliegenden:

- **Prosa**: Safari, Chrome, Arc, Firefox, Edge, Brave (Spec 03 §9: ein Browser ist
  eine Kategorie — was im Tab läuft, ist nicht zu wissen), Notion, Craft, Ulysses,
  iA Writer, Drafts, TextEdit, Claude, ChatGPT.
- **Chat**: Microsoft Teams, Zoom, Signal, Messenger, Mattermost, Element.
- **Code**: Cursor, Zed, Windsurf, Sublime Text, Nova, BBEdit, Ghostty, Warp, kitty,
  Alacritty, Fleet, GoLand, Rider, CLion, RustRover, Android Studio.
- **Mail**: Spark, Mimestream, Thunderbird, Airmail.

Dazu Spec 03 §5, so wie dort beschrieben: `DefaultsKey.appCategoryOverrides` (JSON
`[String: String]`), gelesen in `finishRecording` und als `overrides:` übergeben; in
den Einstellungen eine Tabelle „App → Kategorie" mit einem Picker aus
`NSWorkspace.shared.runningApplications` (Name + Icon, nie eine Bundle-ID tippen) und
einem Kategorie-Popup. Vorbelegte Zeilen sind sichtbar, aber nicht löschbar — nur
umkategorisierbar.

### 3.5 Absätze an Sprechpausen (S–M)

`TranscriptionEngine` bekommt neben `transcribe` ein
`transcribeDetailed(samples:sampleRate:) -> Transcript` mit `text` und `pauses:
[String.Index]` — Stellen im Text, an denen zwischen zwei Tokens mehr als
`paragraphGapSeconds` (0,8 s, wie Spec 03 es vorsah) lag. Nur `ParakeetTranscriber`
liefert Pausen (aus `tokenTimings`); die anderen beiden liefern `[]`, und der
Formatter fällt dort auf die Satzzahl zurück wie heute.

Abbildung Token → Textposition: FluidAudios Tokens sind SentencePiece-Stücke mit
„▁" als Wortgrenze; ihre Verkettung ergibt den Text. Die Abbildung wird in
`TokenTimingMap` (pur) gebaut und mit echten `ASRResult`s aus `ParakeetTranscriberTests`
gegen `result.text` geprüft — Abweichung ⇒ keine Pausen, nie ein falscher Umbruch.

Regel im Formatter: ein Absatz ist **erlaubt** an einem Satzende, das mit einer Pause
zusammenfällt; ohne Pause frühestens nach `sentencesPerParagraph` (bleibt 3) als
Obergrenze, nie mitten im Satz. Spec 03 §„Bewusst nicht gebaut" in `specs/README.md`
wird gestrichen.

## 4. Integration

| Stelle | Änderung |
|---|---|
| `TextPolisher.swift` | Satzanfänge nach `tidy`; `GermanITN` (eigene Datei `Dictation/GermanITN.swift`); `FillerRule`; Wiederholungen |
| `Dictation/GermanITN.swift` (neu, pur) | wie `EnglishITN` |
| `AppCategory.swift`, `DefaultsKey.swift`, `DictationController.swift:627` | Tabelle, `appCategoryOverrides`, `overrides:` übergeben |
| `Settings/AppCategorySettings.swift` (neu) | Tabelle + Picker, eingebunden in die „App-Anpassung"-Sektion |
| `TranscriptionEngine.swift`, `ParakeetTranscriber.swift`, `Dictation/TokenTimingMap.swift` (neu, pur) | `transcribeDetailed`, Pausen |
| `ParagraphFormatter.swift` | `pauses` als Eingabe; Regel §3.5 |
| `DictationSettingsView.swift:87` | Schaltertext ohne „(nur Englisch)" |
| Tests | `TextPolisherTests` (+12), `GermanITNTests` (neu, ≥ 40), `GermanNumberTests` (neu, ≥ 60), `FillerRuleTests` (neu), `AppCategoryTests` (+5), `TokenTimingMapTests` (neu), `ParagraphFormatterTests` (+6) |

Kein Schema. Die Latenz: alle Regeln laufen im `Task.detached`-Polish
(`DictationController.swift:635`), Mikrosekunden bis wenige Millisekunden;
`LatencyProbeTests` misst den Transcriber allein und bleibt gleich. Für die Pausen
kommt kein zusätzlicher ASR-Aufruf hinzu — nur ein Feld, das bisher verworfen wurde.

## 5. Risiken

- **Deutsche Zahlwörter sind Komposita.** „zweiundzwanzig" ist ein Token, „ein und
  zwanzig" nicht. Die Zerlegung muss beides tragen; der Fehlermodus ist eine falsche
  Zahl im Text, und der ist schlimmer als ein ausgeschriebenes Wort. Deshalb „im
  Zweifel nicht" und sechzig Testfälle, bevor die Regel scharf ist.
- **„also" und „halt".** Beide sind volle Wörter. Die Positionsregel begrenzt den
  Schaden; die Beispiele in den Tests sind die aus echten Diktaten (`recordings`),
  nicht ausgedacht.
- **Token-Abbildung.** Wenn FluidAudio die Tokenisierung ändert, bricht die Abbildung —
  und liefert dann `[]`, nicht falsche Positionen. `TokenTimingMapTests` läuft mit
  dem echten Modell und ist der Wächter.
- **Browser als Prosa** wird bei Gmail im Tab falsch sein. Spec 03 hat das
  entschieden; die Override-Tabelle ist die Antwort für den, der Gmail nur im Browser
  liest.

## 6. Abnahme

1. „das ist gut. dann weiter" → „Das ist gut. Dann weiter"; „iPhone ist gut. macOS
   auch" unverändert.
2. „zweiundzwanzig Euro fünfzig" → „22,50 €"; „halb drei" → „2:30"; „am dritten März"
   → „am 3. März"; „ein paar Tage" unverändert; „zu zweit" unverändert.
3. „Also, ich denke, sozusagen, dass das geht" → „Ich denke, dass das geht"; „also ist
   es so" unverändert; „ich ich habe" → „ich habe"; „sehr sehr gut" unverändert.
4. Safari, Cursor und Teams werden erkannt; ein Eintrag „Safari → Chat" in der Tabelle
   gewinnt; `AppCategory.of` bekommt `overrides` aus `finishRecording`.
5. Ein 40-s-Diktat mit zwei deutlichen Pausen ergibt genau dort Absätze; ohne Pausen
   nach drei Sätzen; Whisper-Pfad unverändert.
6. `LatencyProbeTests` ±0; kein zusätzlicher `await` in `finishRecording`.

## 7. Offene Entscheidungen

- **Zwei bis zwölf als Wort** (Duden) oder ab zwei als Ziffer (Wispr-Stil, technisch
  kürzer)? Vorschlag: Duden — in einer Mail liest sich „drei Tage" besser als „3 Tage",
  und wer Ziffern will, sagt es meist im Kontext (Preise, Zeiten), den die Regeln
  ohnehin wandeln.
- **Datum als „3.3.2024"** statt „3. März 2024" als Option? Vorschlag: nein, keine
  Einstellung dafür (Spec 22 §3.4).

## 8. Stand des Baus (2026-09-14)

**Gebaut:** alle fünf Teile, mit den Vorschlägen aus §7 (zwei bis zwölf bleiben Wörter,
das Datum bleibt „3. März", keine Einstellung dafür).

- **Satzanfänge** — nach `tidy`, nur wenn `capitalizeStart` an ist.
- **`GermanITN`** — Kardinalzahlen ab dreizehn, „Komma"-Dezimalen, Prozent, Euro mit
  Cent, andere Währungen mit Wort, Uhrzeiten („halb drei", „Viertel nach acht", „um
  acht [Uhr [dreißig]]"), Datum mit Monat und Jahr, Ordinalzahl nach „am/vom/ab/bis
  (zum)". Ein großgeschriebenes Wort nach der Zahl ist ein Nomen, das sie zählt.
  Tausender von zehntausend an mit Punkt gruppiert.
- **Füllwörter mit Position** und **Stotterer**.
- **App-Tabelle** von 20 auf 70 Einträge, dazu Nutzer-Zuordnungen neben der Tabelle
  (`AppCategory.overridesKey`) und `AppCategorySection` in den Einstellungen: zeigt
  installierte eingebaute Apps und eigene Zuordnungen, fügt laufende Apps per Name und
  Symbol hinzu. Eine Zuordnung, die nur die Tabelle wiederholt, wird wieder entfernt.
- **Pausen** — `ParakeetTranscriber.transcribeDetailed` behält `tokenTimings`,
  `SpeechPauses` macht daraus eine Pause je Satzgrenze, `ParagraphFormatter` bricht an
  einer Pause oder spätestens nach drei Sätzen.

Gemessen vor dem Bau, an dieser Installation (`recordings.source_app`): Ship Studio 25,
Safari 16, die Claude-App 15, Ghostty 6 Diktate — keine der vier stand in der Tabelle.
Jetzt stehen alle vier drin.

**Abweichungen:**

1. **Satzanfänge per Scan, nicht per `NLTokenizer`.** Der Tokenizer nimmt den
   Großbuchstaben als Signal für einen Satzbeginn und liefert „gut. dann weiter" als
   *einen* Satz — genau der Fall, für den die Regel da ist. Der Scan schaut vor den
   Punkt: Ordinalzahl, Ein-Buchstaben- oder gelistete Abkürzung, oder ein Zeilenumbruch
   dazwischen lassen das Wort in Ruhe.
2. **Wiederholungsliste enger** als in §3.3: „die die", „der der", „das das" und „that
   that" sind Grammatik („Leute, die die Regeln kennen"), also nicht in der Liste.
   Bleiben: ich, wir, dass, ist; I, the, we.
3. **Ein Absatz ist schon nach einem Satz erlaubt**, wenn eine Pause folgt — eine Anrede
   mit Atempause wird so ihr eigener Absatz. Die Schwelle 0,8 s ist ein Startwert.
4. **`tidy` lässt das geschützte Leerzeichen stehen**, das die ITN zwischen „22,50" und
   „€" setzt; vorher wurde jedes Leerzeichen zu einem normalen.
5. Zwei bestehende Tests nagelten das alte Verhalten „ITN nur Englisch" fest
   (`TextPolisherTests`, `SpokenLanguagesTests`); der erste prüft jetzt das Gegenteil,
   der zweite schaltet die ITN ab, weil er Füllwörter prüft.

**Tests:** `GermanITNTests` 17, `SpeechPausesTests` 10, `PolishRulesTests` 14 (alle
neu), `AppCategoryTests` +6. **Nicht verifiziert:** die Token-Abbildung an echter
Parakeet-Ausgabe — sie ist mit synthetischen SentencePiece-Tokens getestet; weicht die
echte Ausgabe ab, liefert sie keine Pausen und der Formatter zählt wie vorher. Die
Handtests an der App stehen aus.

### Nachtrag: an echter Parakeet-Ausgabe gemessen (2026-09-14)

`SpeechPausesModelTests` (neu) spricht zwei Sätze mit 1,5 s Pause per `say` ein und
lässt sie durch Parakeet v3 laufen. Die Tokens innerhalb eines Satzes liegen lückenlos
aneinander; die gesprochene Pause von 1,5 s kommt als **0,56 s** Lücke zwischen „."
und dem nächsten Token an — der Tokenzeitstempel sitzt am Ende des Klangs, nicht am
Anfang der Stille. Die Startschwelle 0,8 s hätte also keine einzige echte Pause
erkannt. **`SpeechPauses.minimumGap` ist jetzt 0,35 s**, der Test läuft mit dem Modell
grün (übersprungen, wenn Modelle oder Stimme fehlen). Abweichung 3 gilt mit dieser
Schwelle.
