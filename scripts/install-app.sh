#!/usr/bin/env bash
# Build and install the Quinta desktop app from this checkout.
#
#   bash scripts/install-app.sh            install or update
#   bash scripts/install-app.sh --remove   remove the menu entry and command
#
# Needs CiderDarling (install.sh sets it up), Rust and Node.js. Rebuilds are
# incremental, so running it again after a pull only builds what changed.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
bin_dir=${XDG_BIN_HOME:-$HOME/.local/bin}
apps_dir=${XDG_DATA_HOME:-$HOME/.local/share}/applications
icons_dir=${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/512x512/apps
app_id=io.github.imqstr.Quinta

step() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ ${1:-} == --remove ]]; then
  rm -f "$bin_dir/quinta" "$apps_dir/$app_id.desktop" "$icons_dir/$app_id.png"
  step "Removed Quinta's command and menu entry (settings in ~/.config/quinta are kept)"
  exit 0
fi

for tool in cargo npm; do
  command -v "$tool" >/dev/null || fail "$tool is missing. Install Rust (https://rustup.rs) and Node.js 18+."
done
[[ -f ${XDG_CONFIG_HOME:-$HOME/.config}/quinta/runtime.json ]] ||
  fail "No CiderDarling runtime found. Run install.sh first, then this script."

step "Building the game compatibility shim"
bash "$root/scripts/build-native.sh" >/dev/null

step "Building the interface"
cd "$root/desktop"
if [[ ! -d node_modules || package-lock.json -nt node_modules ]]; then npm ci --no-audit --no-fund; fi
npm run build --silent

step "Building the app (first build takes a few minutes)"
cd "$root/desktop/src-tauri"
cargo build --release --features tauri/custom-protocol

step "Installing"
mkdir -p "$bin_dir" "$apps_dir" "$icons_dir"
cat > "$bin_dir/quinta" <<EOF
#!/bin/sh
QUINTA_ROOT='$root' exec '$root/desktop/src-tauri/target/release/quinta' "\$@"
EOF
chmod +x "$bin_dir/quinta"
cp "$root/desktop/src-tauri/icons/icon.png" "$icons_dir/$app_id.png"
cat > "$apps_dir/$app_id.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Quinta
Comment=Play Roblox on Linux
Exec=$bin_dir/quinta
Icon=$app_id
Categories=Game;
StartupWMClass=quinta
EOF
command -v update-desktop-database >/dev/null && update-desktop-database "$apps_dir" 2>/dev/null || true

step "Done. Open Quinta from your app menu, or run: quinta"
case ":$PATH:" in *":$bin_dir:"*) ;; *) echo "   ($bin_dir is not on your PATH yet)";; esac
