#!/usr/bin/env bash
# Build the 64 MiB / 20 MHz CPU+SDRAM simulation with the physical UART backend.
# Does not boot Linux or program the FPGA. OBJ_DIR permits an isolated build.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -e MAKEFLAGS=-j2 -v "$PWD:/repo" -w /repo \
  "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" make build \
  PLATFORM_PROFILE=de0cv64 RAM_BACKEND=sdram_model PHYSICAL_UART=1 \
  ICACHE_LINE_COUNT=32 ICACHE_DATA_RAM_STYLE=1 \
  DCACHE_LINE_COUNT=32 DCACHE_DATA_RAM_STYLE=1 DCACHE_STORE_BUFFER_DEPTH=4 DCACHE_WRITE_BACK=0 \
  BP_PHT_ENTRIES=32 BP_BTB_ENTRIES=8 BP_RAS_ENTRIES=4 \
  OBJ_DIR="${OBJ_DIR:-build/de0cv/cpu-sim/obj}"
