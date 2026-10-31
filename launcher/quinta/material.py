"""Quinta's Material-inspired surfaces, typography and bundled icon theme."""
from pathlib import Path

import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, Gtk

ICON_ROOT = Path(__file__).resolve().parent / "assets/icons"


def install_icons():
    display = Gdk.Display.get_default()
    if display:
        icons = Gtk.IconTheme.get_for_display(display)
        root = str(ICON_ROOT)
        if root not in icons.get_search_path():
            icons.add_search_path(root)
        Gtk.Settings.get_default().set_property("gtk-icon-theme-name", "Quinta")


# Compact desktop tokens. Components reference these shared values.
COLORS = {
    "surface": "#17212d", "raised": "#25313e", "sunken": "#111b27",
    "hover": "#344353", "selected": "#3b4b5c", "border": "#485a6c",
    "strong": "#515c6b", "text": "#e5e9ef", "subtle": "#a9b2bf",
    "disabled": "#8c9baa", "accent": "#afd0e8", "accent_hover": "#d0e6f5",
    "accent_pressed": "#6fa2d3", "inverse": "#142a3f", "success": "#a7ceb0",
    "warning": "#dfc397", "danger": "#f0aaa4",
    "backdrop_a": "#12243a", "backdrop_b": "#17202d", "backdrop_c": "#27333e",
    "glass": "rgba(224,239,255,0.055)", "glass_hover": "rgba(224,239,255,0.10)",
    "glass_selected": "rgba(224,239,255,0.13)", "glass_border": "rgba(224,239,255,0.12)",
    "glass_highlight": "rgba(240,247,255,0.20)", "glass_sidebar": "rgba(9,17,28,0.36)",
}
TOKENS = {"radius_sm": 6, "radius_md": 10, "radius_lg": 16,
          "compact": 28, "normal": 36, "primary": 44,
          "s1": 4, "s2": 8, "s3": 12, "s4": 16, "s6": 24, "s8": 32,
          "caption": 12, "body": 14, "title": 20, "fast": 120}


def stylesheet():
    colors = {f"quinta_{name}": value for name, value in COLORS.items()}
    for prefix, surface in (("window", "surface"), ("view", "surface"),
                            ("headerbar", "surface"), ("sidebar", "sunken"),
                            ("card", "raised"), ("popover", "raised"), ("dialog", "raised")):
        colors[f"{prefix}_bg_color"] = COLORS[surface]
        colors[f"{prefix}_fg_color"] = COLORS["text"]
    colors["window_bg_color"] = "transparent"
    colors.update(headerbar_backdrop_color=COLORS["surface"],
                  headerbar_border_color=COLORS["border"], sidebar_backdrop_color=COLORS["sunken"],
                  sidebar_border_color=COLORS["border"], card_shade_color=COLORS["border"],
                  accent_color=COLORS["accent"], accent_bg_color=COLORS["accent"], accent_fg_color=COLORS["inverse"],
                  success_color=COLORS["success"], warning_color=COLORS["warning"],
                  error_color=COLORS["danger"], destructive_color=COLORS["danger"],
                  destructive_bg_color=COLORS["danger"], destructive_fg_color=COLORS["inverse"])
    css = "".join(f"@define-color {name} {value};\n" for name, value in colors.items())
    if (Gtk.get_major_version(), Gtk.get_minor_version()) >= (4, 16):
        css += ":root {\n" + "".join(
            f"--{name.replace('_', '-')}: {value};\n" for name, value in colors.items()) + "}\n"
    css += _CSS % TOKENS
    settings = Gtk.Settings.get_default()
    if settings and not settings.get_property("gtk-enable-animations"):
        css += ".quinta-material * { transition: none; animation: none; }\n"
    return css


_CSS = r"""
window.quinta-material { background-image: linear-gradient(135deg, @quinta_backdrop_a, @quinta_backdrop_b, @quinta_backdrop_c); color: @quinta_text; font-family: sans-serif; font-size: %(body)dpx; }
.quinta-material .material-backdrop, .quinta-material .launcher-shell { background: transparent; }
.quinta-material headerbar { background: transparent; border: none; box-shadow: none; min-height: 48px; padding: 0 %(s2)dpx; }
.quinta-material .launcher-header { border: none; }
.quinta-material .launcher-sidebar { background: @quinta_glass_sidebar; border: 1px solid @quinta_glass_border; border-top-color: @quinta_glass_highlight; border-radius: %(radius_lg)dpx; margin: %(s3)dpx 0 %(s3)dpx %(s3)dpx; }
.quinta-material .launcher-sidebar headerbar { background: transparent; padding: %(s2)dpx %(s4)dpx; }
.quinta-material .launcher-brand { font-size: 16px; font-weight: 600; }
.quinta-material .brand-caption { font-size: %(caption)dpx; color: @quinta_subtle; }
.quinta-material .brand-monogram { background: @quinta_glass; color: @quinta_text; border: 1px solid @quinta_border; border-radius: %(radius_md)dpx; min-width: 32px; min-height: 32px; font-size: 20px; font-weight: 700; }
.quinta-material .launcher-sidebar .navigation-sidebar { background: none; padding: %(s3)dpx %(s2)dpx; }
.quinta-material .launcher-sidebar .navigation-sidebar row { border-radius: %(radius_md)dpx; min-height: %(normal)dpx; margin-bottom: %(s1)dpx; padding: 0 %(s3)dpx; color: @quinta_subtle; transition: background-color %(fast)dms ease, color %(fast)dms ease; }
.quinta-material .launcher-sidebar .navigation-sidebar row image { margin-right: %(s2)dpx; -gtk-icon-size: 20px; }
.quinta-material .launcher-sidebar .navigation-sidebar row:hover { background: @quinta_glass_hover; }
.quinta-material .launcher-sidebar .navigation-sidebar row:selected { background: @quinta_glass_selected; color: @quinta_text; }
.quinta-material .launcher-header windowtitle .title { font-size: %(body)dpx; font-weight: 600; }
.quinta-material button { border-radius: %(radius_md)dpx; min-height: %(compact)dpx; padding: %(s1)dpx %(s3)dpx; font-size: %(body)dpx; font-weight: 500; box-shadow: none; transition: background-color %(fast)dms ease, color %(fast)dms ease, border-color %(fast)dms ease; }
.quinta-material button.image-button { min-width: %(compact)dpx; min-height: %(compact)dpx; padding: %(s1)dpx; }
.quinta-material button.flat { background: transparent; }
.quinta-material button.flat:hover { background: @quinta_glass_hover; }
.quinta-material button:active { background: @quinta_selected; }
.quinta-material button.suggested-action { background-image: linear-gradient(to bottom, @quinta_accent_hover, @quinta_accent); color: @quinta_inverse; border: none; font-weight: 600; }
.quinta-material button.suggested-action:hover { background-image: none; background-color: @quinta_accent_hover; }
.quinta-material button.suggested-action:active { background-image: none; background-color: @quinta_accent_pressed; }
.quinta-material button:disabled { color: @quinta_disabled; }
.quinta-material button.suggested-action:disabled { background-image: none; background-color: @quinta_selected; color: @quinta_disabled; }
.quinta-material button.destructive-action { background: @quinta_danger; color: @quinta_inverse; }
.quinta-material .tabs { margin: %(s2)dpx %(s4)dpx; padding: %(s1)dpx; background: @quinta_glass_sidebar; border-radius: %(radius_md)dpx; }
.quinta-material .tabs .tab { border-radius: %(radius_sm)dpx; background: transparent; border: none; min-height: %(compact)dpx; color: @quinta_subtle; padding: %(s1)dpx %(s3)dpx; }
.quinta-material .tabs .tab:checked { background: @quinta_glass_selected; color: @quinta_text; }
.quinta-material .play-dashboard { padding: %(s6)dpx; }
.quinta-material .play-hero { background: @quinta_glass; border: 1px solid @quinta_glass_border; border-top-color: @quinta_glass_highlight; border-radius: %(radius_lg)dpx; box-shadow: 0 8px 24px rgba(0,0,0,0.12); }
.quinta-material .play-hero-head { padding: %(s6)dpx; }
.quinta-material .play-title { color: @quinta_text; font-size: %(title)dpx; font-weight: 600; }
.quinta-material .play-subtitle { color: @quinta_subtle; font-size: %(body)dpx; }
.quinta-material .play-badge { color: @quinta_subtle; font-size: %(caption)dpx; padding: 0; }
.quinta-material .play-hero actionbar { background: transparent; border: none; }
.quinta-material .play-hero actionbar > revealer > box { padding: %(s4)dpx %(s6)dpx; border-top: 1px solid @quinta_glass_border; background: transparent; box-shadow: none; }
.quinta-material .play-hero actionbar button.suggested-action { min-height: %(normal)dpx; padding: %(s1)dpx %(s6)dpx; }
.quinta-material .launcher-section-title { color: @quinta_subtle; font-size: %(caption)dpx; font-weight: 600; }
.quinta-material .play-facts { background: @quinta_glass_sidebar; border: 1px solid @quinta_glass_border; border-radius: %(radius_lg)dpx; padding: %(s1)dpx %(s4)dpx; }
.quinta-material .play-fact { padding: %(s3)dpx 0; }
.quinta-material .play-fact + .play-fact { border-top: 1px solid @quinta_glass_border; }
.quinta-material .play-fact-title { color: @quinta_subtle; font-size: %(body)dpx; }
.quinta-material .play-fact-value { color: @quinta_text; font-family: monospace; font-size: %(caption)dpx; }
.quinta-material preferencesgroup > box > label { color: @quinta_text; font-weight: 600; }
.quinta-material list.boxed-list { border-radius: %(radius_md)dpx; background: @quinta_glass; border: 1px solid @quinta_glass_border; box-shadow: none; }
.quinta-material list.boxed-list row { background: transparent; min-height: 48px; }
.quinta-material list.boxed-list row .subtitle { color: @quinta_subtle; }
.quinta-material list.boxed-list row:selected { background: @quinta_selected; }
.quinta-material entry, .quinta-material textview { border-radius: %(radius_sm)dpx; }
.quinta-material progressbar trough { border-radius: %(radius_sm)dpx; background: @quinta_selected; }
.quinta-material progressbar progress { border-radius: %(radius_sm)dpx; background: @quinta_accent; transition: min-width 160ms ease; }
.quinta-material .setup-wizard { background: @quinta_surface; }
.quinta-material .setup-step, .quinta-material .setup-note { border-radius: %(radius_md)dpx; background: @quinta_raised; }
.quinta-material .setup-number { border-radius: %(radius_sm)dpx; background: @quinta_glass_selected; color: @quinta_text; }
.quinta-material :focus-visible { outline: 2px solid @quinta_accent; outline-offset: 2px; }
"""
