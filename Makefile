.PHONY: install build-whisper download-model setup-telegram login check test install-hotkey clean help

WHISPER_DIR := whisper.cpp
WHISPER_BIN := $(WHISPER_DIR)/build/bin/whisper-cli
WHISPER_MODEL := $(WHISPER_DIR)/models/ggml-base.en.bin
MODEL_NAME := base.en
VENV := .venv
PYTHON := $(VENV)/bin/python
SEND_SCRIPT := send_message.py
SCRIPT := $(abspath ask-kip.sh)
HOTKEY_NAME := Ask Kip
HOTKEY_BINDING := <Super>k
HOTKEY_KEY := custom0

help:
	@echo "ask-kip — voice query interface for Kip / OpenClaw"
	@echo ""
	@echo "Targets:"
	@echo "  make install          Build whisper.cpp, download the model, set up Telethon"
	@echo "  make login            Log in to Telegram as yourself (one-time, interactive)"
	@echo "  make install-hotkey   Bind Super+K to ask-kip in GNOME (requires install first)"
	@echo "  make test             Verify config, mic, and Telegram login"
	@echo "  make build-whisper    Build whisper.cpp only"
	@echo "  make download-model   Download the Whisper model only"
	@echo "  make setup-telegram   Create the Python venv and install Telethon"
	@echo "  make check            Verify all system dependencies are present"
	@echo "  make clean            Remove build artifacts (keeps model)"

install: check build-whisper download-model setup-telegram
	@echo ""
	@echo "✓ ask-kip is ready."
	@echo ""
	@echo "Next steps:"
	@echo "  1. Copy .env.example to .env and fill in your values"
	@echo "  2. Run: make login            (log in to Telegram as yourself)"
	@echo "  3. Run: make install-hotkey   (GNOME, binds Super+K)"
	@echo "     Or bind $(SCRIPT) manually in your desktop environment."
	@echo "  See README.md for details."

install-hotkey:
	@if [ ! -f .env ]; then \
		echo "ERROR: .env not found. Copy .env.example and fill in your values first."; \
		exit 1; \
	fi
	@if ! command -v gsettings >/dev/null 2>&1; then \
		echo "ERROR: gsettings not found — is this a GNOME session?"; \
		exit 1; \
	fi
	@echo "Binding Super+K to ask-kip in GNOME..."
	@EXISTING=$$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings); \
	if echo "$$EXISTING" | grep -q "ask-kip"; then \
		echo "✓ Hotkey already registered, updating..."; \
	fi
	gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
		"['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/$(HOTKEY_KEY)/']"
	gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/$(HOTKEY_KEY)/ \
		name "$(HOTKEY_NAME)"
	gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/$(HOTKEY_KEY)/ \
		command "$(SCRIPT)"
	gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/$(HOTKEY_KEY)/ \
		binding "$(HOTKEY_BINDING)"
	@echo "✓ Super+K bound to $(SCRIPT)"
	@echo "  Test it: press Super+K, speak, press Super+K again."

test:
	@echo "=== ask-kip self-test ==="
	@echo ""
	@echo "1. Checking system dependencies..."
	@command -v arecord  >/dev/null 2>&1 && echo "   ✓ arecord"    || echo "   ✗ arecord missing — sudo apt install alsa-utils"
	@command -v curl     >/dev/null 2>&1 && echo "   ✓ curl"       || echo "   ✗ curl missing — sudo apt install curl"
	@command -v python3  >/dev/null 2>&1 && echo "   ✓ python3"    || echo "   ✗ python3 missing — sudo apt install python3"
	@command -v notify-send >/dev/null 2>&1 && echo "   ✓ notify-send" || echo "   ✗ notify-send missing — sudo apt install libnotify-bin"
	@echo ""
	@echo "2. Checking whisper.cpp build..."
	@if [ -f "$(WHISPER_BIN)" ]; then \
		echo "   ✓ whisper-cli present"; \
	else \
		echo "   ✗ whisper-cli not found — run: make build-whisper"; \
	fi
	@if [ -f "$(WHISPER_MODEL)" ]; then \
		echo "   ✓ Whisper model present"; \
	else \
		echo "   ✗ Model not found — run: make download-model"; \
	fi
	@echo ""
	@echo "3. Checking Telethon + .env..."
	@if [ -x "$(PYTHON)" ] && $(PYTHON) -c "import telethon" >/dev/null 2>&1; then \
		echo "   ✓ Telethon installed"; \
	else \
		echo "   ✗ Telethon not installed — run: make setup-telegram"; \
	fi
	@if [ ! -f .env ]; then \
		echo "   ✗ .env not found — copy .env.example and fill in your values"; \
		exit 1; \
	fi
	@. ./.env; \
	if [ -z "$${TELEGRAM_API_ID:-}" ]; then \
		echo "   ✗ TELEGRAM_API_ID is not set in .env"; \
	else \
		echo "   ✓ TELEGRAM_API_ID is set"; \
	fi; \
	if [ -z "$${TELEGRAM_API_HASH:-}" ]; then \
		echo "   ✗ TELEGRAM_API_HASH is not set in .env"; \
	else \
		echo "   ✓ TELEGRAM_API_HASH is set"; \
	fi; \
	if [ -z "$${KIP_TARGET:-}" ]; then \
		echo "   ✗ KIP_TARGET is not set in .env"; \
	else \
		echo "   ✓ KIP_TARGET is set"; \
	fi
	@echo ""
	@echo "4. Checking Telegram login..."
	@if [ ! -x "$(PYTHON)" ]; then \
		echo "   ✗ Python venv missing — run: make setup-telegram"; \
	else \
		set -a; . ./.env; set +a; \
		if $(PYTHON) -c "import os, sys; from telethon.sync import TelegramClient; s=os.environ.get('TELEGRAM_SESSION') or '.telegram.session'; c=TelegramClient(s, int(os.environ['TELEGRAM_API_ID']), os.environ['TELEGRAM_API_HASH']); c.connect(); ok=c.is_user_authorized(); c.disconnect(); sys.exit(0 if ok else 1)" >/dev/null 2>&1; then \
			echo "   ✓ Logged in to Telegram"; \
		else \
			echo "   ✗ Not logged in — run: make login"; \
		fi; \
	fi
	@echo ""
	@echo "5. Checking mic (recording 2 seconds of silence)..."
	@arecord -f S16_LE -r 16000 -c 1 -d 2 /tmp/ask-kip-test.wav -q 2>/dev/null && \
		echo "   ✓ Mic recorded successfully" || \
		echo "   ✗ Mic recording failed — check arecord -l for available devices"
	@rm -f /tmp/ask-kip-test.wav
	@echo ""
	@echo "=== Self-test complete ==="

check:
	@echo "Checking dependencies..."
	@command -v git     >/dev/null 2>&1 || { echo "ERROR: git is required. sudo apt install git"; exit 1; }
	@command -v cmake   >/dev/null 2>&1 || { echo "ERROR: cmake is required. sudo apt install cmake"; exit 1; }
	@command -v make    >/dev/null 2>&1 || { echo "ERROR: make is required. sudo apt install build-essential"; exit 1; }
	@command -v arecord >/dev/null 2>&1 || { echo "ERROR: arecord is required. sudo apt install alsa-utils"; exit 1; }
	@command -v curl    >/dev/null 2>&1 || { echo "ERROR: curl is required. sudo apt install curl"; exit 1; }
	@command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required. sudo apt install python3"; exit 1; }
	@command -v notify-send >/dev/null 2>&1 || { echo "ERROR: notify-send is required. sudo apt install libnotify-bin"; exit 1; }
	@echo "✓ All dependencies present."

build-whisper:
	@if [ -f "$(WHISPER_BIN)" ]; then \
		echo "✓ whisper-cli already built, skipping."; \
	else \
		echo "Cloning whisper.cpp..."; \
		git clone --depth 1 https://github.com/ggerganov/whisper.cpp $(WHISPER_DIR); \
		echo "Building whisper.cpp (this takes a few minutes)..."; \
		cmake -B $(WHISPER_DIR)/build $(WHISPER_DIR); \
		cmake --build $(WHISPER_DIR)/build --config Release -j$$(nproc); \
		echo "✓ whisper-cli built."; \
	fi

download-model:
	@if [ -f "$(WHISPER_MODEL)" ]; then \
		echo "✓ Model already present, skipping."; \
	else \
		echo "Downloading Whisper model ($(MODEL_NAME), ~140MB)..."; \
		bash $(WHISPER_DIR)/models/download-ggml-model.sh $(MODEL_NAME); \
		echo "✓ Model downloaded."; \
	fi

setup-telegram:
	@if [ ! -d "$(VENV)" ]; then \
		echo "Creating Python venv at $(VENV)..."; \
		python3 -m venv $(VENV); \
	fi
	@echo "Installing Telethon..."
	@$(PYTHON) -m pip install --quiet --upgrade pip
	@$(PYTHON) -m pip install --quiet telethon
	@echo "✓ Telethon installed."

login:
	@if [ ! -x "$(PYTHON)" ]; then \
		echo "ERROR: Python venv not found — run: make setup-telegram"; \
		exit 1; \
	fi
	@if [ ! -f .env ]; then \
		echo "ERROR: .env not found. Copy .env.example and fill in your values first."; \
		exit 1; \
	fi
	@echo "Logging in to Telegram as yourself (interactive)..."
	@set -a; . ./.env; set +a; $(PYTHON) $(SEND_SCRIPT) login

clean:
	@echo "Removing build artifacts..."
	rm -rf $(WHISPER_DIR)/build
	@echo "✓ Clean. Run 'make build-whisper' to rebuild."
	@echo "  (Model at $(WHISPER_MODEL) was preserved.)"
