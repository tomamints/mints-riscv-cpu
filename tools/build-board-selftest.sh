#!/usr/bin/env bash
# Build the DE0-CV bare-metal self test (tb/sw/board/board_selftest.c):
#   build/board/selftest/board_selftest.hex       sparse RAM image for
#       de0cv-jtag-load (program at 0x80000000 + de0cv64 DTB)
#   build/board/selftest/board_selftest_sim.hex   quick variant, flat hex
#       for the 64 MiB CPU simulation
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
set -euo pipefail
out=build/board/selftest
mkdir -p "$out"
make -s dtb PLATFORM_PROFILE=de0cv64 > "$out/dtb.log" 2>&1
cc="riscv64-unknown-elf-gcc -march=rv64ima_zicsr -mabi=lp64 -mcmodel=medany -O2 -nostdlib -nostartfiles -ffreestanding -fno-builtin -T tb/sw/common/link.ld tb/sw/common/entry.S tb/sw/board/board_selftest.c"
$cc -o "$out/board_selftest.elf"
$cc -DSELFTEST_SIM_QUICK -o "$out/board_selftest_sim.elf"
for v in board_selftest board_selftest_sim; do
  riscv64-unknown-elf-objcopy -O binary "$out/$v.elf" "$out/$v.bin"
done
python3 tools/make_linux_ram_hex.py --payload "$out/board_selftest.bin" --dtb build/platform/de0cv64/riscv_cpu.dtb \
  --dtb-offset 0x3f00000 --size 0x4000000 -o "$out/board_selftest.hex"
python3 tools/make_linux_ram_hex.py --payload "$out/board_selftest_sim.bin" --dtb build/platform/de0cv64/riscv_cpu.dtb \
  --dtb-offset 0x3f00000 --size 0x4000000 -o "$out/board_selftest_sim.hex"
ls -l "$out"/*.hex
'
