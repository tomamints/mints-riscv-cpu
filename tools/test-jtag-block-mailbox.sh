#!/usr/bin/env bash
# jtag_block_mailbox + boot_memory_loader unit test at two TCK/clk ratios
# (TCK slower and faster than clk).
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
set -euo pipefail
out=build/test/jtag-block-mailbox
mkdir -p "$out"
srcs="src/eei.sv src/membus_if.sv fpga/de0-cv/rtl/boot_memory_loader.sv fpga/de0-cv/rtl/jtag_block_mailbox.sv tb/unit/sdram/tb_jtag_block_mailbox.sv"
sha256sum $srcs > "$out/sources.sha256"
for r in "17.0 5.0" "3.0 11.0"; do
  set -- $r; tag=tck$1-clk$2
  verilator --binary --timing --assert -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL --top-module tb_jtag_block_mailbox \
    -GTCK_HALF=$1 -GCLK_HALF=$2 --Mdir "$out/obj-$tag" -o sim $srcs > "$out/build-$tag.log" 2>&1
  "$out/obj-$tag/sim" > "$out/run-$tag.log" 2>&1 || { tail -5 "$out/run-$tag.log"; exit 1; }
  grep "^JTAG_BLOCK_MAILBOX_PASS" "$out/run-$tag.log"
done
grep -E "%Warning" "$out"/build-*.log | grep "fpga/de0-cv/rtl/jtag_block_mailbox.sv" || true
'
