# speech-playground

Local, on-demand speech-to-text for a Hyprland desktop with an NVIDIA GPU: dictation into any window, and meeting notes with speaker labels and a summary. Nothing leaves the machine and nothing runs until you start it, so the GPU stays free for games.

## Design

Two local servers do the model work, and two thin clients use them:

| Piece | What it does | Runs |
|---|---|---|
| `speech-asr` | **[CrispASR](https://github.com/CrispStrobe/CrispASR)** serving **Cohere Transcribe** (words), **Nemotron 3 Diarization** (who spoke when, up to 8 speakers) and **Silero VAD** (skips silence) over an OpenAI-compatible API on `127.0.0.1:8091` | GPU, ~4.5 GB |
| `speech-llm` | **llama.cpp** serving **Gemma 4 E4B** (Q8_0) on `127.0.0.1:8090` for dictation cleanup and meeting summaries | GPU, ~6 GB |
| Dictation | **[Voxtype](https://github.com/peteonrails/voxtype)** records on SUPER+D, sends the audio to `speech-asr` through its remote backend, pipes the text through `dictation/cleanup`, and types the result | CPU |
| Meetings | `meetings/meeting` records two tracks, sends them to `speech-asr`, merges the turns and asks `speech-llm` for a summary | CPU |

Each model does one job. Cohere is the most accurate open model available, but it has no timestamps or speaker labels, so the diarization model supplies those. The clients only speak HTTP, so the servers can move to another machine by changing the addresses in `lib/common.sh` and `dictation/voxtype.toml`.

`bin/speech` runs the two servers and the Voxtype daemon as transient systemd user units (`speech-asr`, `speech-llm`, `speech-voxtype`). Nothing auto-starts, and `speech stop` frees the GPU.

## Dictation

- **Start:** the "Speech" app-menu entry, the Waybar microphone icon, or `speech start`.
- **Record:** SUPER+D runs `voxtype record toggle`. Press once to start, again to transcribe and type.
- **Cleanup:** `dictation/cleanup` asks Gemma to drop filler words, keep only the corrected version of self-corrections, and fix punctuation, without rewording. It also turns dictated formatting into symbols: "open quote … close quote" or "quote … unquote", "open paren … close paren" or "in parentheses …", "colon", "new line", and "new paragraph". Line breaks are typed as Shift+Enter, so chat apps don't submit mid-dictation. If Gemma is down, slow (over 7 s), or returns something that looks like a rewrite or an answer, Voxtype types the raw transcript.
- **Waybar icon:** grey = off, yellow = starting or transcribing, green = ready, red = recording. Click to start or stop.
- **Speed:** about 0.4 s from the end of recording to text, plus about 0.15 s for cleanup.

## Meeting notes

- **Start/stop:** the "Meeting Notes" app-menu entry, the Waybar people icon (red with a timer while recording), or `meeting toggle`.
- **Recording:** one `ffmpeg` process records your mic (GoXLR "Chat Mic") as `mic.wav` and everyone else (the monitor of the GoXLR "Chat" output) as `chat.wav`. Calls must be routed to the GoXLR Chat channel. Recording uses no GPU, and the servers don't need to be running.
- **Processing** (in the background after stopping): the chat track is transcribed with speaker separation and the mic track without it, so your lines are always "You" and others are "Speaker 1", "Speaker 2" and so on. `meetings/merge.py` interleaves the turns by time, and Gemma writes a summary, decisions and action items. If the servers weren't running, they are started for the job and stopped after it.
- **Output:** `~/Documents/meetings/<date>_<time>/notes.md`, next to the WAV and JSON files. A notification says when it's ready.
- **Speed:** a 60-minute meeting takes about 80 s.

```sh
speech start | stop | restart | toggle | status
speech logs -f
meeting start | stop | toggle | status
meeting process ~/Documents/meetings/<dir>   # redo transcript and notes
meeting logs -f
```

## Waybar

In `~/.config/waybar/config.jsonc` (styled in `style.css` and `style.css.tmpl` with `#custom-speech` and `#custom-meeting` classes):

```jsonc
"custom/speech": {
    "exec": "~/.local/bin/speech waybar",
    "return-type": "json",
    "on-click": "~/.local/bin/speech toggle"
},
"custom/meeting": {
    "exec": "~/.local/bin/meeting waybar",
    "return-type": "json",
    "on-click": "~/.local/bin/meeting toggle"
}
```

## Install

```sh
./install.sh
```

Safe to re-run. It:

- Installs the Voxtype `.deb` after verifying its release signature (needs sudo) and selects its default Whisper build, which is all the remote backend needs.
- Downloads CrispASR's CUDA 13 build (hash-checked) and the llama.cpp CUDA build into `vendor/`.
- Downloads the CUDA 13 runtime and cuBLAS from NVIDIA's PyPI wheels (hash-checked) into `vendor/cuda13-libs/`. CrispASR's CUDA 13 build is the one with RTX 50-series kernels, and no CUDA libraries are installed system-wide.
- Downloads Cohere Transcribe, Nemotron 3 Diarization, Silero VAD and Gemma into `models/`.
- Symlinks `dictation/voxtype.toml` to `~/.config/voxtype/config.toml`, and `bin/speech` and `meetings/meeting` into `~/.local/bin`.
- Writes the "Speech" and "Meeting Notes" app-menu entries and appends the SUPER+D bind to `~/.config/hypr/hyprland.conf`.

Every version, model revision and hash is pinned in `versions.env`. The Waybar modules are added by hand (see above).

## Tuning

- **Ports and server flags:** `lib/common.sh`.
- **Cleanup behavior:** the prompt and the output guards in `dictation/cleanup`.
- **Disable cleanup:** remove `[output.post_process]` from `dictation/voxtype.toml`.
- **Meeting audio sources:** `MEETING_MIC_SOURCE` and `MEETING_CHAT_SOURCE` (PipeWire source names from `pactl list short sources`). Output folder: `MEETINGS_DIR`.
- **Summary prompt:** `summarize()` in `meetings/meeting`. Turn grouping: `TURN_GAP_S` in `meetings/merge.py`.
