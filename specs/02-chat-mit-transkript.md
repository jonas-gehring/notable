# Spec 02 — Chat mit Transkript

> **Aufwand: M–L.** Freie Fragen an ein aufgezeichnetes Meeting.
> Baut vollständig auf vorhandener Infrastruktur auf: `SummarizationProvider.complete(system:user:)`
> existiert bereits (`SummarizationProvider.swift:73`), das Transkript liegt in SQLite,
> das Notiz-Fenster (`NoteListView`/`NoteManager`) ist der natürliche Ort.

## 1. Ziel

Im Notiz-Fenster eines Meetings ein **Chat-Panel**, in dem der Nutzer frei Fragen zum
Meeting stellt: „Was waren meine Action Items?", „Was hat Sprecher 2 zum Budget gesagt?",
„Fasse die letzten 10 Minuten zusammen." Antworten kommen vom **gewählten
Summarization-Provider** (Anthropic API oder Claude Code CLI) — dieselbe Datenschutz-Haltung
wie die Summary: **nur Transkript-Text verlässt das Gerät, nie Audio.**

Heute gibt es genau zwei LLM-Roundtrips: One-Shot-Summary und Sprecher-Benennung. Chat ist
der dritte, interaktive.

## 2. Umfang v2

- Freitext-Fragen zu **einem** Meeting (dem im Fenster geöffneten).
- Mehrere Nachrichten mit **Gesprächsverlauf** (Folgefragen im Kontext).
- Antworten **zitieren, wo möglich, den Sprecher/Zeitbereich** („laut Sprecher 2 gegen
  Minute 12 …") — der Prompt fordert das ein, keine harte Zitat-Verifikation wie beim
  Sprecher-Resolver.
- Verlauf wird **persistiert** (SQLite), übersteht Fenster-Schließen/Neustart.
- **Nicht** in v2: Chat über mehrere Meetings hinweg, Chat über Diktate, RAG/Embeddings
  (Volltext reicht, siehe §4), Streaming-Rendering (optional später).

## 3. Datenmodell & Migration

Neue Tabelle (idempotent in `ensureOpen()` via `CREATE TABLE IF NOT EXISTS`):

```sql
CREATE TABLE IF NOT EXISTS chat_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    recording_id TEXT NOT NULL REFERENCES recordings(id),
    role TEXT NOT NULL,          -- 'user' | 'assistant'
    text TEXT NOT NULL,
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chat_recording ON chat_messages(recording_id);
```

`RecordingStore`-Methoden (Actor, Muster wie `segments`/`insert`):

```swift
func chatMessages(for recordingID: String) throws -> [ChatMessage]
func appendChatMessage(_ m: ChatMessage, for recordingID: String) throws
func clearChat(for recordingID: String) throws     // „Verlauf löschen"
```

`ChatMessage`: `{ id, role: Role, text, createdAt }`, `Sendable`, `Identifiable`.

Chat wird **nicht** in die Markdown-Projektion geschrieben (die `.md` bleibt Notiz +
Summary + Transkript). Chat ist Arbeitsmaterial, lebt nur in SQLite. Falls später
gewünscht: optionaler Abschnitt „## Fragen & Antworten" — jetzt bewusst nicht.

## 4. Kontext-Aufbau (der Kern)

### 4.1 Transkript in den Prompt
Das ganze Meeting-Transkript geht als Kontext in jede Frage. Bei `claude-sonnet-5`
(200k Kontext) passt ein 1–2-h-Meeting locker (grob: 1 h ≈ 8–12k Tokens). Also **v2:
ganzes Transkript, kein Retrieval.** Das ist die ehrliche, einfache Lösung.

**Guard:** Wenn das Transkript einen Schwellwert überschreitet (z. B. > ~120k Tokens,
grob per Zeichenzahl/4 geschätzt), fällt der Kontext auf ein **Fenster um relevante
Segmente** zurück:

- Kandidaten-Segmente per bestehender `RecordingStore.search`-Substring-Logik gegen die
  Frage-Stichwörter ziehen, plus deren Nachbarsegmente, plus die Summary als Übersicht.
- Das ist der einzige Fall, in dem RRF/Embeddings je nötig würden — für Personal-Meetings
  praktisch nie. Als klar markierter Fallback dokumentiert, nicht als Default gebaut.

### 4.2 Prompt-Form
Über `provider.complete(system:user:)`. `system`:

```
Du beantwortest Fragen zu EINEM Meeting ausschließlich auf Basis des mitgelieferten
Transkripts (und der eigenen Notizen des Nutzers, falls vorhanden). Antworte auf Deutsch,
knapp und präzise. Wenn die Antwort nicht im Transkript steht, sage das klar statt zu raten.
Nenne, wenn hilfreich, Sprecher ("Ich", "Sprecher n") und ungefähre Stelle. Erfinde nichts.
```

`user` = Meeting-Kontext-Header (Titel/Datum wie in `SummarizationPrompt.user`) +
Transkript + eigene Notizen + der **bisherige Chatverlauf** + die neue Frage. Verlauf wird
als abwechselnde „Frage:/Antwort:"-Blöcke eingebettet (die `complete`-API ist ein einzelner
system+user-Roundtrip, kein natives Multi-Turn — Verlauf also in den user-Text serialisieren).

Prompt-Aufbau in eine **pure** `ChatPrompt`-Funktion (analog `SummarizationPrompt`), damit
Kontext-Fenster-Logik und Serialisierung getestet werden können.

### 4.3 Kosten/Latenz
- Anthropic-API: jeder Turn schickt das ganze Transkript erneut (kein Prompt-Caching-Prefix
  über Turns hinweg in v1 vorgesehen). Kosten pro Frage ≈ Summary-Kosten (~$0.02–0.05),
  irrelevant für Personal-Tool. **Optional-Optimierung:** Prompt-Caching auf den
  Transkript-Block (er ist über die Turns eines Chats stabil) — spart Kosten/Latenz bei
  Folgefragen. Nice-to-have, nicht Pflicht.
- CLI-Provider: ein `claude -p`-Aufruf pro Frage; Latenz ist ok (interaktiv wartet der
  Nutzer bewusst auf eine Antwort).

## 5. UI

Im **Notiz-Fenster** (`NoteListView` → Detailbereich eines Meetings) ein Chat-Bereich,
umschaltbar mit der Notiz-/Summary-Ansicht (Tab oder aufklappbares Panel rechts):

- Nachrichtenliste (User rechts, Assistant links, bewusst schlicht), `textSelection.enabled`.
- Eingabefeld unten + Senden (⌘↩), „Denkt nach…"-Zustand während des Roundtrips.
- **Fehler sichtbar**, nie stiller No-op: fehlender API-Key/CLI → dieselbe „Provider nicht
  verfügbar"-Meldung, die die Summary schon nutzt, mit Verweis auf Settings.
- „Verlauf löschen" (räumt `chat_messages` des Meetings).
- Optional: 3–4 **Vorschlags-Chips** („Action Items?", „Entscheidungen?", „Offene Fragen?")
  als Ein-Klick-Fragen — senkt die Einstiegshürde.

Ein `MeetingChatController` (`@MainActor ObservableObject`) hält den Verlauf einer offenen
Notiz, ruft `SummarizationService`/Provider, schreibt in `RecordingStore`. Muster wie
`MeetingController`.

## 6. Edge Cases

- **Kein Transkript / leeres Meeting:** Chat deaktiviert mit Hinweis.
- **Provider wechselt** mitten im Chat: nächster Turn nutzt den neuen Provider; Verlauf
  bleibt (Text ist providerneutral).
- **Sehr lange Antwort / `max_tokens`:** `stop_reason` prüfen (die Provider tun das schon)
  und „Antwort gekürzt"-Hinweis.
- **Refusal:** `stop_reason == refusal` sichtbar melden statt leer.
- **Paralleler Roundtrip:** Senden während „Denkt nach…" sperren (ein Turn zur Zeit pro
  Fenster).
- **Rennen mit Re-Summarize:** Chat liest Transkript/Notizen; wenn parallel neu
  zusammengefasst wird, ist das unkritisch (Transkript-Segmente ändern sich nicht).

## 7. Tests

- `ChatPrompt` (pur): Verlaufs-Serialisierung; Kontext-Fenster-Fallback greift oberhalb
  der Schwelle und wählt die richtigen Segmente; Notizen werden eingebettet.
- `RecordingStore` (temp-DB): append/read/clear von `chat_messages`, Reihenfolge nach
  `created_at`, Fremdschlüssel auf `recordings`.
- Kein echter LLM-Test nötig (Provider sind separat getestet); ein `MeetingChatController`-Test
  mit einem Fake-`SummarizationProvider` prüft den State-Flow (senden → pending → append).

## 8. Umsetzungsschritte

1. `chat_messages`-Tabelle + `RecordingStore`-Methoden + Test.
2. `ChatPrompt` (pur) + Test.
3. `MeetingChatController` + Fake-Provider-Test.
4. Chat-UI im Notiz-Fenster (Liste, Eingabe, Zustände, Fehler).
5. Vorschlags-Chips, „Verlauf löschen".
6. Optional: Prompt-Caching des Transkript-Blocks; Streaming-Rendering.

## 9. Nicht-Ziele

- Kein cross-Meeting-Chat, kein globaler „Frag deine Notizen"-Assistent (späterer,
  größerer Schritt — bräuchte echtes Retrieval/Embeddings).
- Kein Diktat-Chat.
- Keine Audio-Wiedergabe an zitierten Stellen (wir behalten Meeting-Audio, aber das ist
  ein separates Feature).
