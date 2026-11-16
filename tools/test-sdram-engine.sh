#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo \
  -e SDRAM_CLK_HZ="${SDRAM_CLK_HZ:-50000000}" \
  "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
    set -euo pipefail
    hz="$SDRAM_CLK_HZ"
    out=build/test/sdram-engine
    [[ "$hz" == 50000000 ]] || out="$out-$hz"
    echo "SDRAM clock profile $hz Hz"
    if [[ -e "$out" ]]; then
      mkdir -p build/test/archive
      mv "$out" "build/test/archive/sdram-engine-$hz-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    mkdir -p "$out"
    verilator --lint-only -Wall --top-module sdram_test_engine \
      fpga/de0-cv/sdram/rtl/sdram_test_engine.sv > "$out/lint.log" 2>&1
    for injected in 0 1; do
    verilator --binary --timing --assert --timescale 1ns/1ps \
      --top-module tb_sdram_test_engine -GINJECT_BAD_DATA=$injected -GCLK_HZ=$hz --Mdir "$out/obj$injected" -o sim \
      fpga/de0-cv/sdram/rtl/sdram_native16.sv \
      fpga/de0-cv/sdram/rtl/sdram_bridge64.sv \
      fpga/de0-cv/sdram/rtl/sdram_test_engine.sv \
      tb/unit/sdram/sdram_pin_model16.sv tb/unit/sdram/tb_sdram_test_engine.sv \
      > "$out/build$injected.log" 2>&1
    "$out/obj$injected/sim" > "$out/run$injected.log" 2>&1
    grep -q "^SDRAM_TEST_ENGINE_PASS" "$out/run$injected.log"
    cat "$out/run$injected.log"
    done
  '
