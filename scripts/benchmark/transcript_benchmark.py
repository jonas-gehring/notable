#!/usr/bin/env python3
"""Measures Notable meeting notes, optionally against a Wispr Flow export of
the same meeting.

    python3 -I scripts/benchmark/transcript_benchmark.py decode <outdir> <file.textClipping>...
    python3 -I scripts/benchmark/transcript_benchmark.py measure <pairs.json>

`measure` reads a JSON object: name -> {"notable": "<note.md>", "wispr": "<export.txt>" or null,
"owner": "<the user's label in the Wispr export>"}. Paths are relative to the JSON file.
See pairs.example.json. No meeting data lives in the repository.

Per meeting it prints, before and after a replay of the text cleanup that
`MeetingPipeline` runs since 2026-10-21 (`EchoFilter`, `MeetingLanguageGuard`):

- echo:    words in segments that mostly repeat a nearby segment of another speaker
- ich:     share of the words under "Ich" that Wispr attributes to the user
- strays:  short segments in the other language than the meeting's
- missing: share of Wispr's content that the note does not have (and back)

The replay works on the note's text and segment order; the app works on times.
Close, not identical. The rules are copied from the Swift sources, and a
change there has to be made here too.
"""
import json
import os
import plistlib
import re
import sys
from collections import Counter, defaultdict

# --- reading ---------------------------------------------------------------

NOTABLE_LINE = re.compile(r"^(?:\[[\d:]+\]\s*)?\*\*(.+?):\*\*\s*(.*)")
WISPR_LINE = re.compile(r"^\[[\d:]+\]\s*([^:]+):\s*(.*)")


def read_notable(path):
    text = open(path, encoding="utf-8").read()
    if "## Transkript" not in text:
        return []
    segments, current = [], None
    for line in text.split("## Transkript", 1)[1].split("\n"):
        match = NOTABLE_LINE.match(line)
        if match:
            current = [match.group(1), match.group(2)]
            segments.append(current)
        elif line.strip() and current:
            current[1] += " " + line.strip()
    return [tuple(s) for s in segments]


def read_wispr(path):
    text = open(path, encoding="utf-8").read()
    body = text.split("## Transcript", 1)[1] if "## Transcript" in text else text
    return [(m.group(1).strip(), m.group(2)) for m in map(WISPR_LINE.match, body.split("\n")) if m]


def decode(outdir, paths):
    """A .textClipping is a property list; the text sits under one of three keys."""
    os.makedirs(outdir, exist_ok=True)
    for path in paths:
        data = plistlib.load(open(path, "rb"))
        items = data.get("UTI-Data", data)
        text = None
        for key in ("public.utf8-plain-text", "public.utf16-plain-text", "public.plain-text"):
            if key in items:
                value = items[key]
                if isinstance(value, str):
                    text = value
                else:
                    text = value.decode("utf-16" if key.startswith("public.utf16") else "utf-8")
                break
        if text is None:
            print(f"{path}: kein Text gefunden ({', '.join(items)})")
            continue
        target = os.path.join(outdir, os.path.basename(path) + ".txt")
        open(target, "w", encoding="utf-8").write(text)
        print(f"{target}: {len(text.split())} Wörter")


# --- the cleanup, as in the Swift sources ----------------------------------

def words(text):
    """EchoFilter.words: lowercased runs of letters and digits."""
    return [w for w in re.split(r"[^\w]|_", text.lower()) if w]


def triples(ws):
    return {" ".join(ws[i:i + 3]) for i in range(len(ws) - 2)}


def sentences(text):
    """EchoFilter.sentences: cut after . ! ? … plus whitespace, and at line breaks."""
    pieces, start, i = [], 0, 0
    while i < len(text):
        nxt = i + 1
        ends = text[i] == "\n" or (text[i] in ".!?…" and (nxt == len(text) or text[nxt].isspace()))
        if not ends:
            i = nxt
            continue
        end = nxt
        while end < len(text) and text[end].isspace():
            end += 1
        pieces.append(text[start:end])
        start = i = end
    if start < len(text):
        pieces.append(text[start:])
    return pieces


ECHO_THRESHOLD, ECHO_MIN_WORDS, ECHO_WINDOW = 0.5, 3, 4


def echo_filter(segments, me="Ich"):
    """EchoFilter, with segment positions (±ECHO_WINDOW) standing in for times."""
    if all(s == me for s, _ in segments):
        return segments
    result = []
    for i, (speaker, text) in enumerate(segments):
        if speaker != me:
            result.append((speaker, text))
            continue
        heard = set()
        for j in range(max(0, i - ECHO_WINDOW), min(len(segments), i + ECHO_WINDOW + 1)):
            if segments[j][0] != me:
                heard |= triples(words(segments[j][1]))
        kept = ""
        for sentence in sentences(text):
            ws = words(sentence)
            own = triples(ws)
            if len(ws) >= ECHO_MIN_WORDS and own and len(own & heard) / len(own) >= ECHO_THRESHOLD:
                continue
            kept += sentence
        if kept.strip():
            result.append((speaker, kept.strip() if kept != text else text))
    return result


GERMAN = set("der die das und ist sind ich wir es nicht ein eine zu von mit auch auf für dann ja halt "
             "mal noch aber wie wenn dass sie du den dem genau oder schon jetzt hier nee nein".split())
ENGLISH = set("the and is are you we i it this that to of on for with be have yeah but what about they "
              "my your our just like can would do".split())
FILLERS = {"yeah": "ja", "yep": "ja", "yup": "ja", "mm-hmm": "mhm", "uh-huh": "mhm"}


def counts(text):
    ws = words(text)
    return sum(w in GERMAN for w in ws), sum(w in ENGLISH for w in ws)


def meeting_language(segments):
    german = sum(counts(t)[0] for _, t in segments)
    english = sum(counts(t)[1] for _, t in segments)
    if german >= 20 and german >= 2 * english:
        return "de"
    if english >= 20 and english >= 2 * german:
        return "en"
    return None


def rewrite_fillers(text):
    def replace(match):
        word = match.group(0)
        german = FILLERS.get(word.lower())
        if not german:
            return word
        return german.capitalize() if word[0].isupper() else german
    return re.sub(r"[^\W_]+(?:-[^\W\d_]+)*", replace, text)


def german_evidence(text):
    if re.search(r"[äöüßÄÖÜ]", text):
        return True
    starts = True
    for token in text.split():
        letters = re.match(r"[^\W\d_]*", re.sub(r"^[\W\d_]+", "", token)).group(0)
        if not starts and letters[:1].isupper() and letters != "I":
            return True
        starts = token[-1] in ".!?…:"
    return False


def is_stray(text):
    german, english = counts(text)
    return english > 0 and german == 0 and not german_evidence(text)


def language_guard(segments):
    """MeetingLanguageGuard: only German meetings, only segments up to six words."""
    if meeting_language(segments) != "de":
        return segments
    result = []
    for speaker, text in segments:
        if len(words(text)) > 6:
            result.append((speaker, text))
            continue
        text = rewrite_fillers(text)
        if not is_stray(text):
            result.append((speaker, text))
    return result


# --- measuring -------------------------------------------------------------

def echo_share(segments):
    grams = [triples(words(t)) for _, t in segments]
    total = duplicate = 0
    for i, (speaker, text) in enumerate(segments):
        n = len(words(text))
        total += n
        if len(grams[i]) < 3:
            continue
        best = 0
        for j in range(max(0, i - 6), min(len(segments), i + 7)):
            if j != i and segments[j][0] != speaker and grams[j]:
                best = max(best, len(grams[i] & grams[j]) / len(grams[i]))
        if best >= 0.5:
            duplicate += n
    return duplicate / total if total else 0


def strays(segments):
    language = meeting_language(segments)
    if language != "de":
        return 0
    short = [t for _, t in segments if len(words(t)) <= 6]
    return sum(is_stray(rewrite_fillers(t)) for t in short) / len(segments) if segments else 0


def attribution(notable, wispr, owner, me="Ich"):
    """Share of the words under "Ich" whose triples Wispr gives to `owner`."""
    index = defaultdict(Counter)
    for speaker, text in wispr:
        for gram in triples(words(text)):
            index[gram][speaker] += 1
    mine = total = 0
    for speaker, text in notable:
        if speaker != me:
            continue
        votes = Counter()
        for gram in triples(words(text)):
            votes.update(index.get(gram, {}))
        n = len(words(text))
        total += n
        if votes and votes.most_common(1)[0][0] == owner:
            mine += n
    return mine / total if total else None


def missing(source, target):
    """Words of `source` in segments of which under 20 % of the triples appear in `target`."""
    known = set().union(*[triples(words(t)) for _, t in target]) if target else set()
    total = lost = 0
    for _, text in source:
        grams = triples(words(text))
        if len(grams) < 4:
            continue
        n = len(words(text))
        total += n
        if len(grams & known) / len(grams) < 0.2:
            lost += n
    return lost / total if total else 0


def percent(value):
    return "–" if value is None else f"{value:.0%}"


def measure(pairs_path):
    base = os.path.dirname(os.path.abspath(pairs_path))
    pairs = json.load(open(pairs_path, encoding="utf-8"))
    for name, pair in pairs.items():
        before = read_notable(os.path.join(base, pair["notable"]))
        after = language_guard(echo_filter(before))
        line = (f"{name}: echo {percent(echo_share(before))} -> {percent(echo_share(after))}"
                f" · strays {percent(strays(before))} -> {percent(strays(after))}")
        if pair.get("wispr"):
            wispr = read_wispr(os.path.join(base, pair["wispr"]))
            owner = pair.get("owner")
            if owner:
                line += (f" · ich {percent(attribution(before, wispr, owner))}"
                         f" -> {percent(attribution(after, wispr, owner))}")
            line += f" · fehlt {percent(missing(wispr, after))} (Wispr) / {percent(missing(after, wispr))} (Notable)"
        print(line)


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "decode":
        decode(sys.argv[2], sys.argv[3:])
    elif len(sys.argv) == 3 and sys.argv[1] == "measure":
        measure(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(1)
