#!/usr/bin/env bash
# Same container setup as tools/build-de0cv-blink-docker.sh. Analysis only.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init --platform linux/amd64 -v "$PWD:/repo" -w /repo \
  -v "${QUARTUS_VOLUME:-mints-quartus-20.1}:/opt/intelFPGA_lite" \
  -e QUARTUS_SH=/opt/intelFPGA_lite/20.1/quartus/bin/quartus_sh \
  -e LD_PRELOAD=/lib/x86_64-linux-gnu/libudev.so.1 \
  "${QUARTUS_IMAGE:-mints-quartus:20.1}" bash tools/build-mem-probe.sh
