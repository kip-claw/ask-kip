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
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
ENV_FILE="$SCRIPT_DIR/.env"

LOCK_FILE="/tmp/ask-kip-recording.lock"
AUDIO_FILE="/tmp/ask-kip-query.wav"
TRANSCRIPT_BASE="/tmp/ask-kip-query"
TRANSCRIPT_FILE="${TRANSCRIPT_BASE}.txt"

WHISPER_BIN="$SCRIPT_DIR/whisper.cpp/build/bin/whisper-cli"
WHISPER_SERVER_BIN="$SCRIPT_DIR/whisper.cpp/build/bin/whisper-server"
WHISPER_MODEL="$SCRIPT_DIR/whisper.cpp/models/ggml-base.en.bin"

SEND_SCRIPT="$SCRIPT_DIR/send_message.py"
VENV_PYTHON="$SCRIPT_DIR/.venv/bin/python"

GROWL_SCRIPT="$SCRIPT_DIR/growl.py"
# growl.py needs a Python with PyGObject (GTK 3); the project venv usually
# doesn't have it, so prefer the system interpreter.
GROWL_PYTHON="$(command -v /usr/bin/python3 || command -v python3 || true)"
GROWL_OK=0
if [ -f "$GROWL_SCRIPT" ] && [ -n "$GROWL_PYTHON" ] && \
    "$GROWL_PYTHON" -c "import gi" >/dev/null 2>&1; then
    GROWL_OK=1
fi

# ── Logging ───────────────────────────────────────────────────────────────────

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ask-kip"
LOG_FILE="$LOG_DIR/ask-kip.log"
WHISPER_SERVER_LOG="$LOG_DIR/whisper-server.log"

# log — append a timestamped line to the log file. Best effort; never fatal,
# since the script usually runs from a hotkey where stderr is invisible.
log() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# ── Sound cues ────────────────────────────────────────────────────────────────

# Freedesktop event sounds played when recording starts and stops. The canberra
# event id and the matching .oga filename share these names. Kept short so the
# cue ends well before the next button press.
CUE_START="bell"
CUE_STOP="message"

# play_cue — play a short, non-blocking sound cue. Best effort; never fatal.
play_cue() {
    [ "${SOUND_CUES:-1}" = "1" ] || return 0
    local event="$1"
    local file="/usr/share/sounds/freedesktop/stereo/${event}.oga"
    {
        if command -v canberra-gtk-play >/dev/null 2>&1; then
            canberra-gtk-play -i "$event"
        elif command -v pw-play >/dev/null 2>&1; then
            pw-play "$file"
        elif command -v paplay >/dev/null 2>&1; then
            paplay "$file"
        elif command -v aplay >/dev/null 2>&1; then
            aplay -q "$file"
        fi
    } </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# ── Notifications ─────────────────────────────────────────────────────────────

# notify — show a Growl-style popup in the top-right corner instead of letting
# the message collapse into GNOME's notification list. Falls back to
# notify-send if the popup helper or a GTK-capable Python isn't available.
notify() {
    local title="$1" body="$2"
    if [ "$GROWL_OK" -eq 1 ]; then
        GDK_BACKEND=x11 setsid "$GROWL_PYTHON" "$GROWL_SCRIPT" "$title" "$body" \
            </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
    else
        notify-send "$title" "$body"
    fi
}

# ── Load config ────────────────────────────────────────────────────────────────────────────────────

if [ ! -f "$ENV_FILE" ]; then
    log "Missing .env file at $ENV_FILE"
    notify "ask-kip" "Missing .env file. Copy .env.example and fill in your values."
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
# Safety cap so a forgotten recording can't run forever and fill /tmp.
# Long by design (default 1 hour); override MAX_RECORD_SECONDS in .env.
: "${MAX_RECORD_SECONDS:=3600}"
# Set SOUND_CUES=0 in .env to silence the start/stop sound cues.
: "${SOUND_CUES:=1}"
# Keep a warm whisper-server running so the model isn't reloaded on every press.
# Set WHISPER_SERVER=0 in .env to always use the one-shot whisper-cli instead.
: "${WHISPER_SERVER:=1}"
: "${WHISPER_HOST:=127.0.0.1}"
: "${WHISPER_PORT:=8642}"

export TELEGRAM_API_ID TELEGRAM_API_HASH KIP_TARGET
export TELEGRAM_SESSION="${TELEGRAM_SESSION:-}"

WHISPER_MODEL="$WHISPER_MODEL_PATH"

# ── Internal: recording watchdog ──────────────────────────────────────────────
# Spawned in the background when recording starts. If the user never presses the
# hotkey again, it auto-stops and discards the recording once the cap is hit.
if [[ "${1:-}" == "--watchdog" ]]; then
    target_pid="${2:-}"
    sleep "$MAX_RECORD_SECONDS"
    if [ -f "$LOCK_FILE" ] && [ "$(cat "$LOCK_FILE" 2>/dev/null)" = "$target_pid" ] \
        && kill -0 "$target_pid" 2>/dev/null; then
        kill "$target_pid" 2>/dev/null || true
        pkill -f "arecord.*$AUDIO_FILE" 2>/dev/null || true
        rm -f "$LOCK_FILE" "$AUDIO_FILE" "$TRANSCRIPT_FILE"
        play_cue "$CUE_STOP"
        log "Auto-stopped recording after ${MAX_RECORD_SECONDS}s (pid $target_pid); discarded"
        notify "ask-kip" "Recording stopped — reached the ${MAX_RECORD_SECONDS}s limit. Discarded."
    fi
    exit 0
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────
# Always remove the transcript on exit. The audio file is kept while a recording
# is in progress (it lives across the two hotkey presses) and only removed once
# we're processing it (KEEP_AUDIO=0).
KEEP_AUDIO=1
cleanup() {
    rm -f "$TRANSCRIPT_FILE"
    [ "$KEEP_AUDIO" -eq 0 ] && rm -f "$AUDIO_FILE"
    return 0
}
trap cleanup EXIT

if [ -x "$VENV_PYTHON" ]; then
    PYTHON="$VENV_PYTHON"
else
    PYTHON="python3"
fi

# ── Sanity checks ─────────────────────────────────────────────────────────────

if [ ! -f "$WHISPER_BIN" ]; then
    log "whisper-cli not found at $WHISPER_BIN"
    notify "ask-kip" "whisper-cli not found. Run: make install"
    echo "ERROR: whisper-cli not found at $WHISPER_BIN. Run: make install" >&2
    exit 1
fi

if [ ! -f "$WHISPER_MODEL" ]; then
    log "Whisper model not found at $WHISPER_MODEL"
    notify "ask-kip" "Whisper model not found. Run: make install"
    echo "ERROR: Whisper model not found at $WHISPER_MODEL. Run: make install" >&2
    exit 1
fi

# ── Transcription ─────────────────────────────────────────────────────────

SERVER_URL="http://${WHISPER_HOST}:${WHISPER_PORT}"

# server_ready — true if the warm whisper-server answers on its port. Any HTTP
# response counts (even 404); only a refused/absent connection is "not ready".
server_ready() {
    curl -s -o /dev/null -m 1 "$SERVER_URL/" 2>/dev/null
}

# ensure_server — make sure a warm whisper-server is up, starting it detached on
# first use. Returns 0 when ready, 1 if disabled, missing, or slow to start (the
# caller then falls back to whisper-cli).
ensure_server() {
    [ "$WHISPER_SERVER" = "1" ] || return 1
    [ -x "$WHISPER_SERVER_BIN" ] || return 1
    if server_ready; then
        return 0
    fi
    log "Starting warm whisper-server on ${WHISPER_HOST}:${WHISPER_PORT}"
    setsid "$WHISPER_SERVER_BIN" \
        -m "$WHISPER_MODEL" \
        -l "$WHISPER_LANG" \
        --host "$WHISPER_HOST" \
        --port "$WHISPER_PORT" \
        --no-timestamps \
        </dev/null >>"$WHISPER_SERVER_LOG" 2>&1 &
    disown 2>/dev/null || true
    # Wait for the model to load and the port to open (up to ~20s).
    for _ in $(seq 1 40); do
        if server_ready; then
            return 0
        fi
        sleep 0.5
    done
    log "whisper-server did not become ready in time"
    return 1
}

# transcribe AUDIO BASE — write the transcript to BASE.txt. Prefers the warm
# server and falls back to the one-shot whisper-cli if it's unavailable.
transcribe() {
    local audio="$1" base="$2" out="${2}.txt"
    if ensure_server; then
        if curl -fsS -m 120 \
                -F file="@${audio}" \
                -F temperature="0.0" \
                -F response_format="text" \
                "$SERVER_URL/inference" -o "$out" 2>>"$WHISPER_SERVER_LOG"; then
            log "Transcribed via warm whisper-server"
            return 0
        fi
        log "whisper-server request failed; falling back to whisper-cli"
    fi
    log "Transcribing via whisper-cli"
    "$WHISPER_BIN" \
        -m "$WHISPER_MODEL" \
        -f "$audio" \
        --no-timestamps \
        --language "$WHISPER_LANG" \
        -otxt \
        -of "$base" \
        2>/dev/null
}

# ── Toggle ────────────────────────────────────────────────────────────────────

if [ -f "$LOCK_FILE" ]; then
    # Second press — stop recording
    KEEP_AUDIO=0
    ARECORD_PID=$(cat "$LOCK_FILE")
    rm -f "$LOCK_FILE"
    kill "$ARECORD_PID" 2>/dev/null || true
    # Safety net: stop any other stray ask-kip recorders
    pkill -f "arecord.*$AUDIO_FILE" 2>/dev/null || true
    # Wait for the recorder to flush and finalize the WAV header
    for _ in $(seq 1 20); do
        kill -0 "$ARECORD_PID" 2>/dev/null || break
        sleep 0.1
    done
    play_cue "$CUE_STOP"
    log "Recording stopped; transcribing"

    notify "ask-kip" "Transcribing..."

    transcribe "$AUDIO_FILE" "$TRANSCRIPT_BASE"

    if [ ! -f "$TRANSCRIPT_FILE" ]; then
        log "Transcription failed — no output produced"
        notify "ask-kip" "Transcription failed — no output produced"
        exit 1
    fi

    TEXT=$(tr -d '\n' < "$TRANSCRIPT_FILE" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

    # Whisper emits placeholder markers like [BLANK_AUDIO] or [ Silence ] when
    # the recording has no speech. Strip those out so a silent take counts as
    # empty and nothing is sent.
    STRIPPED=$(printf '%s' "$TEXT" \
        | sed -E 's/\[[[:space:]]*(BLANK_AUDIO|SILENCE|silence|Silence|blank|BLANK|inaudible|INAUDIBLE|music|MUSIC|Music|sound|SOUND|noise|NOISE)[[:space:]]*\]//g' \
        | sed -E 's/\([[:space:]]*(blank|silence|inaudible|no audio|no speech)[[:space:]]*\)//gI' \
        | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

    if [ -z "$STRIPPED" ]; then
        log "Nothing transcribed (blank audio)"
        notify "ask-kip" "Nothing transcribed — try again"
        exit 0
    fi

    log "Sending: $STRIPPED"
    notify "ask-kip" "Sending: $STRIPPED"

    if ! SEND_ERR=$("$PYTHON" "$SEND_SCRIPT" send "$STRIPPED" 2>&1 >/dev/null); then
        log "Telegram send failed: $SEND_ERR"
        notify "ask-kip" "Telegram send failed — run: make login"
        echo "ERROR: $SEND_ERR" >&2
        exit 1
    fi

    log "Sent"
    notify "ask-kip" "Sent ✓"

else
    # First press — start recording
    # Clean up any orphaned recorder left behind by a previous run
    pkill -f "arecord.*$AUDIO_FILE" 2>/dev/null || true
    rm -f "$LOCK_FILE"

    notify "ask-kip" "Recording... (press hotkey again to send)"
    play_cue "$CUE_START"
    log "Recording started (max ${MAX_RECORD_SECONDS}s)"

    arecord -f S16_LE -r 16000 -c 1 "$AUDIO_FILE" &
    AR_PID=$!
    echo "$AR_PID" > "$LOCK_FILE"

    # Watchdog: auto-stop and discard if the hotkey is never pressed again.
    setsid "$SELF" --watchdog "$AR_PID" </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
fi
