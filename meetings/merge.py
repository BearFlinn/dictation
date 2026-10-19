"""Merge the mic and chat transcripts (nemo-speech JSON) into one Markdown transcript.

Usage: merge.py MIC_JSON CHAT_JSON > transcript.md

Words from the mic track are "You". Words from the chat track carry a speaker
number from diarization. Each track is first grouped into turns, so overlapping
speech from the two tracks doesn't interleave word by word, then the turns are
sorted by start time.
"""

import json
import sys

# A pause longer than this starts a new turn even for the same speaker.
TURN_GAP_S = 2.0


def turns(path, label):
    with open(path, encoding="utf-8") as f:
        words = json.load(f).get("words", [])
    out = []
    for w in words:
        speaker = label(w)
        if out and out[-1]["speaker"] == speaker and w["start"] - out[-1]["end"] < TURN_GAP_S:
            out[-1]["words"].append(w["word"])
            out[-1]["end"] = w["end"]
        else:
            out.append({"speaker": speaker, "start": w["start"], "end": w["end"], "words": [w["word"]]})
    return out


def stamp(seconds):
    s = int(seconds)
    h, m, s = s // 3600, s // 60 % 60, s % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def main():
    mic_path, chat_path = sys.argv[1:3]
    merged = sorted(
        turns(mic_path, lambda w: "You") + turns(chat_path, lambda w: f"Speaker {w.get('speaker', '?')}"),
        key=lambda t: t["start"],
    )
    if not merged:
        print("_No speech detected._")
        return
    for t in merged:
        print(f"**[{stamp(t['start'])}] {t['speaker']}:** {' '.join(t['words'])}\n")


if __name__ == "__main__":
    main()
