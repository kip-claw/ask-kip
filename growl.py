#!/usr/bin/env python3
"""Growl-style corner popup for ask-kip.

Shows an undecorated, always-on-top notification bubble in the top-right
corner of the screen (the way the old Growl notifications worked) instead of
collapsing into GNOME's notification list.

Only one bubble is shown at a time: launching a new one replaces the previous
bubble so the messages read like a live status indicator.

Usage:
    growl.py "Title" "Body text" [timeout_seconds]

Run with the system Python that has PyGObject (e.g. /usr/bin/python3) and,
under Wayland, force the X11 backend (GDK_BACKEND=x11) so the window can be
positioned in the corner via XWayland.
"""

import os
import signal
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

PID_FILE = "/tmp/ask-kip-growl.pid"
MARGIN = 16
WIDTH = 360

CSS = b"""
.growl {
    background-color: rgba(28, 28, 30, 0.92);
    border-radius: 12px;
    border: 1px solid rgba(255, 255, 255, 0.12);
    padding: 14px 18px;
}
.growl-title {
    color: #ffffff;
    font-weight: bold;
    font-size: 12pt;
}
.growl-body {
    color: #e6e6e6;
    font-size: 11pt;
}
"""


def _replace_previous():
    """Kill any previously-shown bubble so only one is on screen."""
    try:
        with open(PID_FILE) as handle:
            old_pid = int(handle.read().strip())
    except (OSError, ValueError):
        old_pid = None

    if old_pid and old_pid != os.getpid():
        try:
            os.kill(old_pid, signal.SIGTERM)
        except OSError:
            pass

    try:
        with open(PID_FILE, "w") as handle:
            handle.write(str(os.getpid()))
    except OSError:
        pass


def _clear_pid():
    try:
        with open(PID_FILE) as handle:
            if int(handle.read().strip()) == os.getpid():
                os.remove(PID_FILE)
    except (OSError, ValueError):
        pass


def main(argv):
    title = argv[1] if len(argv) > 1 else "ask-kip"
    body = argv[2] if len(argv) > 2 else ""
    try:
        timeout = float(argv[3]) if len(argv) > 3 else 4.0
    except ValueError:
        timeout = 4.0

    _replace_previous()

    provider = Gtk.CssProvider()
    provider.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(),
        provider,
        Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    )

    window = Gtk.Window(type=Gtk.WindowType.POPUP)
    window.set_decorated(False)
    window.set_resizable(False)
    window.set_keep_above(True)
    window.set_skip_taskbar_hint(True)
    window.set_skip_pager_hint(True)
    window.set_accept_focus(False)
    window.set_focus_on_map(False)
    window.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
    window.set_size_request(WIDTH, -1)

    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
    box.get_style_context().add_class("growl")

    title_label = Gtk.Label(label=title, xalign=0)
    title_label.get_style_context().add_class("growl-title")
    title_label.set_line_wrap(True)
    box.pack_start(title_label, False, False, 0)

    if body:
        body_label = Gtk.Label(label=body, xalign=0)
        body_label.get_style_context().add_class("growl-body")
        body_label.set_line_wrap(True)
        body_label.set_max_width_chars(40)
        box.pack_start(body_label, False, False, 0)

    window.add(box)

    def position(*_args):
        display = Gdk.Display.get_default()
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        geo = monitor.get_geometry()
        win_width, _win_height = window.get_size()
        x = geo.x + geo.width - win_width - MARGIN
        y = geo.y + MARGIN
        window.move(x, y)

    window.connect("realize", position)
    window.connect("size-allocate", position)
    window.connect("destroy", lambda *_: Gtk.main_quit())
    window.show_all()
    position()

    GLib.timeout_add(int(timeout * 1000), window.destroy)
    for sig in (signal.SIGTERM, signal.SIGINT):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, window.destroy)

    try:
        Gtk.main()
    finally:
        _clear_pid()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
