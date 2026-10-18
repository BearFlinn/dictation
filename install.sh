#!/usr/bin/env bash
# Installs the dictation stack: Voxtype (.deb), a llama.cpp CUDA build, the
# CUDA 13 libraries Voxtype's GPU path needs, Gemma 4 E2B (GGUF), Cohere
# Transcribe (ONNX), config symlinks and the Hyprland bind. Safe to re-run;
# finished steps are skipped.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO/versions.env"

VENDOR="$REPO/vendor"
MODELS="$REPO/models"
COHERE_DIR="$HOME/.local/share/voxtype/models/$COHERE_MODEL"
HYPR_CONF="$HOME/.config/hypr/hyprland.conf"

log() { printf '\n==> %s\n' "$*"; }

fetch() { # url dest
    [[ -s "$2" ]] && return 0
    curl -fL --retry 3 -o "$2.part" "$1"
    mv "$2.part" "$2"
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
    # `dictation start` runs the ONNX CUDA binary directly. /usr/bin/voxtype
    # only needs to be an ONNX build so `voxtype record toggle` and config
    # checks understand the Cohere engine. (`voxtype setup gpu --enable`
    # refuses on CPUs without AVX-512, but the CUDA binary runs fine on the
    # Ryzen 5800X.)
    log "Selecting Voxtype's ONNX binary"
    sudo voxtype setup onnx --enable
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
    log "Downloading CUDA 13 runtime, cuBLAS, cuFFT, cuRAND and cuDNN"
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
    log "Downloading Gemma 4 E2B ($GEMMA_FILE)"
    mkdir -p "$MODELS"
    fetch "https://huggingface.co/$GEMMA_REPO/resolve/$GEMMA_REVISION/$GEMMA_FILE" "$MODELS/$GEMMA_FILE"

    # File names follow Voxtype's own downloader (src/setup/model.rs), which
    # renames the fp16 graphs to the names its Cohere engine loads.
    log "Downloading Cohere Transcribe ($COHERE_MODEL, ~3.9 GB)"
    mkdir -p "$COHERE_DIR"
    local pair src dest
    for pair in \
        onnx/encoder_model_fp16.onnx:encoder_model.onnx \
        onnx/encoder_model_fp16.onnx_data:encoder_model_fp16.onnx_data \
        onnx/encoder_model_fp16.onnx_data_1:encoder_model_fp16.onnx_data_1 \
        onnx/decoder_model_merged_fp16.onnx:decoder_model_merged.onnx \
        onnx/decoder_model_merged_fp16.onnx_data:decoder_model_merged_fp16.onnx_data \
        tokenizer.json:tokenizer.json \
        tokenizer_config.json:tokenizer_config.json \
        config.json:config.json \
        generation_config.json:generation_config.json \
        processor_config.json:processor_config.json; do
        src="${pair%%:*}"
        dest="${pair##*:}"
        fetch "https://huggingface.co/$COHERE_REPO/resolve/$COHERE_REVISION/$src" "$COHERE_DIR/$dest"
    done
}

link_config() {
    log "Linking config and CLI"
    mkdir -p "$HOME/.config/voxtype" "$HOME/.local/bin"
    ln -sfn "$REPO/config/voxtype.toml" "$HOME/.config/voxtype/config.toml"
    ln -sfn "$REPO/bin/dictation" "$HOME/.local/bin/dictation"

    log "Writing app-menu entry"
    mkdir -p "$HOME/.local/share/applications"
    cat >"$HOME/.local/share/applications/dictation.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Dictation
GenericName=Voice dictation
Comment=Start or stop local voice dictation (SUPER+D records)
Exec=$REPO/bin/dictation toggle
Icon=audio-input-microphone
Terminal=false
Categories=Utility;Accessibility;
Keywords=voice;speech;dictate;transcribe;microphone;
EOF
}

add_hypr_bind() {
    if grep -q 'voxtype record toggle' "$HYPR_CONF"; then
        log "Hyprland bind already present"
        return
    fi
    log "Adding SUPER+D dictation toggle to $HYPR_CONF"
    cat >> "$HYPR_CONF" <<'EOF'

# Dictation: SUPER+D starts/stops recording (needs `dictation start`; see ~/Projects/playground/dictation)
bind = SUPER, D, exec, voxtype record toggle
EOF
}

install_voxtype
install_llama
install_cuda_libs
install_models
link_config
add_hypr_bind
log "Done. Run 'dictation start', then press SUPER+D to start and stop dictating."
