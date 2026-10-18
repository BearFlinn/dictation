#!/usr/bin/env bash
# Installs the dictation stack: Voxtype (.deb), a llama.cpp CUDA build,
# Gemma 4 E2B (GGUF), Parakeet TDT 0.6B v2 (ONNX), config symlinks and
# Hyprland binds. Safe to re-run; finished steps are skipped.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO/versions.env"

VENDOR="$REPO/vendor"
MODELS="$REPO/models"
PARAKEET_DIR="$HOME/.local/share/voxtype/models/parakeet-tdt-0.6b-v2"
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
    # Voxtype's ONNX GPU binaries require AVX-512, which the Ryzen 5800X
    # lacks, so Parakeet runs on the CPU (AVX2) build.
    log "Selecting Voxtype's ONNX binary (Parakeet engine)"
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

install_models() {
    log "Downloading Gemma 4 E2B ($GEMMA_FILE)"
    mkdir -p "$MODELS"
    fetch "https://huggingface.co/$GEMMA_REPO/resolve/$GEMMA_REVISION/$GEMMA_FILE" "$MODELS/$GEMMA_FILE"

    log "Downloading Parakeet TDT 0.6B v2"
    mkdir -p "$PARAKEET_DIR"
    local f
    for f in encoder-model.onnx encoder-model.onnx.data decoder_joint-model.onnx vocab.txt config.json; do
        fetch "https://huggingface.co/$PARAKEET_REPO/resolve/$PARAKEET_REVISION/$f" "$PARAKEET_DIR/$f"
    done
}

link_config() {
    log "Linking config and CLI"
    mkdir -p "$HOME/.config/voxtype" "$HOME/.local/bin"
    ln -sfn "$REPO/config/voxtype.toml" "$HOME/.config/voxtype/config.toml"
    ln -sfn "$REPO/bin/dictation" "$HOME/.local/bin/dictation"
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
install_models
link_config
add_hypr_bind
log "Done. Run 'dictation start', then press SUPER+D to start and stop dictating."
