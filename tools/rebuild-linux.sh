#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
: "${DOCKER_IMAGE:=mints-linux-verilator:5.046}"
: "${SOURCES_VOLUME:=mints-linux-sources}"
: "${JOBS:=4}"
docker build -f Dockerfile.linux -t "$DOCKER_IMAGE" .
docker run --rm --init -v "$PWD:/repo" -v "$SOURCES_VOLUME:/sources" \
  -e JOBS="$JOBS" "$DOCKER_IMAGE" bash tools/rebuild-linux-container.sh "${1:-all}"
