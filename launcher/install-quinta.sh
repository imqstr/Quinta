#!/usr/bin/env bash
# Install development checkout shortcuts without replacing Quinta's entries.
set -euo pipefail
launcher_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
data_dir=${XDG_DATA_HOME:-$HOME/.local/share}
mkdir -p "$HOME/.local/bin" "$data_dir/applications"
chmod +x "$launcher_dir/quinta-launcher"
ln -sfn -- "$launcher_dir/quinta-launcher" "$HOME/.local/bin/quinta"
python3 - "$launcher_dir" "$data_dir" <<'PY'
import pathlib
import sys

launcher, data = map(pathlib.Path, sys.argv[1:])
# Escape the quoted argument using the Desktop Entry Exec rules.
entry = str(launcher / 'quinta-launcher')
for char in ('\\', '"', '`', '$'):
    entry = entry.replace(char, '\\' + char)
entry = entry.replace('%', '%%')
icon = launcher.parent / 'branding/icons/quadrahq-256.png'
(data / 'applications/io.github.imqstr.Quinta.desktop').write_text(
    '[Desktop Entry]\nType=Application\nName=Quinta\n'
    'Comment=Roblox on Linux through Darling\n'
    f'Exec="{entry}"\nIcon={icon}\nTerminal=false\n'
    'Categories=Game;\nKeywords=roblox;darling;quinta;\nStartupNotify=true\n')
PY
if command -v update-desktop-database >/dev/null; then
    update-desktop-database "$data_dir/applications"
fi
printf '%s\n' 'Installed Quinta. Run quinta or select Quinta in the app menu.'
