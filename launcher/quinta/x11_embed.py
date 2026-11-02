"""Show a GTK window inside another client's X11 window.

Studio's sign-in dialog holds a web view that Darling cannot draw. The WebKit
host runs on X11 and reparents the page's window into the dialog's X11 window
at the web view's rectangle, so the page appears where Studio expects it and
moves with the dialog. Reparenting is plain X11; no toolkit embedding protocol
is involved, so keyboard focus is handed over explicitly on click.
"""

import ctypes
import ctypes.util

import gi

gi.require_version("GdkX11", "4.0")
from gi.repository import GdkX11  # noqa: E402

_REVERT_TO_PARENT = 2
_CURRENT_TIME = 0
_ERROR_HANDLER = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
_CLIENT_MESSAGE = 33
_NO_EVENT_MASK = 0


class _SyncValue(ctypes.Structure):
    _fields_ = [("hi", ctypes.c_int), ("lo", ctypes.c_uint)]


class _ClientMessage(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                ("format", ctypes.c_int), ("data", ctypes.c_long * 5)]


class _WindowAttributes(ctypes.Structure):
    _fields_ = [("background_pixmap", ctypes.c_ulong), ("background_pixel", ctypes.c_ulong),
                ("border_pixmap", ctypes.c_ulong), ("border_pixel", ctypes.c_ulong),
                ("bit_gravity", ctypes.c_int), ("win_gravity", ctypes.c_int), ("backing_store", ctypes.c_int),
                ("backing_planes", ctypes.c_ulong), ("backing_pixel", ctypes.c_ulong), ("save_under", ctypes.c_int),
                ("event_mask", ctypes.c_long), ("do_not_propagate_mask", ctypes.c_long),
                ("override_redirect", ctypes.c_int), ("colormap", ctypes.c_ulong), ("cursor", ctypes.c_ulong)]


_CW_OVERRIDE_REDIRECT = 1 << 9


class _Event(ctypes.Union):
    _fields_ = [("message", _ClientMessage), ("pad", ctypes.c_long * 24)]


class X11Embedder:
    """Own Xlib connection used only to place windows; errors are ignored."""

    def __init__(self):
        name = ctypes.util.find_library("X11") or "libX11.so.6"
        lib = ctypes.CDLL(name)
        lib.XOpenDisplay.restype = ctypes.c_void_p
        lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
        for function, arguments in (
            ("XReparentWindow", [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_int, ctypes.c_int]),
            ("XMoveResizeWindow", [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint]),
            ("XRaiseWindow", [ctypes.c_void_p, ctypes.c_ulong]),
            ("XSetInputFocus", [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]),
            ("XFlush", [ctypes.c_void_p]),
            ("XSendEvent", [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.POINTER(_Event)]),
            ("XGetWindowProperty", [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_long, ctypes.c_long,
                                    ctypes.c_int, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong),
                                    ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_ulong),
                                    ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_void_p)]),
            ("XFree", [ctypes.c_void_p]),
            ("XChangeWindowAttributes", [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.POINTER(_WindowAttributes)]),
        ):
            getattr(lib, function).argtypes = arguments
        lib.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        lib.XInternAtom.restype = ctypes.c_ulong
        sync = ctypes.CDLL(ctypes.util.find_library("Xext") or "libXext.so.6")
        sync.XSyncQueryCounter.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(_SyncValue)]
        self.sync = sync
        self.counters = {}
        lib.XSetErrorHandler.argtypes = [_ERROR_HANDLER]
        lib.XSetErrorHandler.restype = ctypes.c_void_p
        self.display = lib.XOpenDisplay(None)
        if not self.display:
            raise OSError("Cannot open the X11 display")
        self.lib = lib
        # A parent that disappears (dialog closed) must not end this process.
        self._handler = _ERROR_HANDLER(lambda _display, _event: 0)
        lib.XSetErrorHandler(self._handler)
        self.frame_drawn_atom = lib.XInternAtom(self.display, b"_NET_WM_FRAME_DRAWN", 0)
        self.counter_atom = lib.XInternAtom(self.display, b"_NET_WM_SYNC_REQUEST_COUNTER", 0)

    @staticmethod
    def window_id(window):
        surface = window.get_surface()
        return GdkX11.X11Surface.get_xid(surface) if isinstance(surface, GdkX11.X11Surface) else 0

    def place(self, child, parent, x, y, width, height, reparent):
        """Move `child` into `parent` at x, y; GTK keeps showing and hiding it."""
        if reparent:
            # The game's window selects SubstructureRedirect, which hands a
            # child's map and resize requests to the game; Darling ignores
            # them and the page stayed unmapped at 1x1. Override-redirect
            # windows bypass that.
            attributes = _WindowAttributes(override_redirect=1)
            self.lib.XChangeWindowAttributes(self.display, child, _CW_OVERRIDE_REDIRECT, ctypes.byref(attributes))
            self.lib.XReparentWindow(self.display, child, parent, x, y)
        self.lib.XMoveResizeWindow(self.display, child, x, y, max(1, width), max(1, height))
        self.lib.XRaiseWindow(self.display, child)
        self.lib.XFlush(self.display)

    def frame_drawn(self, child):
        """Acknowledge GTK's finished frames as a compositor would.

        GTK waits for _NET_WM_FRAME_DRAWN after each frame of a window the
        window manager manages. A reparented window has no manager, so without
        this the page froze after its first, empty frame.
        """
        counter, last = self.counters.get(child, (None, None))
        if counter is None:
            counter = self._extended_counter(child)
            if not counter:
                return
        value = _SyncValue()
        if not self.sync.XSyncQueryCounter(self.display, counter, ctypes.byref(value)):
            return
        current = (value.hi << 32) | value.lo
        self.counters[child] = (counter, current)
        if current == last or current % 2:
            return  # no new frame, or GTK is still drawing one
        event = _Event()
        event.message.type = _CLIENT_MESSAGE
        event.message.window = child
        event.message.message_type = self.frame_drawn_atom
        event.message.format = 32
        event.message.data[0] = current & 0xFFFFFFFF
        event.message.data[1] = current >> 32
        self.lib.XSendEvent(self.display, child, 0, _NO_EVENT_MASK, ctypes.byref(event))
        self.lib.XFlush(self.display)

    def forget(self, child):
        self.counters.pop(child, None)

    def _extended_counter(self, child):
        kind, size, count, after = ctypes.c_ulong(), ctypes.c_int(), ctypes.c_ulong(), ctypes.c_ulong()
        data = ctypes.c_void_p()
        if self.lib.XGetWindowProperty(self.display, child, self.counter_atom, 0, 2, 0, 0,
                                       ctypes.byref(kind), ctypes.byref(size), ctypes.byref(count),
                                       ctypes.byref(after), ctypes.byref(data)) or not data.value:
            return 0
        values = ctypes.cast(data, ctypes.POINTER(ctypes.c_ulong))
        counter = values[1] if count.value >= 2 else 0  # [basic, extended]
        self.lib.XFree(data)
        return counter

    def focus(self, child):
        self.lib.XSetInputFocus(self.display, child, _REVERT_TO_PARENT, _CURRENT_TIME)
        self.lib.XFlush(self.display)


def available():
    """Embedding works only when GTK itself runs on X11."""
    try:
        from gi.repository import Gdk

        return isinstance(Gdk.Display.get_default(), GdkX11.X11Display)
    except (ImportError, ValueError):
        return False
