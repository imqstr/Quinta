#!/usr/bin/env python3
"""Refresh the bundled Google Material Symbols Rounded icon set."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import json
import urllib.request

PROJECT = Path(__file__).resolve().parents[1]
REVISION = "10ecc14790612ca8fd164e3f4ffe9c16fc50d5b7"
ORIGIN = f"https://raw.githubusercontent.com/google/material-design-icons/{REVISION}"
ICONS = {
    "adw-external-link-symbolic": "open_in_new",
    "application-x-addon-symbolic": "extension",
    "application-x-executable-symbolic": "deployed_code",
    "applications-development-symbolic": "code_blocks",
    "applications-engineering-symbolic": "tune",
    "dialog-warning-symbolic": "warning",
    "document-edit-symbolic": "edit_document",
    "edit-clear-symbolic": "delete",
    "edit-copy-symbolic": "content_copy",
    "edit-find-symbolic": "search",
    "emblem-ok-symbolic": "check_circle",
    "emblem-system-symbolic": "settings",
    "folder-download-symbolic": "download",
    "folder-open-symbolic": "folder_open",
    "go-bottom-symbolic": "vertical_align_bottom",
    "go-down-symbolic": "arrow_downward",
    "go-next-symbolic": "arrow_forward",
    "go-previous-symbolic": "arrow_back",
    "go-up-symbolic": "arrow_upward",
    "help-about-symbolic": "info",
    "input-gaming-symbolic": "sports_esports",
    "list-add-symbolic": "add",
    "media-playback-start-symbolic": "play_arrow",
    "open-menu-symbolic": "more_horiz",
    "preferences-other-symbolic": "flag",
    "preferences-system-symbolic": "tune",
    "preferences-system-time-symbolic": "schedule",
    "quinta-github-symbolic": "code",
    "quinta-web-symbolic": "language",
    "quinta-discord-symbolic": "forum",
    "sidebar-show-symbolic": "side_navigation",
    "software-update-available-symbolic": "system_update_alt",
    "utilities-terminal-symbolic": "terminal",
    "video-display-symbolic": "desktop_windows",
    "view-refresh-symbolic": "refresh",
    "window-close-symbolic": "close",
    "pan-down-symbolic": "expand_more",
    "pan-end-symbolic": "chevron_right",
    "pan-start-symbolic": "chevron_left",
    "pan-up-symbolic": "expand_less",
    "object-select-symbolic": "check",
}


def main():
    root = PROJECT / "launcher/quinta/assets/icons/Quinta"
    actions = root / "scalable/actions"
    actions.mkdir(parents=True, exist_ok=True)

    def fetch(item):
        alias, symbol = item
        url = f"{ORIGIN}/symbols/web/{symbol}/materialsymbolsrounded/{symbol}_24px.svg"
        with urllib.request.urlopen(url, timeout=30) as response:
            data = response.read()
        if not data.startswith(b"<svg") or b"<path" not in data:
            raise ValueError(f"Unexpected icon response: {symbol}")
        (actions / f"{alias}.svg").write_bytes(data)
        return {"alias": alias, "symbol": symbol, "sha256": hashlib.sha256(data).hexdigest()}

    with ThreadPoolExecutor(max_workers=8) as pool:
        manifest = list(pool.map(fetch, ICONS.items()))
    (root / "index.theme").write_text(
        "[Icon Theme]\nName=Quinta\nComment=Google Material Symbols Rounded\n"
        "Inherits=Adwaita,hicolor\nDirectories=scalable/actions\n\n"
        "[scalable/actions]\nSize=24\nType=Scalable\nMinSize=16\nMaxSize=64\nContext=Actions\n")
    (root / "sources.json").write_text(json.dumps(
        {"repository": "https://github.com/google/material-design-icons", "revision": REVISION,
         "license": "Apache-2.0", "icons": manifest}, indent=2) + "\n")
    license_path = PROJECT / "LICENSES/google-material-symbols-LICENSE.txt"
    with urllib.request.urlopen(f"{ORIGIN}/LICENSE", timeout=30) as response:
        license_path.write_bytes(response.read())
    print(f"Bundled {len(manifest)} Google Material Symbols Rounded icons")


if __name__ == "__main__":
    main()
