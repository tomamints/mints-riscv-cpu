#!/usr/bin/env bash
# Board: PLATFORM_PROFILE=de0cv64 bash tools/rebuild-linux.sh all
# Existing dependencies: rebuild kernel, then image with the same profile.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
: "${DOCKER_IMAGE:=mints-linux-verilator:5.046}"
: "${SOURCES_VOLUME:=mints-linux-sources}"
: "${JOBS:=4}"
: "${PLATFORM_PROFILE:=legacy}"
docker build -f Dockerfile.linux -t "$DOCKER_IMAGE" .
docker run --rm --init -v "$PWD:/repo" -v "$SOURCES_VOLUME:/sources" \
  -e JOBS="$JOBS" -e PLATFORM_PROFILE="$PLATFORM_PROFILE" \
  -e KERNEL_INIT_MODE="${KERNEL_INIT_MODE:-}" "$DOCKER_IMAGE" bash tools/rebuild-linux-container.sh "${1:-all}"
