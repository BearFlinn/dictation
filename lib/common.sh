# Shared settings and helpers for the speech tools. Sourced by bin/speech,
# dictation/cleanup and meetings/meeting.

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
source "$REPO/versions.env"

ASR_PORT="${SPEECH_ASR_PORT:-8091}"
LLM_PORT="${SPEECH_LLM_PORT:-8090}"
ASR_URL="http://127.0.0.1:$ASR_PORT"
LLM_URL="http://127.0.0.1:$LLM_PORT"

ASR_UNIT=speech-asr
LLM_UNIT=speech-llm
VOX_UNIT=speech-voxtype

CRISPASR_DIR="$REPO/vendor/crispasr-$CRISPASR_VERSION"
LLAMA_DIR="$REPO/vendor/llama.cpp-$LLAMA_CPP_BUILD"
CUDA_LIBS="$REPO/vendor/cuda13-libs"
MODELS="$REPO/models"

notify() { # title message
    if command -v notify-send >/dev/null; then
        notify-send -a speech "$1" "$2" || true
    fi
}

is_active() { systemctl --user is-active --quiet "$1"; }

servers_ready() {
    curl -fs --max-time 1 "$ASR_URL/health" >/dev/null 2>&1 &&
        curl -fs --max-time 1 "$LLM_URL/health" >/dev/null 2>&1
}

# Starts whichever of the two servers isn't running. Both run as transient
# systemd user units, so nothing starts at login and stopping frees the GPU.
start_servers() {
    if ! is_active "$ASR_UNIT"; then
        systemctl --user reset-failed "$ASR_UNIT" 2>/dev/null || true
        systemd-run --user --quiet --unit="$ASR_UNIT" --collect \
            --setenv=LD_LIBRARY_PATH="$CUDA_LIBS" \
            "$CRISPASR_DIR/crispasr" --server \
            --host 127.0.0.1 --port "$ASR_PORT" \
            --backend cohere -m "$MODELS/$COHERE_FILE" -l en \
            --diarize-model "$MODELS/$DIAR_FILE" \
            --vad-model "$MODELS/$VAD_FILE"
    fi
    if ! is_active "$LLM_UNIT"; then
        systemctl --user reset-failed "$LLM_UNIT" 2>/dev/null || true
        systemd-run --user --quiet --unit="$LLM_UNIT" --collect \
            --setenv=LD_LIBRARY_PATH="$LLAMA_DIR" \
            "$LLAMA_DIR/llama-server" \
            --model "$MODELS/$GEMMA_FILE" \
            --host 127.0.0.1 --port "$LLM_PORT" \
            --n-gpu-layers 999 --ctx-size 32768 --parallel 1 \
            --reasoning-budget 0
    fi
}

# Waits up to 120 s for both servers; fails early if either unit dies.
wait_for_servers() {
    local _
    for _ in $(seq 120); do
        servers_ready && return 0
        is_active "$ASR_UNIT" && is_active "$LLM_UNIT" || return 1
        sleep 1
    done
    return 1
}

stop_servers() { systemctl --user stop "$ASR_UNIT" "$LLM_UNIT" 2>/dev/null || true; }
