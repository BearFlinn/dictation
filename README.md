# dictation

Local, on-demand voice dictation for Hyprland. Press a key, speak, press it again, and the text is typed into whatever window has focus. Nothing leaves the machine and nothing runs until you start it.

## How it works

- **[Voxtype](https://github.com/peteonrails/voxtype)** records from the mic and transcribes with **Parakeet TDT 0.6B v2** (English, includes punctuation). Parakeet runs on the CPU, because Voxtype's ONNX GPU builds require AVX-512 and the Ryzen 5800X lacks it. Voxtype types the result with `wtype`.
- Before typing, Voxtype pipes the transcript through `bin/cleanup`. That script sends it to **Gemma 4 E2B** (Q8_0 GGUF) served by **llama.cpp** on `127.0.0.1:8090` for light cleanup: it drops filler words, keeps only the corrected version of self-corrections, and fixes punctuation. It does no rewording. It also turns dictated formatting into symbols: "open quote … close quote" or "quote … unquote", "open paren … close paren" or "in parentheses …", "colon", "new line", and "new paragraph". Line breaks are typed as Shift+Enter, so chat apps don't submit mid-dictation.
- If the cleanup server is down, slow (over 7 s), or returns something that looks like a rewrite or an answer instead of a cleanup, Voxtype types the raw transcript.
- `bin/dictation` runs both processes as transient systemd user units (`dictation-llm`, `dictation-voxtype`). Nothing auto-starts, and `dictation stop` frees everything. Gemma uses about 6 GB of VRAM.

## Use

```sh
dictation start    # load models (a few seconds), then SUPER+D toggles recording
dictation stop     # unload everything
dictation status
dictation logs -f
```

SUPER+D runs `voxtype record toggle`. When the stack is stopped, the key does nothing.

## Install

```sh
./install.sh
```

The installer does the following, and is safe to re-run:

- Installs the Voxtype `.deb` after verifying its release signature. Needs sudo.
- Selects Voxtype's ONNX binary.
- Downloads the llama.cpp CUDA build into `vendor/`.
- Downloads Gemma into `models/`.
- Downloads Parakeet into `~/.local/share/voxtype/models/`.
- Symlinks `config/voxtype.toml` to `~/.config/voxtype/config.toml`.
- Symlinks `bin/dictation` into `~/.local/bin`.
- Appends the SUPER+D bind to `~/.config/hypr/hyprland.conf`.

All versions and model revisions are pinned in `versions.env`.

## Tuning

- **Cleanup behavior:** the prompt and the word-count guard are in `bin/cleanup`.
- **Transcription engine or model:** `config/voxtype.toml`. Voxtype also supports Whisper and Cohere Transcribe. See its `docs/CONFIGURATION.md`.
- **Disable cleanup:** remove the `[output.post_process]` section from `config/voxtype.toml`.
