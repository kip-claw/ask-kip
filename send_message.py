#!/usr/bin/env python3
"""Send a Telegram message as your own user account via MTProto (Telethon).

Unlike the Bot API, this posts the message authored by *you*, so Kip sees it
as a query from you instead of a message from the bot.

Usage:
    send_message.py login            Interactive one-time login (creates session)
    send_message.py send "text"      Send a message (non-interactive)
    send_message.py send             Read message text from stdin

Configuration is read from environment variables (loaded from .env by the
caller):
    TELEGRAM_API_ID     Your api_id   from https://my.telegram.org
    TELEGRAM_API_HASH   Your api_hash from https://my.telegram.org
    KIP_TARGET          Where to send: the Kip bot @username or a numeric chat id
    TELEGRAM_SESSION    Path to the Telethon session file (optional)
"""

import os
import sys

try:
    from telethon.errors import RPCError
    from telethon.sync import TelegramClient
except ImportError:
    sys.stderr.write("ERROR: Telethon is not installed. Run: make install\n")
    sys.exit(2)


def _require_env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        sys.stderr.write(f"ERROR: {name} is not set in .env\n")
        sys.exit(2)
    return value


def _client():
    api_id = _require_env("TELEGRAM_API_ID")
    api_hash = _require_env("TELEGRAM_API_HASH")
    try:
        api_id = int(api_id)
    except ValueError:
        sys.stderr.write("ERROR: TELEGRAM_API_ID must be a number\n")
        sys.exit(2)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    session = os.environ.get("TELEGRAM_SESSION", "").strip() or os.path.join(
        script_dir, ".telegram.session"
    )
    return TelegramClient(session, api_id, api_hash)


def _resolve_target(raw):
    raw = raw.strip()
    # Numeric chat ids (including negative ids for groups) are passed as ints.
    try:
        return int(raw)
    except ValueError:
        return raw


def do_login():
    client = _client()
    # start() prompts for phone number, login code, and 2FA password if needed.
    client.start()
    me = client.get_me()
    handle = getattr(me, "username", None) or me.first_name
    client.disconnect()
    print(f"\u2713 Logged in as {handle}. Session saved.")


def do_send(text):
    target = _resolve_target(_require_env("KIP_TARGET"))
    client = _client()
    client.connect()
    if not client.is_user_authorized():
        client.disconnect()
        sys.stderr.write("ERROR: Not logged in. Run: make login\n")
        sys.exit(3)
    try:
        client.send_message(target, text)
    except RPCError as exc:
        client.disconnect()
        sys.stderr.write(f"ERROR: Telegram send failed: {exc}\n")
        sys.exit(1)
    client.disconnect()


def main(argv):
    if len(argv) < 2 or argv[1] not in ("login", "send"):
        sys.stderr.write(__doc__)
        return 2

    if argv[1] == "login":
        do_login()
        return 0

    # send
    if len(argv) >= 3:
        text = argv[2]
    else:
        text = sys.stdin.read()
    text = text.strip()
    if not text:
        sys.stderr.write("ERROR: No message text provided\n")
        return 1
    do_send(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
