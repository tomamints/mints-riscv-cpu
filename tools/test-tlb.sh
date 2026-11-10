#!/usr/bin/env bash
# TLB unit test at the default (8) and board (4) entry counts.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
set -euo pipefail
out=build/test/tlb
mkdir -p "$out"
for n in 8 4; do
  verilator --binary --timing --assert -Wno-fatal --top-module tb_tlb -GENTRIES=$n \
    --Mdir "$out/obj-$n" -o sim src/eei.sv rtl/mmu/tlb.sv tb/unit/tlb/tb_tlb.sv > "$out/build-$n.log" 2>&1
  "$out/obj-$n/sim" > "$out/run-$n.log" 2>&1 || { tail -3 "$out/run-$n.log"; exit 1; }
  grep "^\[TLB TEST\] pass" "$out/run-$n.log"
done
'
