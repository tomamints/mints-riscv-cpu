#!/usr/bin/env bash
# Compare a standalone seeded RV64 ELF against Sail and MiNTs.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -ge 1 && $# -le 2 ]] || { echo "Usage: $0 ACT4_RUN_DIR [seed]" >&2; exit 2; }
config=$(cd "$1/config" && pwd)
seed=${2:-20261126}
image=${VERILATOR_IMAGE:-mints-linux-verilator:5.046}
sail=${ACT4_IMAGE:-ghcr.io/riscv/act4-build@sha256:7f91dd68ceca47300dc59e320797a86998b8c94062b011bf6de9a3ba3ad57a03}
mkdir -p build/act4
out=$(mktemp -d "$PWD/build/act4/differential.XXXXXX")
echo "Differential output $out (seed $seed)"
python3 tools/act4/mixed_workload.py generate "$seed" 128 > "$out/workload.S"
printf '%s\n' "$seed" > "$out/seed"
docker run --rm --init -e OUT="${out#"$PWD"/}" -e SIM="${RV64_DIFF_SIM:-}" \
    -v "$PWD:/repo" -w /repo "$image" bash -ec '
    if [[ -z "$SIM" ]]; then
        make -j4 build OBJ_DIR="$OUT/obj" > "$OUT/build.log" 2>&1
        SIM=$OUT/obj/sim
    fi
    make bootrom-build TEST_BUILD_DIR="$OUT"
    riscv64-unknown-elf-gcc -march=rv64imac_zicsr -mabi=lp64 -nostdlib -mno-relax \
        -T tb/sw/directed/rv64_arch.ld "$OUT/workload.S" -o "$OUT/workload.elf"
    riscv64-unknown-elf-objcopy -O binary "$OUT/workload.elf" "$OUT/workload.bin"
    python3 tools/bin2hex.py 8 "$OUT/workload.bin" > "$OUT/workload.bin.hex"
    riscv64-unknown-elf-nm "$OUT/workload.elf" > "$OUT/symbols"
    DBG_ADDR=0x$(awk "\$3 == \"tohost\" { print \$1 }" "$OUT/symbols") \
        "$SIM" "$OUT/bootrom.hex" "$OUT/workload.bin.hex" 200000 +TRACE_RETIRE > "$OUT/mints.trace"
    grep -q "test success!" "$OUT/mints.trace"
'
docker run --rm --init -v "$out:/run:ro" -v "$config:/cfg:ro" "$sail" sail_riscv_sim \
    --config /cfg/sail.json --inst-limit 20000 --trace-instr --trace-gpr /run/workload.elf \
    > "$out/sail.trace" 2>&1
end=$(awk '$3 == "trace_end" { print $1 }' "$out/symbols")
python3 tools/act4/mixed_workload.py compare "$out/sail.trace" "$out/mints.trace" "$end"
