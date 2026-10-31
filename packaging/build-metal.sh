#!/usr/bin/env bash
# Build the guest framework and either compile the pinned host crate or use
# the release workflow's Ubuntu 24.04 artifact (same source revision).
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
build_dir=${QUINTA_BUILD_DIR:-$project_dir/build}
bash "$project_dir/prototype/metal-vulkan/build.sh" framework
if [[ -n ${QUINTA_METAL_HOST_LIBRARY:-} ]]; then
  install -m755 -- "$QUINTA_METAL_HOST_LIBRARY" "$build_dir/metal/libquinta_metal_host.so"
else
  bash "$project_dir/prototype/metal-vulkan/build.sh" host
fi
