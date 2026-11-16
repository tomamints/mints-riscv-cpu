#!/usr/bin/env bash
# Requires a de0cv64 simulator built with RAM_BACKEND=sdram_model.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -e CAPACITY_SIM="${CAPACITY_SIM:-build/test/cpu-m3c-board/obj/sim}" \
  -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
set -euo pipefail
out=build/test/ram-capacity
mkdir -p "$out/valid" "$out/invalid" "$out/boot"
make bootrom-build TEST_BUILD_DIR="$out/boot" > "$out/boot.log" 2>&1
sha256sum "$CAPACITY_SIM" src/eei.sv src/mmio_controller.sv tb/sw/directed/ram_capacity.S > "$out/sources.sha256"
for variant in valid invalid; do
  defs=(); [[ $variant == invalid ]] && defs=(-DCAPACITY_INVALID)
  elf="$out/$variant/ram_capacity"
  riscv64-unknown-elf-gcc -march=rv64imac_zicsr_zifencei -mabi=lp64 -mno-relax -static \
    -mcmodel=medany -nostdlib -nostartfiles "${defs[@]}" -Ibuild/riscv-tests/env/p \
    -Ibuild/riscv-tests/isa/macros/scalar -Tbuild/riscv-tests/env/p/link.ld \
    tb/sw/directed/ram_capacity.S -o "$elf"
  riscv64-unknown-elf-objcopy -O binary "$elf" "$elf.bin"
  python3 tools/bin2hex.py 8 "$elf.bin" > "$elf.bin.hex"
done
python3 tools/run_riscv_tests.py "$CAPACITY_SIM" "$out/valid" --rom "$out/boot/bootrom.hex" \
  -o "$out/pass" -t 30 --sim-arg +SDRAM_PRELOAD_VERIFY > "$out/valid.log" 2>&1
grep -q "Test Result : 1 / 1" "$out/pass/result.txt"
if python3 tools/run_riscv_tests.py "$CAPACITY_SIM" "$out/invalid" --rom "$out/boot/bootrom.hex" \
  -o "$out/reject" -t 30 > "$out/invalid.log" 2>&1; then
  echo "FAIL: outside-RAM access succeeded"; exit 1
fi
grep -q "MMIO_UNKNOWN_ACCESS addr=0000000084000000" "$out/reject/"*.txt
echo RAM_CAPACITY_PASS
'
