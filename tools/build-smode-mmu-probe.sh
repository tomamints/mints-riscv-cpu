#!/usr/bin/env bash
# Build a standalone M->S transition, CSR, Sv39 superpage/4K-page diagnostic.
# No OpenSBI/Linux execution and no FPGA programming.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
set -euo pipefail
out=build/board/smode-mmu-probe
mkdir -p "$out"
make -s dtb PLATFORM_PROFILE=de0cv64 > "$out/dtb.log" 2>&1
riscv64-unknown-elf-gcc -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany \
  -mno-relax -nostdlib -nostartfiles -T tb/sw/common/link.ld \
  tb/sw/board/smode_mmu_probe.S -o "$out/probe.elf"
riscv64-unknown-elf-objcopy -O binary "$out/probe.elf" "$out/probe.bin"
python3 tools/make_linux_ram_hex.py --payload "$out/probe.bin" \
  --dtb build/platform/de0cv64/riscv_cpu.dtb --dtb-offset 0x3f00000 \
  --size 0x4000000 -o "$out/probe.hex"
echo "$out/probe.hex"
'
