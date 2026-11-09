#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo \
  "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
    set -euo pipefail
    out=build/test/sdram-bridge64
    if [[ -e "$out" ]]; then
      mkdir -p build/test/archive
      mv "$out" "build/test/archive/sdram-bridge64-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    mkdir -p "$out"
    rtl=fpga/de0-cv/sdram/rtl/sdram_bridge64.sv
    verilator --lint-only -Wall --top-module sdram_bridge64 "$rtl" > "$out/lint.log" 2>&1
    for integrated in 0 1; do
      verilator --binary --timing --assert --top-module tb_sdram_bridge64 \
        -GINTEGRATED=$integrated --Mdir "$out/obj_$integrated" -o sim "$rtl" \
        fpga/de0-cv/sdram/rtl/sdram_native16.sv tb/unit/sdram/sdram_pin_model16.sv \
        tb/unit/sdram/tb_sdram_bridge64.sv > "$out/build_$integrated.log" 2>&1
      "$out/obj_$integrated/sim" > "$out/run_$integrated.log" 2>&1
      grep -q "^SDRAM_BRIDGE64_PASS integrated=$integrated" "$out/run_$integrated.log"
      cat "$out/run_$integrated.log"
    done
  '
