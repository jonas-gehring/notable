# Transkript-Benchmark

Misst Meeting-Notizen von Notable, wahlweise gegen einen Export von Wispr Flow aus demselben Meeting. Entstanden beim Vergleich vom 20.10.2026, aus dem `EchoFilter`, `MeetingLanguageGuard` und `OwnerVoice` kommen.

Meetingdaten liegen nie im Repo. Notizen und Exporte bleiben in einem eigenen Ordner, `pairs.json` daneben.

```sh
# Wispr-Flow-Ausschnitte (.textClipping) in Text umwandeln
python3 -I scripts/benchmark/transcript_benchmark.py decode ~/benchmark/wispr ~/Downloads/*.textClipping

# messen, vorher und nachher
python3 -I scripts/benchmark/transcript_benchmark.py measure ~/benchmark/pairs.json
```

Aufbau von `pairs.json` steht in `pairs.example.json`. `owner` ist der Name, unter dem Wispr einen selbst führt.

## Was gemessen wird

| Wert | Bedeutung |
| --- | --- |
| echo | Wörter in Segmenten, die zum größten Teil ein benachbartes Segment eines anderen Sprechers wiederholen |
| strays | kurze Segmente (bis 6 Wörter) in der anderen Sprache als der des Meetings, nur bei deutschen Meetings |
| ich | Anteil der Wörter unter „Ich", die Wispr der eigenen Person zuordnet |
| fehlt | Inhalt, der in der anderen Quelle nicht vorkommt (Wortdreier, unter 20 % Überdeckung) |

Der Wert links vom Pfeil ist die Notiz, wie sie ist. Rechts steht dieselbe Notiz nach dem Textteil der Bereinigung, die `MeetingPipeline` seit dem 21.10.2026 macht. Die Wiederholung arbeitet mit der Reihenfolge der Segmente, die App mit Zeiten. Das ist nah dran, aber nicht gleich. Das Diarisieren des Mikrofons hängt am Audio und lässt sich hier nicht nachstellen, dafür gibt es `MeetingReplayTests`.

Die Regeln sind aus den Swift-Quellen abgeschrieben. Wer dort eine Schwelle ändert, ändert sie hier mit.

## Stand 21.10.2026 (16 Notizen, 6 davon mit Wispr-Export)

| | vorher | nachher |
| --- | --- | --- |
| echo | 0 bis 68 % | 0 bis 1 % |
| ich (6 Paare) | 26 bis 72 % | 36 bis 97 % |
| strays | 0 bis 4 % | 0 % |

Bei 36 % bleibt es im einen Meeting, das nur über das Mikrofon lief. Das löst erst das Diarisieren der Mikrofonspur. Von allen Sätzen, die der Echo-Filter gestrichen hat, waren 99 % laut Wispr wirklich von der Gegenseite.

## Engines vergleichen: Messlauf übers Archiv

`MeetingPipelineReplayTests` schickt archivierte Meetings ein zweites Mal durch die ganze Pipeline, wie sie heute ist, mit der Engine aus der Umgebung. Jede Notiz landet als Markdown in `~/Library/Application Support/Notable/replay/<engine>/<Sitzung>.md`, im Format, das `measure` liest. Ausgegeben werden nur Zahlen: Dauer, Rechenzeit, Wörter, Anteil „Ich", Stimmen, Echo und was die Bereinigung gemacht hat.

```sh
DD="$TMPDIR/notable"
# Parakeet v3, wie die App heute
TEST_RUNNER_NOTABLE_REPLAY=1 TEST_RUNNER_NOTABLE_REPLAY_SESSIONS=1C65,B6 \
  xcodebuild -project Notable.xcodeproj -scheme Notable -derivedDataPath "$DD" test \
  -only-testing:NotableTests/MeetingPipelineReplayTests/testReplayWholeMeetings

# dieselben Meetings mit Whisper large-v3-turbo, auf Deutsch festgelegt
TEST_RUNNER_NOTABLE_REPLAY=1 TEST_RUNNER_NOTABLE_REPLAY_SESSIONS=1C65,B6 \
TEST_RUNNER_NOTABLE_REPLAY_ENGINE=whisper:large-v3-v20240930_turbo TEST_RUNNER_NOTABLE_REPLAY_LANGUAGES=de \
  xcodebuild -project Notable.xcodeproj -scheme Notable -derivedDataPath "$DD" test \
  -only-testing:NotableTests/MeetingPipelineReplayTests/testReplayWholeMeetings
```

Danach in `pairs.json` dieselbe Wispr-Datei einmal gegen jede Engine eintragen und `measure` laufen lassen. Entscheidend ist `fehlt`: wie viel von Wisprs Inhalt in der Notiz nicht vorkommt. Der Whisper-Download (gut ein Gigabyte) passiert beim ersten Lauf, in denselben Ordner, den die App benutzt.

Die Notizen enthalten die vollen Transkripte. Den Ordner `replay` nach der Messung löschen.

