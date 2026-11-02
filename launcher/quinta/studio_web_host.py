"""WebKit host process for the native Studio launcher."""
import os
import signal
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gtk

from .web import WebBridge


def main():
    Gtk.init()
    Adw.init()
    bridge = WebBridge(None)
    loop = GLib.MainLoop()
    owner = os.getppid()

    def check_owner():
        if os.getppid() != owner:
            loop.quit()
            return GLib.SOURCE_REMOVE
        return GLib.SOURCE_CONTINUE

    GLib.timeout_add_seconds(1, check_owner)
    signal.signal(signal.SIGTERM, lambda *_: GLib.idle_add(loop.quit))
    signal.signal(signal.SIGINT, lambda *_: GLib.idle_add(loop.quit))
    print(bridge.guest_path, flush=True)
    try:
        loop.run()
    finally:
        bridge.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
