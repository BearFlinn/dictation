# speech-playground

Local, on-demand speech-to-text tools for a Hyprland desktop with an NVIDIA GPU. Nothing leaves the machine and nothing runs until you start it, so the GPU stays free for games.

- **[Dictation](#dictation):** press a key, speak, press it again, and the text is typed into whatever window has focus.

Shared pieces live at the top level: `install.sh` installs everything, `versions.env` pins every download, and `vendor/` and `models/` hold the llama.cpp build and model files.

## Dictation

### How it works

- **[Voxtype](https://github.com/peteonrails/voxtype)** records from the mic and transcribes with **Cohere Transcribe** (FP16, the most accurate model Voxtype supports). It uses Voxtype's ONNX CUDA 13 build, the one with RTX 50-series kernels. That build runs Cohere's encoder on the GPU and its decoder on the CPU. Voxtype types the result with `wtype`.
- Before typing, Voxtype pipes the transcript through `dictation/cleanup`. That script sends it to **Gemma 4 E2B** (Q8_0 GGUF) served by **llama.cpp** on `127.0.0.1:8090` for light cleanup: it drops filler words, keeps only the corrected version of self-corrections, and fixes punctuation. It does no rewording. It also turns dictated formatting into symbols: "open quote … close quote" or "quote … unquote", "open paren … close paren" or "in parentheses …", "colon", "new line", and "new paragraph". Line breaks are typed as Shift+Enter, so chat apps don't submit mid-dictation.
- If the cleanup server is down, slow (over 7 s), or returns something that looks like a rewrite or an answer instead of a cleanup, Voxtype types the raw transcript.
- `dictation/dictation` runs both processes as transient systemd user units (`dictation-llm`, `dictation-voxtype`). Nothing auto-starts, and `dictation stop` frees everything. The two models together use about 7 GB of VRAM.

### Use

- **App menu:** "Dictation" starts the stack, or stops it if it's running.
- **Waybar:** the microphone icon shows the state (grey = off, yellow = starting or transcribing, green = ready, red = recording). Click it to start or stop.
- **Recording:** SUPER+D runs `voxtype record toggle`. Press it once to start recording and again to transcribe and type. When the stack is stopped, the key does nothing.

From a terminal:

```sh
dictation start | stop | toggle | restart | status
dictation logs -f
```

The Waybar module (in `~/.config/waybar/config.jsonc`, styled in `style.css` and `style.css.tmpl`):

```jsonc
"custom/dictation": {
    "exec": "~/.local/bin/dictation waybar",
    "return-type": "json",
    "on-click": "~/.local/bin/dictation toggle"
}
```

### Tuning

- **Cleanup behavior:** the prompt and the word-count guard are in `dictation/cleanup`.
- **Transcription engine or model:** `dictation/voxtype.toml`. Smaller Cohere variants (`cohere-transcribe-q4f16`, `-int8`) and other engines are listed in Voxtype's `docs/CONFIGURATION.md`. They aren't downloaded by `install.sh`.
- **Disable cleanup:** remove the `[output.post_process]` section from `dictation/voxtype.toml`.

## Install

```sh
./install.sh
```

The installer does the following, and is safe to re-run:

- Installs the Voxtype `.deb` after verifying its release signature. Needs sudo.
- Selects Voxtype's ONNX binary.
- Downloads the llama.cpp CUDA build into `vendor/`.
- Downloads NVIDIA's CUDA 13 libraries (runtime, cuBLAS, cuFFT, cuRAND, cuDNN) from PyPI into `vendor/cuda13-libs/`, checking their hashes.
- Downloads Gemma into `models/`.
- Downloads Cohere Transcribe into `~/.local/share/voxtype/models/`.
- Symlinks `dictation/voxtype.toml` to `~/.config/voxtype/config.toml`.
- Symlinks `dictation/dictation` into `~/.local/bin`.
- Writes the app-menu entry.
- Appends the SUPER+D bind to `~/.config/hypr/hyprland.conf`.

All versions, model revisions and library hashes are pinned in `versions.env`. The Waybar module is added by hand (see above).

`voxtype setup gpu --enable` refuses to pick a CUDA build on CPUs without AVX-512. The CUDA build runs fine on the Ryzen 5800X, so `dictation/dictation` starts it directly instead.
