#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
set -euo pipefail
out=build/test/boot-memory-loader
mkdir -p "$out"
sha256sum fpga/de0-cv/rtl/boot_memory_loader.sv tb/unit/sdram/tb_boot_memory_loader.sv > "$out/sources.sha256"
verilator --binary --timing --assert -Wno-fatal --top-module tb_boot_memory_loader \
  --Mdir "$out/obj" -o sim src/eei.sv src/membus_if.sv \
  fpga/de0-cv/rtl/boot_memory_loader.sv tb/unit/sdram/tb_boot_memory_loader.sv > "$out/build.log" 2>&1
"$out/obj/sim" > "$out/run.log" 2>&1
grep "^BOOT_MEMORY_LOADER_PASS" "$out/run.log"
'
