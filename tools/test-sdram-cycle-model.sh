#!/usr/bin/env bash
# Cross-check of tb/model/sdram_cycle_model16.sv (clock-sampled, for CPU-level
# simulation) against the timing-mode pin model, through the real adapter,
# bridge and controller, at 20 MHz and 50 MHz; plus a mutation that must fail.
# Logs: build/test/sdram-cycle-model/.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" \
  bash -c 'set -uo pipefail
    out=build/test/sdram-cycle-model
    if [[ -e "$out" ]]; then
      mkdir -p build/test/archive
      mv "$out" "build/test/archive/sdram-cycle-model-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    mkdir -p "$out"
    status=0
    model=tb/model/sdram_cycle_model16.sv
    srcs="src/eei.sv src/membus_if.sv rtl/bus/membus_sdram_adapter.sv fpga/de0-cv/sdram/rtl/sdram_bridge64.sv fpga/de0-cv/sdram/rtl/sdram_native16.sv tb/unit/sdram/sdram_pin_model16.sv $model"
    tb=tb/unit/sdram/tb_sdram_model_crosscheck.sv
    sha256sum $srcs $tb tb/model/sdram_preloader.sv tb/model/sdram_backend.f > "$out/sources.sha256"
    # model lint (-Wall); diagnostics in the model file are reported, errors fail
    verilator --lint-only -Wall -Wno-fatal --top-module sdram_cycle_model16 $model > "$out/lint.log" 2>&1
    lint_rc=$?
    grep -E "^%(Warning|Error)" "$out/lint.log" > "$out/lint_model.txt"
    echo "model lint rc=$lint_rc diagnostics=$(wc -l < "$out/lint_model.txt") errors=$(grep -c "^%Error" "$out/lint.log")"
    cat "$out/lint_model.txt"
    if [[ $lint_rc -ne 0 ]] || grep -q "^%Error" "$out/lint.log"; then status=1; fi
    for hz in 20000000 50000000; do
      verilator --binary --timing --assert -Wno-fatal --top-module tb_sdram_model_crosscheck -GCLK_HZ=$hz \
        --Mdir "$out/obj_$hz" -o sim $srcs $tb > "$out/build_$hz.log" 2>&1 || { echo "FAIL build $hz"; status=1; continue; }
      if timeout 1200 "$out/obj_$hz/sim" > "$out/run_$hz.log" 2>&1 && grep -q "^SDRAM_MODEL_CROSSCHECK_PASS" "$out/run_$hz.log"; then
        echo "PASS $hz: $(grep "^SDRAM_MODEL_CROSSCHECK_PASS" "$out/run_$hz.log")"
      else
        echo "FAIL $hz (see $out/run_$hz.log)"; status=1
      fi
    done
    # mutation: stack C read data one cycle late must be detected
    verilator --binary --timing --assert -Wno-fatal --top-module tb_sdram_model_crosscheck -DTB_MUTATE_DELAY \
      --Mdir "$out/obj_mutate" -o sim $srcs $tb > "$out/build_mutate.log" 2>&1 || { echo "FAIL build mutate"; status=1; }
    timeout 1200 "$out/obj_mutate/sim" > "$out/run_mutate.log" 2>&1; rc=$?
    if [[ $rc -ne 0 && $rc -ne 124 ]] && grep -qE "\[CROSS\]|\[SHADOW\]" "$out/run_mutate.log" && ! grep -q "^SDRAM_MODEL_CROSSCHECK_PASS" "$out/run_mutate.log"; then
      echo "EXPECTED-FAIL mutate rc=$rc: $(grep -m1 -E "\[CROSS\]|\[SHADOW\]" "$out/run_mutate.log")"
    else
      echo "FAIL mutate: delayed read data was not detected (rc=$rc)"; status=1
    fi
    [[ $status -eq 0 ]] && echo SDRAM_CYCLE_MODEL_PASS || echo SDRAM_CYCLE_MODEL_FAIL
    exit $status
  '
