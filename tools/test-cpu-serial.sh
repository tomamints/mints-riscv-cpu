#!/usr/bin/env bash
# Requires a PHYSICAL_UART=1, 20 MHz simulator (see CAPACITY/ICACHE profile flags).
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -e SERIAL_SIM="${SERIAL_SIM:-build/test/cpu-physical-uart/obj/sim}" \
  -e UART_SERIAL_TRACE=1 -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
set -euo pipefail
out=build/test/cpu-serial
mkdir -p "$out/elf" "$out/boot"
make bootrom-build TEST_BUILD_DIR="$out/boot" > "$out/boot.log" 2>&1
elf="$out/elf/uart_serial_smoke"
riscv64-unknown-elf-gcc -march=rv64imac_zicsr_zifencei -mabi=lp64 -mno-relax -static \
  -mcmodel=medany -nostdlib -nostartfiles -Ibuild/riscv-tests/env/p \
  -Ibuild/riscv-tests/isa/macros/scalar -Tbuild/riscv-tests/env/p/link.ld \
  tb/sw/directed/uart_serial_smoke.S -o "$elf"
riscv64-unknown-elf-objcopy -O binary "$elf" "$elf.bin"
python3 tools/bin2hex.py 8 "$elf.bin" > "$elf.bin.hex"
python3 tools/run_riscv_tests.py "$SERIAL_SIM" "$out/elf" --rom "$out/boot/bootrom.hex" \
  -o "$out/result" -t 30 > "$out/run.log" 2>&1
python3 -I -c "
from pathlib import Path
logs=list(Path(\"$out/result\").glob(\"*.bin.hex.txt\"))
assert len(logs)==1, logs
data=bytes(int(l.split(\"=\")[1],16) for l in logs[0].read_text().splitlines() if l.startswith(\"UART_SERIAL_TX byte=\"))
assert data==b\"MiNTs\\n\", data
print(\"CPU_SERIAL_PASS: MiNTs + newline at 115200 baud\")
"
'
