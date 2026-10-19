#!/usr/bin/env bash
# Installs the speech stack: CrispASR (speech-asr) with Cohere Transcribe,
# Nemotron 3 Diarization and Silero VAD; llama.cpp (speech-llm) with Gemma;
# the CUDA 13 libraries CrispASR needs; Voxtype as the dictation front end;
# CLI symlinks, app-menu entries and the Hyprland bind. Safe to re-run;
# finished steps are skipped.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO/versions.env"

VENDOR="$REPO/vendor"
MODELS="$REPO/models"
HYPR_CONF="$HOME/.config/hypr/hyprland.conf"

log() { printf '\n==> %s\n' "$*"; }

fetch() { # url dest
    [[ -s "$2" ]] && return 0
    curl -fL --retry 3 -o "$2.part" "$1"
    mv "$2.part" "$2"
}

hf_fetch() { # repo revision file
    fetch "https://huggingface.co/$1/resolve/$2/$3" "$MODELS/$3"
}

install_voxtype() {
    if [[ "$(voxtype --version 2>/dev/null || true)" == *"$VOXTYPE_VERSION"* ]]; then
        log "Voxtype $VOXTYPE_VERSION already installed"
    else
        log "Installing Voxtype $VOXTYPE_VERSION"
        local tmp deb base
        tmp="$(mktemp -d)"
        chmod 700 "$tmp"
        deb="voxtype_${VOXTYPE_VERSION}-1_amd64.deb"
        base="https://github.com/peteonrails/voxtype/releases/download/v${VOXTYPE_VERSION}"
        fetch "$base/$deb" "$tmp/$deb"
        fetch "$base/$deb.asc" "$tmp/$deb.asc"
        # The .deb isn't in SHA256SUMS.txt; verify its release-key signature.
        gpg --homedir "$tmp" --quiet --keyserver hkps://keys.openpgp.org \
            --recv-keys "$VOXTYPE_SIGNING_KEY"
        gpg --homedir "$tmp" --status-fd 1 --verify "$tmp/$deb.asc" "$tmp/$deb" 2>/dev/null |
            grep -q "VALIDSIG $VOXTYPE_SIGNING_KEY" ||
            { echo "Voxtype .deb signature check failed" >&2; exit 1; }
        sudo apt-get install -y "$tmp/$deb"
        rm -rf "$tmp"
    fi
    # Transcription happens in speech-asr, so Voxtype only needs its default
    # Whisper build for the remote backend.
    log "Selecting Voxtype's default (Whisper) binary"
    sudo voxtype setup onnx --disable
}

install_crispasr() {
    local dir="$VENDOR/crispasr-$CRISPASR_VERSION"
    if [[ -x "$dir/crispasr" ]]; then
        log "CrispASR $CRISPASR_VERSION already present"
        return
    fi
    log "Downloading CrispASR $CRISPASR_VERSION (CUDA 13)"
    local tmp
    tmp="$(mktemp -d)"
    fetch "https://github.com/CrispStrobe/CrispASR/releases/download/v$CRISPASR_VERSION/crispasr-linux-x86_64-cuda13.tar.gz" "$tmp/crispasr.tar.gz"
    echo "$CRISPASR_SHA256  $tmp/crispasr.tar.gz" | sha256sum -c --quiet -
    mkdir -p "$dir"
    tar -xzf "$tmp/crispasr.tar.gz" -C "$dir" --strip-components=1
    rm -rf "$tmp"
}

install_llama() {
    local dir="$VENDOR/llama.cpp-$LLAMA_CPP_BUILD"
    if [[ -x "$dir/llama-server" ]]; then
        log "llama.cpp $LLAMA_CPP_BUILD already present"
        return
    fi
    log "Downloading llama.cpp $LLAMA_CPP_BUILD (CUDA $LLAMA_CPP_CUDA)"
    local base="https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_CPP_BUILD"
    local tmp
    tmp="$(mktemp -d)"
    fetch "$base/llama-$LLAMA_CPP_BUILD-bin-ubuntu-cuda-$LLAMA_CPP_CUDA-x64.tar.gz" "$tmp/llama.tar.gz"
    fetch "$base/cudart-llama-$LLAMA_CPP_BUILD-bin-ubuntu-cuda-$LLAMA_CPP_CUDA-x64.tar.gz" "$tmp/cudart.tar.gz"
    mkdir -p "$dir"
    tar -xzf "$tmp/llama.tar.gz" -C "$dir" --strip-components=1
    tar -xzf "$tmp/cudart.tar.gz" -C "$dir" --strip-components=1
    rm -rf "$tmp"
}

install_cuda_libs() {
    local dir="$VENDOR/cuda13-libs"
    if [[ -f "$dir/.complete" ]]; then
        log "CUDA 13 libraries already present"
        return
    fi
    log "Downloading CUDA 13 runtime and cuBLAS"
    local tmp entry url sha
    tmp="$(mktemp -d)"
    mkdir -p "$dir"
    for entry in "${CUDA_WHEELS[@]}"; do
        read -r url sha <<<"$entry"
        fetch "$url" "$tmp/wheel.whl"
        echo "$sha  $tmp/wheel.whl" | sha256sum -c --quiet -
        unzip -q -o -j "$tmp/wheel.whl" 'nvidia/*/lib/*.so*' -d "$dir"
        rm "$tmp/wheel.whl"
    done
    rm -rf "$tmp"
    touch "$dir/.complete"
}

install_models() {
    mkdir -p "$MODELS"
    log "Downloading Cohere Transcribe ($COHERE_FILE, ~4.1 GB)"
    hf_fetch "$COHERE_REPO" "$COHERE_REVISION" "$COHERE_FILE"
    log "Downloading Nemotron 3 Diarization ($DIAR_FILE)"
    hf_fetch "$DIAR_REPO" "$DIAR_REVISION" "$DIAR_FILE"
    log "Downloading Silero VAD ($VAD_FILE)"
    hf_fetch "$VAD_REPO" "$VAD_REVISION" "$VAD_FILE"
    log "Downloading Gemma ($GEMMA_FILE)"
    hf_fetch "$GEMMA_REPO" "$GEMMA_REVISION" "$GEMMA_FILE"
}

link_config() {
    log "Linking config and CLIs"
    mkdir -p "$HOME/.config/voxtype" "$HOME/.local/bin" "$HOME/.local/share/applications"
    ln -sfn "$REPO/dictation/voxtype.toml" "$HOME/.config/voxtype/config.toml"
    ln -sfn "$REPO/bin/speech" "$HOME/.local/bin/speech"
    ln -sfn "$REPO/meetings/meeting" "$HOME/.local/bin/meeting"

    log "Writing app-menu entries"
    cat >"$HOME/.local/share/applications/speech.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Speech
GenericName=Voice dictation
Comment=Start or stop the local speech servers and dictation (SUPER+D records)
Exec=$REPO/bin/speech toggle
Icon=audio-input-microphone
Terminal=false
Categories=Utility;Accessibility;
Keywords=voice;speech;dictate;dictation;transcribe;microphone;
EOF
    cat >"$HOME/.local/share/applications/meeting-notes.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Meeting Notes
GenericName=Meeting recorder
Comment=Start or stop recording a call; notes are written when it stops
Exec=$REPO/meetings/meeting toggle
Icon=audio-x-generic
Terminal=false
Categories=Utility;Office;
Keywords=meeting;call;record;transcribe;notes;diarization;
EOF
}

add_hypr_bind() {
    if grep -q 'voxtype record toggle' "$HYPR_CONF"; then
        log "Hyprland bind already present"
        return
    fi
    log "Adding SUPER+D dictation toggle to $HYPR_CONF"
    cat >>"$HYPR_CONF" <<'EOF'

# Dictation: SUPER+D starts/stops recording (needs `speech start`; see ~/Projects/playground/speech-playground)
bind = SUPER, D, exec, voxtype record toggle
EOF
}

install_voxtype
install_crispasr
install_llama
install_cuda_libs
install_models
link_config
add_hypr_bind
log "Done. Run 'speech start', then press SUPER+D to dictate. Meetings: 'meeting toggle'."
