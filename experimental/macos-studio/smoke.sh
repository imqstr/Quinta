#!/usr/bin/env bash
set -euo pipefail
experiment_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_dir=$(dirname -- "$(dirname -- "$experiment_dir")")
mapfile -t runtime < <(PYTHONPATH="$project_dir/launcher" python3 - <<'PY'
from quinta.runtime import resolve_runtime
r = resolve_runtime()
for key in ('sysroot', 'executable', 'prefix'):
    print(r[key])
PY
)
bash "$experiment_dir/build.sh"
smoke_dir=$(mktemp -d /tmp/quinta-studio-smoke.XXXXXX)
trap 'rm -rf -- "$smoke_dir"' EXIT
clang -target x86_64-apple-darwin -fuse-ld=lld -isysroot "${runtime[0]}" \
    -mmacosx-version-min=11.0 "$experiment_dir/smoke.m" \
    -framework Foundation -framework CoreText -framework CoreGraphics \
    -framework CoreFoundation -framework CFNetwork -o "$smoke_dir/smoke"
DPREFIX="${runtime[2]}" "${runtime[1]}" shell /bin/bash -c \
    'export DYLD_INSERT_LIBRARIES="$1"; exec "$2"' quinta-smoke \
    "/Volumes/SystemRoot$experiment_dir/libStudioCompat.dylib" "/Volumes/SystemRoot$smoke_dir/smoke"
