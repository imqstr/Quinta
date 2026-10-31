#ifndef QUINTA_WAYLAND_COORDINATES_H
#define QUINTA_WAYLAND_COORDINATES_H
typedef struct { double x, y; } QuintaWaylandPoint;
typedef struct { double width, height; } QuintaWaylandSize;
typedef struct { QuintaWaylandPoint origin; QuintaWaylandSize size; } QuintaWaylandRect;

/* Wayland exposes logical coordinates within the client surface. Preserve
 * Cocoa's virtual window origin: compositor placement is not discoverable. */
static inline QuintaWaylandPoint quinta_wayland_cocoa_point(
        QuintaWaylandPoint local, QuintaWaylandRect window) {
    return (QuintaWaylandPoint){window.origin.x + local.x,
                                 window.origin.y + window.size.height - local.y};
}
static inline int quinta_wayland_local_warp(QuintaWaylandPoint quartz,
        QuintaWaylandRect window, double screen_height, QuintaWaylandPoint *local) {
    double x = quartz.x - window.origin.x;
    double y = quartz.y - (screen_height - window.origin.y - window.size.height);
    if (!__builtin_isfinite(x) || !__builtin_isfinite(y) || x < 0 || y < 0 ||
        x >= window.size.width || y >= window.size.height) return 0;
    *local = (QuintaWaylandPoint){x, y};
    return 1;
}
#endif
