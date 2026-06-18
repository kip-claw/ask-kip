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

# ── Load config ───────────────────────────────────────────────────────────────

if [ ! -f "$ENV_FILE" ]; then
    notify-send "ask-kip" "Missing .env file. Copy .env.example and fill in your values."
    echo "ERROR: Missing .env file at $ENV_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

: "${BOT_TOKEN:?BOT_TOKEN is not set in .env}"
: "${CHAT_ID:?CHAT_ID is not set in .env}"
: "${WHISPER_MODEL_PATH:=$WHISPER_MODEL}"
: "${WHISPER_LANG:=en}"

WHISPER_MODEL="$WHISPER_MODEL_PATH"

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

    RESPONSE=$(curl -s -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${TEXT}")

    OK=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ok',''))" 2>/dev/null)

    if [ "$OK" != "True" ]; then
        notify-send "ask-kip" "Telegram send failed — check BOT_TOKEN in .env"
        echo "ERROR: Telegram API response: $RESPONSE" >&2
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
