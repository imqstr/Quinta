#!/bin/sh
# Quinta inside the Flatpak: a Darling prefix of its own, Darling
# without root (darling-noroot.c) and the shim built with the package.
export DPREFIX="${DPREFIX:-$XDG_DATA_HOME/darling}"
export QUINTA_NOROOT_LIB=/app/lib/quinta/darling-noroot.so
export QUINTA_PID1_DYLIB=/app/lib/quinta/launchd_pid1.dylib
export QUINTA_PREBUILT_SHIM=/app/lib/quinta/shim
exec python3 /app/share/quinta/launcher/quinta-launcher "$@"
