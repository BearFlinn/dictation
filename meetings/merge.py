"""Merge the mic and chat transcripts into one Markdown transcript.

Usage: merge.py MIC_JSON CHAT_JSON > transcript.md

Both files are speech-asr responses: the mic track as verbose_json, the chat
track as diarized_json. Mic segments are "You". Chat speakers are renumbered
"Speaker 1", "Speaker 2", ... in order of first appearance. Consecutive
segments from the same speaker with a short gap become one turn, then the
turns from both tracks are sorted by start time.
"""

import json
import sys

# A pause longer than this starts a new turn even for the same speaker.
TURN_GAP_S = 2.0


def segments(path):
    with open(path, encoding="utf-8") as f:
        return [s for s in json.load(f).get("segments", []) if s.get("text", "").strip()]


def turns(segs, label):
    out = []
    for s in segs:
        speaker = label(s)
        if out and out[-1]["speaker"] == speaker and s["start"] - out[-1]["end"] < TURN_GAP_S:
            out[-1]["text"] += " " + s["text"].strip()
            out[-1]["end"] = s["end"]
        else:
            out.append({"speaker": speaker, "start": s["start"], "end": s["end"], "text": s["text"].strip()})
    return out


def stamp(seconds):
    s = int(seconds)
    h, m, s = s // 3600, s // 60 % 60, s % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def main():
    mic_path, chat_path = sys.argv[1:3]
    numbers = {}

    def chat_label(seg):
        raw = seg.get("speaker", "?")
        numbers.setdefault(raw, len(numbers) + 1)
        return f"Speaker {numbers[raw]}"

    merged = sorted(
        turns(segments(mic_path), lambda s: "You") + turns(segments(chat_path), chat_label),
        key=lambda t: t["start"],
    )
    if not merged:
        print("_No speech detected._")
        return
    for t in merged:
        print(f"**[{stamp(t['start'])}] {t['speaker']}:** {t['text']}\n")


if __name__ == "__main__":
    main()
