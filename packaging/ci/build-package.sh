#!/usr/bin/env bash
# Run inside the target distro container with /src, /runtime and /out mounted.
set -euo pipefail
flavor=${1:?package flavor required}
case $flavor in
  arch)
    pacman -Syu --noconfirm --needed base-devel clang lld git python pkgconf sdl2 wayland vulkan-headers vulkan-icd-loader
    useradd -m builder
    ;;
  ubuntu24.04)
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential debhelper dh-python python3 clang lld pkg-config libsdl2-dev libwayland-dev libvulkan-dev
    ;;
  fedora)
    dnf install -y rpm-build clang lld gcc-c++ python3 pkgconf-pkg-config SDL2-devel wayland-devel vulkan-loader-devel
    ;;
  *) exit 2 ;;
esac
mkdir -p /work
cp -a /src/. /work/
cd /work
version=$(python3 -c 'import json; print(json.load(open("packaging/release.json"))["version"])')
archive=/out/quinta-$version-source.tar.gz
digest=$(sha256sum "$archive"); digest=${digest%% *}
python3 - "$digest" <<'PY'
import json, sys
from pathlib import Path
path = Path('packaging/release.json')
data = json.loads(path.read_text())
data['sha256'] = sys.argv[1]
path.write_text(json.dumps(data, indent=2) + '\n')
PY
bash packaging/prepare-source.sh /work/prepared "$archive"
export DARLING_SYSROOT=/runtime
case $flavor in
  arch)
    chown -R builder: /work/prepared
    su builder -c 'export DARLING_SYSROOT=/runtime; cd /work/prepared/aur/quinta && makepkg --printsrcinfo > .SRCINFO && makepkg --nodeps --noconfirm'
    cp /work/prepared/aur/quinta/quinta-*.pkg.tar.zst /out/
    cp /work/prepared/aur/quinta/PKGBUILD /out/quinta.PKGBUILD
    cp /work/prepared/aur/quinta/.SRCINFO /out/quinta.SRCINFO
    tar -tf "/out/quinta-$version-1-x86_64.pkg.tar.zst" > /work/package-files
    ;;
  ubuntu24.04)
    cd "/work/prepared/Quinta-$version"
    DEB_BUILD_PROFILES=pkg.quinta.prebuilt-metal dpkg-buildpackage -b -us -uc
    cp /work/prepared/quinta_*.deb /out/
    dpkg-deb --fsys-tarfile "/out/quinta_${version}-1_amd64.deb" | tar -tf - > /work/package-files
    ;;
  fedora)
    rpmbuild --with prebuilt_metal --define '_topdir /work/prepared/rpm' -ba /work/prepared/rpm/SPECS/quinta.spec
    cp /work/prepared/rpm/RPMS/x86_64/*.rpm /out/
    cp /work/prepared/rpm/SRPMS/*.src.rpm /out/
    rpm -qpl /work/prepared/rpm/RPMS/x86_64/quinta-*.rpm > /work/package-files
    ;;
esac
python3 - <<'PY'
from pathlib import Path
files = Path('/work/package-files').read_text().splitlines()
for tail in ('/quinta/shim/metal/libquinta_metal_host.so',
             '/quinta/shim/metal/Metal.framework/Metal',
             '/quinta/shim/metal/Metal.framework/Versions/A/Metal'):
    assert any(name.endswith(tail) for name in files), f'Missing Metal payload: {tail}'
print('Verified packaged Metal framework and host library.')
# Studio's Vulkan renderer needs this layer; it is built only when the Vulkan headers are installed.
assert any(name.endswith('/quinta/shim/libquinta-studio-layer.so') for name in files), \
    'Missing Studio Vulkan layer: are the Vulkan development headers installed?'
print('Verified packaged Studio Vulkan layer.')
PY
chmod -R a+rX /out
