#!/bin/bash
# ask-kip.sh — toggle mic recording, transcribe with Whisper, send to Kip via Telegram
#
# First press: starts recording
# Second press: stops recording, transcribes, sends

VERSION="0.1.0"

if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "ask-kip $VERSION"
    exit 0
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

LOCK_FILE="/tmp/ask-kip-recording.lock"
AUDIO_FILE="/tmp/ask-kip-query.wav"
TRANSCRIPT_BASE="/tmp/ask-kip-query"
TRANSCRIPT_FILE="${TRANSCRIPT_BASE}.txt"

WHISPER_BIN="$SCRIPT_DIR/whisper.cpp/build/bin/whisper-cli"
WHISPER_MODEL="$SCRIPT_DIR/whisper.cpp/models/ggml-base.en.bin"

SEND_SCRIPT="$SCRIPT_DIR/send_message.py"
VENV_PYTHON="$SCRIPT_DIR/.venv/bin/python"

# ── Load config ────────────────────────────────────────────────────────────────────────────────────

if [ ! -f "$ENV_FILE" ]; then
    notify-send "ask-kip" "Missing .env file. Copy .env.example and fill in your values."
    echo "ERROR: Missing .env file at $ENV_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

: "${TELEGRAM_API_ID:?TELEGRAM_API_ID is not set in .env}"
: "${TELEGRAM_API_HASH:?TELEGRAM_API_HASH is not set in .env}"
: "${KIP_TARGET:?KIP_TARGET is not set in .env}"
: "${WHISPER_MODEL_PATH:=$WHISPER_MODEL}"
: "${WHISPER_LANG:=en}"

export TELEGRAM_API_ID TELEGRAM_API_HASH KIP_TARGET
export TELEGRAM_SESSION="${TELEGRAM_SESSION:-}"

WHISPER_MODEL="$WHISPER_MODEL_PATH"

if [ -x "$VENV_PYTHON" ]; then
    PYTHON="$VENV_PYTHON"
else
    PYTHON="python3"
fi

# ── Sanity checks ─────────────────────────────────────────────────────────────

if [ ! -f "$WHISPER_BIN" ]; then
    notify-send "ask-kip" "whisper-cli not found. Run: make install"
    echo "ERROR: whisper-cli not found at $WHISPER_BIN. Run: make install" >&2
    exit 1
fi

if [ ! -f "$WHISPER_MODEL" ]; then
    notify-send "ask-kip" "Whisper model not found. Run: make install"
    echo "ERROR: Whisper model not found at $WHISPER_MODEL. Run: make install" >&2
    exit 1
fi

# ── Toggle ────────────────────────────────────────────────────────────────────

if [ -f "$LOCK_FILE" ]; then
    # Second press — stop recording
    ARECORD_PID=$(cat "$LOCK_FILE")
    kill "$ARECORD_PID" 2>/dev/null || true
    rm -f "$LOCK_FILE"

    notify-send "ask-kip" "Transcribing..."

    "$WHISPER_BIN" \
        -m "$WHISPER_MODEL" \
        -f "$AUDIO_FILE" \
        --no-timestamps \
        --language "$WHISPER_LANG" \
        -otxt \
        -of "$TRANSCRIPT_BASE" \
        2>/dev/null

    if [ ! -f "$TRANSCRIPT_FILE" ]; then
        notify-send "ask-kip" "Transcription failed — no output produced"
        exit 1
    fi

    TEXT=$(tr -d '\n' < "$TRANSCRIPT_FILE" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

    if [ -z "$TEXT" ]; then
        notify-send "ask-kip" "Nothing transcribed — try again"
        rm -f "$AUDIO_FILE" "$TRANSCRIPT_FILE"
        exit 0
    fi

    notify-send "ask-kip" "Sending: $TEXT"

    if ! SEND_ERR=$("$PYTHON" "$SEND_SCRIPT" send "$TEXT" 2>&1 >/dev/null); then
        notify-send "ask-kip" "Telegram send failed — run: make login"
        echo "ERROR: $SEND_ERR" >&2
        exit 1
    fi

    notify-send "ask-kip" "Sent ✓"
    rm -f "$AUDIO_FILE" "$TRANSCRIPT_FILE"

else
    # First press — start recording
    notify-send "ask-kip" "Recording... (press hotkey again to send)"

    arecord -f S16_LE -r 16000 -c 1 "$AUDIO_FILE" &
    echo $! > "$LOCK_FILE"
fi
