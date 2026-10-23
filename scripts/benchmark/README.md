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
