#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
set -euo pipefail
out=build/test/vga
mkdir -p "$out"
verilator --binary --timing --assert -Wno-fatal --top-module tb_vga_text \
  -j 4 --Mdir "$out/obj" -o sim fpga/de0-cv/vga/rtl/vga_text.sv tb/unit/tb_vga_text.sv \
  > "$out/build.log" 2>&1
"$out/obj/sim" | tee "$out/run.log"
grep -q VGA_TEXT_PASS "$out/run.log"
'

python3 tools/check-vga-frame.py
