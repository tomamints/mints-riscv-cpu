#!/usr/bin/env bash
# Build only: no FPGA programming and no Linux execution.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
set -euo pipefail
out=build/board/time64-probe
mkdir -p "$out"
make -s dtb PLATFORM_PROFILE=de0cv64 > "$out/dtb.log" 2>&1
riscv64-unknown-elf-gcc -march=rv64ima_zicsr -mabi=lp64 -mcmodel=medany -O2 \
  -nostdlib -nostartfiles -ffreestanding -fno-builtin -T tb/sw/common/link.ld \
  tb/sw/common/entry.S tb/sw/board/time64_probe.c -o "$out/probe.elf"
riscv64-unknown-elf-objcopy -O binary "$out/probe.elf" "$out/probe.bin"
python3 tools/make_linux_ram_hex.py --payload "$out/probe.bin" \
  --dtb build/platform/de0cv64/riscv_cpu.dtb --dtb-offset 0x3f00000 \
  --size 0x4000000 -o "$out/probe.hex"
echo "$out/probe.hex"
'
