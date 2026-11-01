#!/usr/bin/env bash
set -euo pipefail
experiment_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_dir=$(dirname -- "$(dirname -- "$experiment_dir")")
studio_sysroot=$(PYTHONPATH="$project_dir/launcher" python3 - <<'PY'
from quinta.runtime import resolve_runtime
print(resolve_runtime()['sysroot'])
PY
)
clang -target x86_64-apple-darwin -fuse-ld=lld -isysroot "$studio_sysroot" \
    -mmacosx-version-min=11.0 -dynamiclib -fno-objc-arc \
    "$experiment_dir/studio_compat.m" -framework Foundation -framework CoreGraphics -framework CoreText -framework CoreFoundation \
    -o "$experiment_dir/libStudioCompat.dylib"
