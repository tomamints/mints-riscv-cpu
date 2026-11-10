#!/usr/bin/env bash
# Board-path simulation of the DE0-CV SoC (tb/board/tb_de0cv_soc.sv): JTAG load
# of IMAGE (sparse RAM hex, default: quick bare-metal self test) through the
# mailbox, loader and SDRAM controller into the SDRAM model, release, run,
# decode UART TX. Simulates the synthesis view (SYNTHESIS defined) with the
# board profile macros of tools/build-de0cv-soc.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
image=${IMAGE:-build/board/selftest/board_selftest_sim.hex}
[[ -f $image ]] || bash tools/build-board-selftest.sh
docker run --rm --init -e IMAGE="$image" -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
set -euo pipefail
out=build/test/de0cv-soc-sim
mkdir -p "$out"
make -s linux-bootrom-build PLATFORM_PROFILE=de0cv64 > "$out/bootrom.log" 2>&1
python3 -I - "$IMAGE" "$out/image.words" <<PY
import sys
src, dst = sys.argv[1], sys.argv[2]
addr, out = None, []
for line in open(src):
    line = line.strip()
    if not line: continue
    if line[0] == "@": addr = int(line[1:], 16); continue
    assert addr is not None and len(line) == 16, line
    out.append((addr, line)); addr += 1
out.sort()
open(dst, "w").write("".join(f"{a:x} {v}\n" for a, v in out))
PY
files="$(sed "/^#/d;/^$/d" core.f | tr "\n" " ") rtl/peripheral/uart16550_regs.sv fpga/de0-cv/rtl/uart_baud_gen.sv fpga/de0-cv/rtl/uart_tx.sv fpga/de0-cv/rtl/uart_rx.sv fpga/de0-cv/rtl/uart_phy.sv rtl/peripheral/uart16550_serial.sv rtl/bus/membus_sdram_adapter.sv fpga/de0-cv/sdram/rtl/sdram_bridge64.sv fpga/de0-cv/sdram/rtl/sdram_native16.sv fpga/de0-cv/rtl/boot_memory_loader.sv fpga/de0-cv/rtl/jtag_block_mailbox.sv fpga/de0-cv/soc/rtl/de0cv_soc_core.sv tb/model/sdram_cycle_model16.sv tb/board/tb_de0cv_soc.sv"
sha256sum $files "$IMAGE" > "$out/sources.sha256"
verilator --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD --top-module tb_de0cv_soc \
  -DSYNTHESIS=1 -DSVCPU_RAM_EXTERNAL -DSVCPU_PHYSICAL_UART -DSVCPU_RAM_SIZE_BYTES=67108864 \
  -DSVCPU_BP_PHT_ENTRIES=32 -DSVCPU_BP_BTB_ENTRIES=4 -DSVCPU_BP_RAS_ENTRIES=4 -DSVCPU_TLB_ENTRIES=4 -DSVCPU_PMP_CARRY_COMPARE=1 \
  -GBOOTROM_HEX="\"build/platform/de0cv64/bootrom_linux.hex\"" \
  -j 4 --Mdir "$out/obj" -o sim $files > "$out/build.log" 2>&1 || { grep -E "%Error" "$out/build.log" | head -20; exit 1; }
start=$(date +%s)
"$out/obj/sim" +IMAGE="$out/image.words" > "$out/run.log" 2>&1 || { tail -15 "$out/run.log"; exit 1; }
echo "wall_seconds=$(( $(date +%s) - start ))"
grep -E "^\[TB\]" "$out/run.log"
grep -q "^DE0CV_SOC_SIM_PASS" "$out/run.log" && echo DE0CV_SOC_SIM_PASS
'
