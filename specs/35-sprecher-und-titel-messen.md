# Spec 35 — Sprechernamen und Titel: erst messen

> **Aufwand: S (1 Tag).** Der Owner meldet auf beiden Macs: keine Sprechernamen, Titel
> nur „Meeting". Die Daten dieses Macs zeigen fünf verschiedene stille Ausgänge, von
> denen keiner eine Spur hinterlässt. Diese Spec baut die Spur und zwei Fixes, die
> ohne Messung sicher sind — und ausdrücklich **keine** Lockerung der Benennungsregeln
> („lieber anonym als falsch" bleibt).

## 1. Ausgangslage (gemessen, 2026-09-15, 18 Meetings 03.08.–10.09.)

- **Namen:** 1 von 23 fremden Labels trägt einen richtigen Namen, 3 tragen den eigenen
  Namen des Owners (vor dem Schutz aus Spec 24). `llm_usage` hat **keine** Zeile für
  die Sprecherbenennung; das Unified Log für das Subsystem ist leer.
- **Ursachen, soweit belegbar:** 8 Meetings mit stummer Mikrofonspur (Deckel zu,
  Spec 23 — Benennung absichtlich übersprungen); `CallScreenAdapters.all` leer
  (Spec 24, Stufe 0 fehlt); Kalender liefert keine Teilnehmernamen; Anbieterfehler
  enden in `[:]` ohne Log; `NSFullUserName()` ist „Jonas" — „Herr Gehring" gilt
  nicht als eigener Name.
- **Titel:** 13 von 18 Meetings fanden **keinen** Kalendertermin; alle Treffer kamen
  aus drei Kalendern, fast nur Bewerbungsgespräche. Ob der Arbeitskalender überhaupt
  in EventKit ist, weiß niemand (auch der Owner nicht). „Meeting" entsteht, wenn kein
  Termin passt *und* keine Zusammenfassung einen Titel liefert. Der Kalender wird nur
  beim Start gefragt.
- Kein Meeting auf diesem Mac lief mit 1.2.0 oder neuer; ob Spec 23/24 die Fälle schon
  schließen, ist unbelegt.

## 2. Ziel

Das nächste echte Meeting sagt, warum es keinen Namen und welchen Titel es bekam. Dazu
nur, was ohne Messung sicher richtig ist.

## 3. Konzept

### 3.1 Die Spur: `NoteDiagnosis` (pur)

Ein Code je Frage, in `meta.json` (`naming`, `titleSource`) und im Log:

- **Namen:** `keinTranskript`, `keineGegenseite`, `mikrofonStumm`, `ausgeschaltet`,
  `nichtVersucht`, `anbieterFehler: …`, `modellOhneNamen (n offen)`,
  `verworfen: n vorgeschlagen, 0 übernommen`, `benannt: n von m`.
- **Titel:** `kalender`, `kalenderBeimStopp`, `modell`, sonst
  `callQuelle|fallback: keinKalenderzugriff|keinPassenderTermin,
  keinTranskript|zusammenfassungFehlgeschlagen|modellOhneTitel`.

`SpeakerNameResolver.resolveDetailed` liefert dafür ein `Outcome` (Ergebnis, Zahl
vorgeschlagener und übernommener Namen); `resolve` bleibt als Hülle.

### 3.2 Sichere Fixes

1. **„Dein vollständiger Name"** (Einstellungen → Meetings → Sprecher,
   `DefaultsKey.ownerName`): `ownerNameTokens` = Accountname ∪ dieser Name.
2. **Kalenderliste** (Einstellungen → Meetings → Kalender): jeder Kalender, den
   EventKit liefert, mit Konto und heutigen Terminen; ohne Zugriff ein Satz, warum
   nichts zugeordnet wird. Beantwortet „ist der Arbeitskalender da?".
3. **Titel ohne Termin:** statt „Meeting" die erkannte Call-Quelle mit Uhrzeit
   („Microsoft Teams · 10:03", aus Spec 34 `callSource`) — bis das Modell einen Titel
   liefert. Ohne Call-Quelle bleibt „Meeting".
4. **Kalender auch beim Stopp:** fand der Start nichts, wird für die Mitte der
   Aufnahme noch einmal gefragt (Termin, der mehr als 5 min nach Aufnahmebeginn
   anfing).

## 4. Nicht Teil dieser Spec

- Namen ohne wörtliche Nennung vergeben — entscheidet die Messung.
- Adapter für Teams/Zoom/Meet — hängen weiter an Spec 24 Stufe 0 im echten Call.

## 5. Abnahme

1. `NoteDiagnosisNamingTests`, `NoteDiagnosisTitleTests`, `OwnerNameTests` grün.
2. Nächstes echtes Meeting mit 1.3.1: `meta.json` im Archiv trägt `naming` und
   `titleSource`; das Log hat „Sprecherbenennung: …" und „Titel: …".
3. Einstellungen → Meetings zeigt die Kalender; der Owner weiß, ob der
   Arbeitskalender dabei ist.

## 6. Stand des Baus (2026-09-15)

Gebaut wie beschrieben; Abnahme 2 und 3 brauchen ein echtes Meeting bzw. einen Blick
in die Einstellungen.
