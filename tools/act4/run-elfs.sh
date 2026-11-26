#!/usr/bin/env bash
# Run one ACT4 generation directory in the MiNTs RISC-V/Verilator image.
set -euo pipefail
out=${ACT4_OUT:?Set ACT4_OUT to a generation run directory}
elfs=$out/generated/mints-rv64/elfs
find "$elfs" -type f -name '*.elf' -print | sort > "$out/elf-list"
if [[ ! -s "$out/elf-list" ]]; then
    echo "No ACT4 ELFs in $elfs" >&2
    exit 1
fi
while IFS= read -r elf; do
    sha256sum "$elf"
    riscv64-unknown-elf-objcopy -O binary "$elf" "$elf.bin"
    python3 tools/bin2hex.py 8 "$elf.bin" > "$elf.bin.hex"
done < "$out/elf-list" > "$out/elf.sha256"
if [[ -z ${ACT4_SIM:-} ]]; then
    make -j"${ACT4_JOBS:-4}" build OBJ_DIR="$out/obj" > "$out/rtl-build.log" 2>&1
fi
make bootrom-build TEST_BUILD_DIR="$out/boot"
python3 tools/run_riscv_tests.py "${ACT4_SIM:-$out/obj/sim}" "$elfs" -r \
    --rom "$out/boot/bootrom.hex" -o "$out/results" -t "${TEST_TIMEOUT:-10}" \
    --jobs "${ACT4_JOBS:-4}" --require-pass-marker
