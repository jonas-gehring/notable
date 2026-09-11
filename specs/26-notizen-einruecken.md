# Spec 26 — Einrücken und Ausrücken in Notizen

> **Aufwand: Stufe 1 = S–M (1,5–2 Tage), Stufe 2 = S.** Listen in den Live-Notizen
> sollen verschachtelt werden können — Tab / ⇧Tab und ⌘] / ⌘[, wie in Apple Notes.
> Das Risiko ist nicht die Taste, sondern der Round-Trip: der Puffer ist Markdown, geht
> wörtlich an das Modell, und jede Drift schreibt still Notizen um, die die
> Zusammenfassung als Tatsache behandelt.

## 1. Ausgangslage (Fakten aus dem Code)

- **Das Modell ist absichtlich flach.** `NotesBlock` hat keine Ebene; der Kommentar
  sagt „no nesting" (`NotesMarkdown.swift:5-8`). `NotesLine` ist Block + Text.
- **Nummerierung wird bei jeder Nicht-Nummern-Zeile zurückgesetzt**
  (`NotesMarkdown.swift:107-113`). Mit Verschachtelung wäre das falsch: ein
  eingerückter Unterpunkt zwischen „1." und „2." darf die äußere Zählung nicht
  neu starten.
- **Die sichtbare Markierung ist die Wahrheit.** `NotesRichText` erkennt Listen an
  „•\t", „☐\t", „1.\t" am Absatzanfang (`NotesRichText.swift:123-129`); nur Überschriften
  tragen ein verstecktes Attribut. Die Absatzformatierung hat einen festen Einzug von
  18 pt (`:47-54`).
- **Tab ist heute ein Datenfehler.** `doCommandBy` behandelt nur Return und Backspace
  (`LiveNotesView.swift:446-456`); Tab fällt an `NSTextView` durch und fügt ein „\t"
  ein. Am Anfang eines Aufzählungspunkts wird aus „•\tText" dann „\t•\tText" — das
  erkennt `line(from:)` nicht mehr als Liste, die Zeile wird zu Fließtext **mit einem
  wörtlichen „•" im Text**, und genau so steht sie danach im Markdown und in der
  Zusammenfassung. Sieht eingerückt aus, ist kaputt.
- **Es gibt einen zweiten Editor.** Im Notizen-Fenster bearbeitet ein SwiftUI-
  `TextEditor` die „Eigenen Notizen" als **rohes Markdown** (`NoteListView.swift:181`).
  Dort sieht man `- ` und `## `, und Tab fügt ein Tabulatorzeichen ins Markdown ein —
  das CommonMark als vier Leerzeichen liest, also als Codeblock.
- Nachgelagert: `## Eigene Notizen` im Markdown (wörtlich), Zusammenfassung (als
  Grundwahrheit), Chat. Kein Schema in SQLite betroffen.

## 2. Ziel

Listenpunkte lassen sich per Tastatur und Knopf ein- und ausrücken, sechs Ebenen tief.
Das Markdown sind **normale verschachtelte Listen**, die jeder Markdown-Leser (Obsidian,
GitHub, das Modell) als solche liest. `serialize(parse(x))` bleibt idempotent,
`parse(serialize(lines))` bleibt gleich der normalisierten Eingabe.

## 3. Konzept

### 3.1 Modell

- `NotesLine.indent: Int` (0…5). **Nur Listenpunkte** (Aufzählung, Nummer, Checkbox)
  haben eine Ebene. Fließtext und Überschriften sind immer 0 — vier Leerzeichen vor
  einem Absatz sind in Markdown ein Codeblock, und das würde für das Modell und für
  Obsidian die Bedeutung ändern.
- **Normalisierung** (ein Ort, pure, von `parse` *und* allen Editieroperationen
  benutzt):
  - der erste Listenpunkt nach Fließtext/Überschrift/Anfang hat Ebene 0;
  - ein Listenpunkt ist höchstens eine Ebene tiefer als der vorige Listenpunkt.

  Markdown kann einen Sprung um zwei Ebenen ohne Zwischenstufe gar nicht ausdrücken;
  die Regel macht das Modell genau so ausdrucksstark wie das Format, und damit wird der
  Round-Trip total.

### 3.2 Markdown-Format

- **Kind-Einzug = Inhaltsspalte des Elternteils** (CommonMark): unter `- ` zwei
  Leerzeichen, unter `1. ` drei, unter `10. ` vier, unter `- [ ] ` zwei (die
  Listenmarke ist `- `). `serialize` berechnet die Spalte aus dem **tatsächlichen**
  Präfix des Elternteils — keine feste Breite, die bei zweistelligen Nummern falsch
  wird.
- **`parse`** liest führende Leerzeichen (ein Tab zählt als vier Spalten) und bestimmt
  die Ebene über einen Stapel offener Elternteile und ihrer Inhaltsspalten; danach
  Normalisierung. Alles Unerkannte bleibt Fließtext mit unverändertem Text — es gibt
  weiterhin keine ungültige Eingabe.
- **Nummerierung je Ebene:** Zähler pro Ebene; ein flacherer Punkt setzt alle tieferen
  Zähler zurück, ein tieferer lässt die flacheren stehen. Also:

  ```markdown
  1. Budget
     - offen: Q4
  2. Personal
     1. Recruiting
     2. Onboarding
  3. Termine
  ```

### 3.3 Darstellung: die Ebene ist sichtbarer Text

Eingerückt wird mit **führenden Tabs vor der Marke**: Ebene 2 ist „\t\t•\tText". Damit
bleibt die Regel aus `NotesRichText` unangetastet — *der sichtbare Text ist die
Wahrheit, versteckt ist nur die Überschriftenebene*. Wer den führenden Tab löscht,
rückt aus, genau wie das Löschen der Marke die Liste auflöst. Ein verstecktes
Ebenen-Attribut wäre der zweite versteckte Zustand, und damit genau die Sorte, die
auseinanderläuft.

- Absatzstil je Ebene *n*: Tabstopps bei 18 pt · 1…n+1, `firstLineHeadIndent = 0`,
  `headIndent = 18 · (n+1)`. Umbrochene Zeilen stehen unter dem Text, nicht unter der
  Marke.
- `line(from:)` zählt und entfernt führende Tabs, dann die Marke. **Das repariert den
  Fehler aus §1 nebenbei:** „\t•\tText" ist ab jetzt ein Punkt auf Ebene 1.
- `markerLength` schließt die führenden Tabs ein; `position`/`utf16Offset` bleiben
  exakte Inverse (bestehende Tests + neue mit Ebenen, Emoji und Umlauten).
- Der Checkbox-Klick in `NotesTextView.mouseDown` (`LiveNotesView.swift:350`) prüft
  heute `hasPrefix("☐\t")` und muss die Tabs überspringen — über eine Hilfsfunktion in
  `NotesRichText` statt einer zweiten Kopie der Regel.

### 3.4 Editieroperationen (pure, in `NotesMarkdown`)

- `indenting(_:in:)` / `outdenting(_:in:)`: auf alle **Listenpunkte** der Auswahl,
  Fließtext in der Auswahl bleibt unberührt; danach Normalisierung.
- **Kinder wandern nicht mit** (wie Apple Notes und Google Docs): betroffen ist nur die
  Auswahl. Wer einen Elternpunkt ausrückt, dessen Kinder auf Ebene 2 lagen, findet sie
  danach — durch die Normalisierung — auf Ebene 1. Deterministisch und getestet.
- `applying(block)`: Liste → Liste behält die Ebene; → Fließtext/Überschrift setzt
  sie auf 0.
- `continuation` behält die Ebene.

### 3.5 Tasten (in `NotesTextEditor.Coordinator.doCommandBy` und der Formatleiste)

| Eingabe | Listenpunkt | Fließtext |
|---|---|---|
| Tab (`insertTab:`) — egal wo in der Zeile | einrücken | Standard (Tabzeichen) |
| ⇧Tab (`insertBacktab:`) | ausrücken; auf Ebene 0 nichts | nichts |
| ⌘] / ⌘[ | ein-/ausrücken | nichts |
| Return auf **leerem** Punkt, Ebene > 0 | eine Ebene ausrücken | — |
| Return auf leerem Punkt, Ebene 0 | Liste verlassen (wie heute) | — |
| Backspace in Spalte 0, Ebene > 0 | eine Ebene ausrücken | — |
| Backspace in Spalte 0, Ebene 0 | Format entfernen (wie heute) | — |

⌘] / ⌘[ laufen über versteckte Knöpfe wie die bestehenden ⌘⌥1–6
(`LiveNotesView.swift:127-138`); dazu zwei Knöpfe in der Formatleiste
(`decrease.indent`, `increase.indent`) und der Hinweis in der Fußzeile.

### 3.6 Stufe 2 — ein Editor statt zwei

`NotesTextEditor` + `NotesEditorProxy` wandern aus `LiveNotesView.swift` in eine eigene
Datei und ersetzen den `TextEditor` im Notizen-Fenster. Dann gibt es nachträglich
dieselbe Darstellung und dieselbe Verschachtelung, und der Weg, auf dem ein Tab als
Codeblock ins Markdown gelangt, ist zu. (Gleiches Muster wie Spec 22: eine
Implementierung je Begriff.)

## 4. Integration

- **`NotesMarkdown`** — `indent`, Normalisierung, Parse/Serialize mit Spalten,
  Zählung je Ebene, `indenting`/`outdenting`.
- **`NotesRichText`** — führende Tabs, Absatzstil je Ebene, `markerLength`, Hilfe für
  den Checkbox-Treffer.
- **`LiveNotesView`** — Proxy-Methoden, `insertTab:`/`insertBacktab:`, Return/Backspace
  mit Ebene, Knöpfe, Kurzbefehle.
- **`NoteListView`** — Stufe 2.
- **`en.lproj`** — „Einrücken (⌘])", „Ausrücken (⌘[)", Fußzeilen-Hinweis
  (`LocalizationTests` fällt sonst).

## 5. Risiken

- **Drift im Round-Trip** — das eine Risiko, auf das es ankommt. Neben den
  Beispiel-Tests ein **Eigenschaftstest**: 10 000 zufällige Zeilenfolgen (alle Blöcke,
  Ebenen 0–5, leere Zeilen, Emoji) → `serialize` → `parse` → gleich der normalisierten
  Eingabe; `serialize(parse(serialize(x))) == serialize(x)`.
- **Bestandspuffer werden anders gelesen**, wo eine Zeile mit Leerzeichen vor `- `
  beginnt: heute Fließtext, künftig ein verschachtelter Punkt. Betrifft nur Text, der
  bereits wie eine verschachtelte Liste aussieht — also genau das, was gemeint war.
  Ebenso „\t•\t…"-Zeilen aus dem Tab-Fehler: sie werden zu richtigen Unterpunkten.
- **Caret nach Formatänderung.** Jede Operation rendert neu (`render(…)`); Absatz und
  Spalte sind so definiert, dass sie das überleben — mit führenden Tabs muss die
  Spalte weiterhin *nach* der Marke zählen. Getestet.

## 6. Abnahme

- Tab auf einem Aufzählungspunkt rückt ein, ⇧Tab rückt aus; das Markdown ist
  `- a\n  - b`, und Obsidian zeigt eine verschachtelte Liste.
- Tab auf einem Punkt erzeugt **nie** mehr Fließtext mit einem „•" im Text.
- Nummerierte Liste mit Unterpunkten zählt wie im Beispiel in 3.2.
- Leerer Unterpunkt + Return rückt aus; zweites Return verlässt die Liste.
- Round-Trip-Eigenschaftstest grün; alle bestehenden `NotesMarkdownTests` und
  `NotesRichTextTests` unverändert grün.
- Ein Spool mit verschachtelten `notes.md` wird nach einem Absturz wörtlich
  wiederhergestellt.
