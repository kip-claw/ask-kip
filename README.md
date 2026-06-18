# ask-kip

[![CI](https://github.com/kip-claw/ask-kip/actions/workflows/ci.yml/badge.svg)](https://github.com/kip-claw/ask-kip/actions/workflows/ci.yml)

A hotkey-triggered voice query tool for [Kip](https://github.com/kip-claw) and [OpenClaw](https://openclaw.ai). Press a hotkey to start recording, press it again to transcribe and send your query to your Kip agent via Telegram.

**Pipeline:**
Hotkey → mic recording → [whisper.cpp](https://github.com/ggerganov/whisper.cpp) transcription → Telegram Bot API → Kip responds in Telegram

No cloud STT. No always-on process. No GPU required.

---

## Requirements

- Linux with GNOME (or any desktop environment that supports custom hotkey commands)
- `build-essential`, `cmake`, `curl`, `python3`, `arecord` (alsa-utils), `libnotify-bin`
- A Kip / OpenClaw instance with a Telegram bot configured
- Your Telegram bot token and chat ID

Install dependencies on Ubuntu/Debian:

```bash
sudo apt install build-essential cmake curl python3 alsa-utils libnotify-bin
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

---

## Configuration

Copy the example config and fill in your values:

```bash
cp .env.example .env
nano .env
```

Set `BOT_TOKEN` to your OpenClaw Telegram bot token and `CHAT_ID` to your Telegram user ID. Everything else is optional.

`.env` is gitignored and will never be committed.

---

## Bind a Hotkey

### GNOME (automated)

```bash
make install-hotkey
```

This binds `Super+K` to `ask-kip.sh` using `gsettings`. Requires a `.env` file to be present first.

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

---

## Makefile targets

| Target | Description |
|---|---|
| `make install` | Full install: check deps, build whisper.cpp, download model |
| `make install-hotkey` | Bind Super+K to ask-kip in GNOME |
| `make test` | Verify config, mic, and Telegram credentials without sending |
| `make build-whisper` | Build whisper.cpp only |
| `make download-model` | Download the Whisper model only |
| `make check` | Verify all system dependencies are present |
| `make clean` | Remove build artifacts (preserves downloaded model) |

---

## Troubleshooting

**No notification on hotkey press** — confirm `libnotify-bin` is installed and the path in your hotkey config is absolute. Run `make test` to check the full setup.

**`arecord` captures silence** — run `arecord -l` to list capture devices. If your mic isn't the default, add `-D hw:X,Y` to the `arecord` line in `ask-kip.sh`.

**Transcription is garbled** — check mic input level in your system sound settings. Speak clearly and leave a brief pause before and after your query.

**Telegram send fails** — run `make test` to validate your token. Confirm `BOT_TOKEN` in `.env` is correct and has no trailing whitespace.

**Lock file stuck after a crash** — clear it:
```bash
rm -f /tmp/ask-kip-recording.lock
```

---

## License

MIT
