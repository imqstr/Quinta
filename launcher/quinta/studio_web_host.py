"""WebKit host process for the game's and Studio's embedded pages."""
import os
import signal
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gtk

from .web import WebBridge


def main():
    # Wayland app ID: the window shows Quinta's icon (io.github.imqstr.Quinta.desktop).
    GLib.set_prgname("io.github.imqstr.Quinta")
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
    # The launcher reads one line: the guest socket path and WebKit's user agent,
    # which the game extends with its app name as macOS WebKit does.
    print(f"{bridge.guest_path}\t{bridge.user_agent}", flush=True)
    try:
        loop.run()
    finally:
        bridge.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
