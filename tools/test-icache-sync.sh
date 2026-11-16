#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
set -euo pipefail
out=build/test/icache-sync
mkdir -p "$out"
for style in 0 1; do
  verilator --binary --timing --assert -Wno-fatal --top-module tb_icache_sync -GSTYLE=$style \
    --Mdir "$out/obj$style" -o sim src/eei.sv \
    fpga/de0-cv/mem_probe/rtl/ram_1r1w_be64.sv rtl/cache/icache.sv \
    tb/unit/sdram/tb_icache_sync.sv > "$out/build$style.log" 2>&1
  "$out/obj$style/sim" > "$out/run$style.log" 2>&1
  grep "^ICACHE_SYNC_PASS" "$out/run$style.log"
done
'
