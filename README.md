# ask-kip

[![CI](https://github.com/kip-claw/ask-kip/actions/workflows/ci.yml/badge.svg)](https://github.com/kip-claw/ask-kip/actions/workflows/ci.yml)

A hotkey-triggered voice query tool for [Kip](https://github.com/kip-claw) and [OpenClaw](https://openclaw.ai). Press a hotkey to start recording, press it again to transcribe and send your query to your Kip agent via Telegram.

Messages are sent from **your own Telegram account** (via MTProto), so Kip sees them as coming from you — not from a bot.

**Pipeline:**
Hotkey → mic recording → [whisper.cpp](https://github.com/ggerganov/whisper.cpp) transcription → Telegram (as you) → Kip responds in Telegram

No cloud STT. No always-on process. No GPU required.

---

## Requirements

- Linux with GNOME (or any desktop environment that supports custom hotkey commands)
- `build-essential`, `cmake`, `python3`, `python3-venv`, `arecord` (alsa-utils), `libnotify-bin`
- `python3-gi` + `gir1.2-gtk-3.0` for the Growl-style corner popup (falls back to `notify-send` if missing)
- A sound player for the start/stop cues — `libcanberra-gtk3-module`, `pipewire-bin`, or `alsa-utils` (optional; cues are skipped if none is present, or set `SOUND_CUES=0`)
- A Kip / OpenClaw instance reachable on Telegram
- Telegram API credentials (`api_id` + `api_hash`) from [my.telegram.org](https://my.telegram.org)

Install dependencies on Ubuntu/Debian:

```bash
sudo apt install build-essential cmake python3 python3-venv alsa-utils libnotify-bin python3-gi gir1.2-gtk-3.0
```

---

## Installation

```bash
git clone https://github.com/kip-claw/ask-kip.git
cd ask-kip
make install
```

`make install` will:

1. Check that all system dependencies are present
2. Clone and build `whisper.cpp`
3. Download the `base.en` Whisper model (~140MB)
4. Create a Python virtualenv and install Telethon

---

## Configuration

Copy the example config and fill in your values:

```bash
cp .env.example .env
nano .env
```

Set `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` to the credentials you create at
[my.telegram.org](https://my.telegram.org) → **API development tools**. Set
`KIP_TARGET` to your Kip bot's `@username` (or a numeric chat id) — that's where
your voice queries are sent. Everything else is optional.

`.env` is gitignored and will never be committed.

---

## Log in to Telegram

Log in once as yourself to create a private session file:

```bash
make login
```

You'll be prompted for your phone number, the login code Telegram sends you, and
your 2FA password if you have one. This writes `.telegram.session` (gitignored).
Messages are then sent from your account, so Kip sees them as coming from you.

---

## Bind a Hotkey

### GNOME (automated)

```bash
make install-hotkey
```

This binds `Super+K` to `ask-kip.sh` using `gsettings`. Requires a `.env` file and a completed `make login` first.

### GNOME (manual)

**Settings → Keyboard → Keyboard Shortcuts → View and Customize Shortcuts → Custom Shortcuts → +**

- **Name:** `Ask Kip`
- **Command:** `/full/path/to/ask-kip/ask-kip.sh`
- **Shortcut:** `Super+K` (or your preference)

### Other desktop environments

Any hotkey system that can run a shell command works. Point it at the absolute path to `ask-kip.sh`.

---

## Usage

1. Press `Super+K` — a notification appears: **"Recording..."**
2. Speak your query
3. Press `Super+K` again — notifications appear: **"Transcribing..."** then **"Sending: [your text]"** then **"Sent ✓"**
4. Kip responds in Telegram

If a recording is accidentally left open, pressing the hotkey will stop it. You can also clear it manually:

```bash
rm -f /tmp/ask-kip-recording.lock /tmp/ask-kip-query.*
```

---

## Whisper Models

The default `base.en` model (~140MB) transcribes a 10-second clip in roughly 3–8 seconds on a CPU-only machine. If you want better accuracy at the cost of speed, download a larger model and set `WHISPER_MODEL_PATH` in `.env`:

```bash
bash whisper.cpp/models/download-ggml-model.sh small.en   # ~460MB, ~2x slower
bash whisper.cpp/models/download-ggml-model.sh medium.en  # ~1.5GB, ~5x slower
```

### Warm Whisper server

By default ask-kip keeps `whisper-server` running in the background so the model
stays loaded between presses, avoiding a model reload on every query. The server
is started lazily on first use (so the first query after a reboot is slower) and
binds to `127.0.0.1` only. If it's unavailable for any reason, ask-kip
automatically falls back to the one-shot `whisper-cli`.

Tune it in `.env` with `WHISPER_SERVER` (set `0` to disable), `WHISPER_HOST`, and
`WHISPER_PORT`. Server logs are written to `~/.local/state/ask-kip/whisper-server.log`.

---

## Makefile targets

| Target                | Description                                                                  |
| --------------------- | ---------------------------------------------------------------------------- |
| `make install`        | Full install: check deps, build whisper.cpp, download model, set up Telethon |
| `make login`          | Log in to Telegram as yourself (one-time, interactive)                       |
| `make install-hotkey` | Bind Super+K to ask-kip in GNOME                                             |
| `make test`           | Verify config, mic, and Telegram login without sending                       |
| `make build-whisper`  | Build whisper.cpp only                                                       |
| `make download-model` | Download the Whisper model only                                              |
| `make setup-telegram` | Create the Python venv and install Telethon                                  |
| `make check`          | Verify all system dependencies are present                                   |
| `make clean`          | Remove build artifacts (preserves downloaded model)                          |

---

## Troubleshooting

**No notification on hotkey press** — confirm `libnotify-bin` is installed and the path in your hotkey config is absolute. Run `make test` to check the full setup.

**Popups appear in GNOME's notification list instead of the corner** — the Growl-style bubble needs `python3-gi` and `gir1.2-gtk-3.0`. Without them the script falls back to `notify-send`, whose banners collapse into the notification list.

**`arecord` captures silence** — run `arecord -l` to list capture devices. If your mic isn't the default, add `-D hw:X,Y` to the `arecord` line in `ask-kip.sh`.

**Transcription is garbled** — check mic input level in your system sound settings. Speak clearly and leave a brief pause before and after your query.

**Telegram send fails** — run `make test` to check your login state. If it reports "Not logged in," run `make login`. Confirm `TELEGRAM_API_ID`, `TELEGRAM_API_HASH`, and `KIP_TARGET` in `.env` are correct and have no trailing whitespace.

**Lock file stuck after a crash** — clear it:

```bash
rm -f /tmp/ask-kip-recording.lock
```

A forgotten recording also auto-stops on its own once `MAX_RECORD_SECONDS` (default 1 hour) is reached, discarding the audio.

**Nothing happens on hotkey press** — because the script runs from a hotkey, errors aren't visible on screen. Check the log:

```bash
tail -f ~/.local/state/ask-kip/ask-kip.log
```

---

## License

MIT
