#!/usr/bin/env bash
# Shared staging step for Debian and RPM builds. Never installs to the host.
set -euo pipefail
if [[ $# != 4 ]]; then
  printf 'Usage: %s SOURCE_ROOT BUILD_DIR DESTDIR LIBDIR\n' "$0" >&2
  exit 2
fi
source_root=$(realpath -- "$1")
build_dir=$(realpath -- "$2")
destdir=$(realpath -m -- "$3")
libdir=$4
[[ $destdir != / && $libdir =~ ^/usr/lib(64|/[A-Za-z0-9_-]+)?$ ]] || {
  printf '%s\n' 'Use a package staging directory and an absolute /usr/lib path.' >&2
  exit 2
}
for file in libQuintaShims.dylib libquinta-wayland.so metal/libquinta_metal_host.so metal/Metal.framework/Metal; do
  [[ -f $build_dir/$file ]] || {
    printf 'Missing build artifact: %s\n' "$build_dir/$file" >&2
    exit 1
  }
done
share=$destdir/usr/share/quinta
shim=$destdir$libdir/quinta/shim
install -d "$share/branding" "$shim" "$destdir/usr/bin"
cp -r --no-preserve=ownership "$source_root/launcher" "$share/"
rm -f "$share/launcher/install.sh"
find "$share/launcher" -type d -name __pycache__ -exec rm -rf -- {} +
# Include runtime branding; design sources and the website are not installed.
cp -r --no-preserve=ownership "$source_root/branding/icons" \
  "$source_root/branding/contributors" "$share/branding/"
install -m644 "$source_root/branding/"*.png "$source_root/branding/"*.svg "$share/branding/"
install -m644 "$source_root/branding/quinta.webp" "$share/branding/"
install -m644 "$source_root/scripts/patch-startup-throttle.py" "$share/"
install -m644 "$source_root/README.md" "$share/"
install -m755 "$source_root/install.sh" "$share/"
install -m755 "$build_dir/libQuintaShims.dylib" \
  "$build_dir/libquinta-wayland.so" "$shim/"
# Studio's Vulkan fix: optional, built only where the Vulkan headers are installed.
if [[ -f $build_dir/libquinta-studio-layer.so ]]; then
  install -m755 "$build_dir/libquinta-studio-layer.so" "$shim/"
fi
cp -r --no-preserve=ownership "$build_dir/frameworks" "$shim/"
install -d "$shim/metal" "$share/prototype/metal-vulkan"
install -m755 "$build_dir/metal/libquinta_metal_host.so" "$shim/metal/"
cp -r --no-preserve=ownership "$build_dir/metal/Metal.framework" "$shim/metal/"
install -m644 "$source_root/prototype/metal-vulkan/README.md" "$share/prototype/metal-vulkan/"
cat > "$destdir/usr/bin/quinta" <<WRAPPER
#!/bin/sh
export QUINTA_PREBUILT_SHIM=$libdir/quinta/shim
exec python3 /usr/share/quinta/launcher/quinta-launcher "\$@"
WRAPPER
chmod 755 "$destdir/usr/bin/quinta"
for size in 16 22 24 32 48 64 128 256 512 1024; do
  install -Dm644 "$source_root/branding/icons/quinta-$size.png" \
    "$destdir/usr/share/icons/hicolor/${size}x${size}/apps/quinta.png"
done
for file in io.github.imqstr.Quinta.desktop io.github.imqstr.Quinta.URI.desktop \
  io.github.imqstr.Quinta.Studio.desktop quinta-roblox-window.desktop; do
  install -Dm644 "$source_root/packaging/$file" \
    "$destdir/usr/share/applications/$file"
done
install -Dm644 "$source_root/packaging/io.github.imqstr.Quinta.xml" \
  "$destdir/usr/share/mime/packages/io.github.imqstr.Quinta.xml"
install -Dm644 "$source_root/LICENSE" \
  "$destdir/usr/share/licenses/quinta/LICENSE"
install -m644 "$source_root/LICENSES/MIT-MacOBlox.txt" \
  "$destdir/usr/share/licenses/quinta/"
cp -r --no-preserve=ownership "$source_root/LICENSES/metal" \
  "$destdir/usr/share/licenses/quinta/"
install -m644 "$source_root/launcher/quinta/assets/fonts/"*-OFL.txt \
  "$destdir/usr/share/licenses/quinta/"
