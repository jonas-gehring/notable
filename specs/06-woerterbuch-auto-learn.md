# Spec 06 — Wörterbuch-Auto-Learn

> **Aufwand: S.** Notable lernt wiederkehrende Fehlerkennungen und schlägt Korrekturen vor. Das Rechen-/Speichergerüst existiert bereits und ist getestet-fähig; es
> fehlt (a) eine **Erfassung** von Korrekturen und (b) die **UI**, die Vorschläge zeigt.

## 1. Ausgangslage (Fakten aus dem Code)

In `TextPolisher.swift:116–157` liegt `enum PersonalDictionary` mit:

- `recordCorrection(heard:corrected:)` — zählt beobachtete Korrekturen in einem separaten
  UserDefaults-Key `personalDictionaryLearned` als `[heard: [corrected: count]]`.
- `learnedSuggestions(minCount:)` — liefert je „heard" die häufigste „corrected"-Form ab
  `minCount` Beobachtungen.

Der Doc-Kommentar ist explizit: **record-only, nie automatisch angewandt** — „a wrong
auto-correction is worse than none, so promotion stays a manual, deliberate act."
`recordCorrection` wird **nirgends aufgerufen**, `learnedSuggestions` **nirgends angezeigt**.

Diese Spec respektiert diese Grundhaltung: **Wir bauen Vorschläge, keine stille
Auto-Korrektur.** Der Nutzer promotet einen Vorschlag mit einem Klick ins aktive Wörterbuch.

## 2. Ziel

1. **Korrekturen erfassen**, damit `recordCorrection` überhaupt Daten bekommt.
2. In Settings → „Persönliches Wörterbuch" einen Abschnitt **„Vorschläge"**, der
   `learnedSuggestions` zeigt: „›Hofmann‹ → ›Hoffmann‹ (3×) — Übernehmen / Verwerfen".
3. Übernehmen schreibt den Eintrag ins aktive Wörterbuch (`PersonalDictionary.save`) und
   entfernt ihn aus den gelernten Kandidaten.

## 3. Der Knackpunkt: Korrekturen erfassen

Woher weiß Notable, dass „Hofmann" eigentlich „Hoffmann" heißen sollte? Drei Quellen, nach
Zuverlässigkeit geordnet. **v2 baut Quelle A (sicher), optional B; C ist bewusst out of scope.**

### Quelle A — explizite Korrektur in „Letzte Diktate" (empfohlen, verlässlich)
Im Fenster **„Letzte Diktate"** (`RecentDictationsView`) und/oder im Menü-Untermenü bekommt
jedes Diktat eine Aktion **„Korrigieren…"**: Der Nutzer sieht den Diktattext, bearbeitet
ihn, speichert. Ein **wortweiser Diff** (alt → neu) füttert `recordCorrection` für jedes
geänderte Wortpaar.

- Diff pur & getestet: Token-Alignment (einfaches LCS auf Wortebene), nur **Substitutionen**
  einzelner Wörter zählen (nicht Einfügungen/Löschungen — die sind keine „heard→corrected"-
  Paare). Beispiel: „danke Hofmann" → „danke Hoffmann" ergibt genau `recordCorrection("Hofmann",
  "Hoffmann")`.
- Das ist der ehrliche Weg: der Nutzer *sagt uns*, was falsch war, ohne Bundle-übergreifende
  Beobachtung.

### Quelle B — Re-Diktat-Heuristik (optional, vorsichtig)
Wenn der Nutzer **kurz nach** einem Diktat ein sehr ähnliches, kurzes Diktat macht (typisch:
er wiederholt ein falsch erkanntes Wort), *könnte* das eine Korrektur sein. Sehr
fehleranfällig → in v2 **nicht** automatisch zählen; höchstens als „War das eine Korrektur
von X?"-Rückfrage. Standardmäßig aus. Nur dokumentiert, damit klar ist, warum wir es *nicht*
tun.

### Quelle C — AX-Beobachtung eingefügten Texts (bewusst out of scope)
Fremd-App-Textänderungen nach dem Einfügen mitlesen wäre der „magische" Weg, ist aber
fragil (Electron/Web, Autocorrect der Ziel-App, Fokuswechsel) und datenschutzintensiv
(Notable läse fortlaufend fremde Textfelder). **Nicht in v2.**

## 4. Datenmodell

Keine neue SQLite-Tabelle nötig — die gelernten Kandidaten leben schon in UserDefaults
(`personalDictionaryLearned`). Optional, wenn wir mehr Kontext wollen (wann/wie oft, aus
welchem Diktat), eine kleine Tabelle `dictionary_candidates(heard, corrected, count,
last_seen)`; für v2 reicht der bestehende UserDefaults-Store. **Default: bestehenden Store
nutzen**, kein Schema-Change.

`PersonalDictionary` um zwei kleine Helfer ergänzen (das Muster ist schon da):

```swift
/// Promote a learned suggestion into the active dictionary and forget the candidate.
static func promote(heard: String, corrected: String, store: UserDefaults = .standard)
/// Drop a candidate the user rejected, so it stops being suggested.
static func dismiss(heard: String, store: UserDefaults = .standard)
```

## 5. UI

Settings → Diktat → „Persönliches Wörterbuch" (die Sektion existiert,
`SettingsView.swift:151–195`), darunter ein neuer Block **„Gelernte Vorschläge"**:

- Liste aus `learnedSuggestions(minCount: 2)`: „heard → corrected (n×)".
- Pro Zeile **Übernehmen** (`promote`, fügt in die Tabelle darüber ein) und **Verwerfen**
  (`dismiss`).
- Leerzustand: „Noch keine Vorschläge. Korrigiere ein Diktat unter ›Letzte Diktate‹, um
  Notable beizubringen, was es falsch hört."
- Ein `minCount`-Default von 2 verhindert, dass ein einmaliger Vertipper zum Vorschlag wird.

Im **„Letzte Diktate"**-Fenster: pro Eintrag „Korrigieren…" → editierbares Feld → beim
Speichern Wort-Diff → `recordCorrection`. (Der korrigierte Text wird **nicht** rückwirkend
neu eingefügt — er ist längst in der Ziel-App; die Korrektur dient nur dem Lernen. Ehrlich
kommunizieren.)

## 6. Edge Cases

- **Groß/Kleinschreibung:** `recordCorrection` ignoriert Paare, die sich nur in der
  Schreibung unterscheiden (`caseInsensitiveCompare`), bewusst — das aktive Wörterbuch matcht
  ohnehin case-insensitiv.
- **Mehrere Korrekturen desselben Worts:** häufigste gewinnt (`learnedSuggestions` nimmt
  `max`).
- **Promotete Einträge:** aus Kandidaten entfernen, sonst tauchen sie erneut auf.
- **Verworfene Einträge:** merken (nicht nur count 0), sonst kommen sie beim nächsten
  Vorkommen sofort wieder. `dismiss` setzt einen Tombstone (z. B. count auf −1 oder separater
  Ignore-Set).
- **Wort-Diff-Rauschen:** nur 1:1-Substitutionen mit ähnlicher Länge/Position zählen; große
  Umbauten ignorieren (kein „heard→corrected" ableitbar).

## 7. Tests

- Wort-Diff (pur): „a Hofmann b" → „a Hoffmann b" ⇒ genau ein Paar; Einfügung/Löschung ⇒ kein
  Paar; mehrere Substitutionen ⇒ mehrere Paare.
- `recordCorrection`/`learnedSuggestions` sind schon testbar (injizierbarer `UserDefaults`):
  Tally über mehrere Aufrufe; `minCount`-Schwelle; häufigste Form gewinnt.
- `promote`/`dismiss`: Kandidat wandert ins aktive Dict bzw. verschwindet und kommt nicht
  wieder (Tombstone).

## 8. Umsetzungsschritte

1. `promote`/`dismiss` + Tombstone in `PersonalDictionary` + Tests.
2. Wort-Diff (pur) + Tests.
3. „Korrigieren…" in `RecentDictationsView` → Diff → `recordCorrection`.
4. „Gelernte Vorschläge"-Block in den Wörterbuch-Settings (Liste + Übernehmen/Verwerfen).

## 9. Nicht-Ziele

- **Keine automatische Anwendung** gelernter Korrekturen — die Kern-Designentscheidung
  bleibt: Promotion ist ein bewusster Klick.
- Keine AX-Beobachtung fremden Texts (Quelle C).
- Keine Re-Diktat-Auto-Erfassung als Default (Quelle B bleibt aus).
