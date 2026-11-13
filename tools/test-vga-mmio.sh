#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
set -euo pipefail
out=build/test/vga-mmio
mkdir -p "$out"
verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD --top-module tb_vga_mmio \
  -j 4 --Mdir "$out/obj" -o sim src/eei.sv src/membus_if.sv rtl/peripheral/board_gpio_mmio.sv tb/unit/tb_vga_mmio.sv \
  > "$out/build.log" 2>&1
"$out/obj/sim" | tee "$out/run.log"
grep -q VGA_MMIO_PASS "$out/run.log"
'
