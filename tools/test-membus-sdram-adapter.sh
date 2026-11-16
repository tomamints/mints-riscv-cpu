#!/usr/bin/env bash
# Unit test for rtl/bus/membus_sdram_adapter.sv with sdram_bridge64, sdram_native16
# and the independent pin model, at the 20 MHz and 50 MHz controller profiles.
# Logs: build/test/membus-sdram-adapter/.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" \
  bash -c 'set -uo pipefail
    out=build/test/membus-sdram-adapter
    if [[ -e "$out" ]]; then
      mkdir -p build/test/archive
      mv "$out" "build/test/archive/membus-sdram-adapter-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    mkdir -p "$out"
    status=0
    rtl="src/eei.sv src/membus_if.sv rtl/bus/membus_sdram_adapter.sv"
    sdram="fpga/de0-cv/sdram/rtl/sdram_bridge64.sv fpga/de0-cv/sdram/rtl/sdram_native16.sv tb/unit/sdram/sdram_pin_model16.sv"
    tb=tb/unit/sdram/tb_membus_sdram_adapter.sv
    sha256sum $rtl $sdram $tb tb/unit/sdram/tb_membus_sdram_adapter_faults.sv > "$out/sources.sha256"
    # -Wall with a scoped baseline: warnings from the context files (eei/membus_if)
    # are recorded, not hidden; any diagnostic in the adapter file or any %Error fails.
    verilator --lint-only -Wall -Wno-fatal --top-module membus_sdram_adapter $rtl > "$out/lint.log" 2>&1
    lint_rc=$?
    grep -E "^%(Warning|Error)" "$out/lint.log" | grep "rtl/bus/membus_sdram_adapter.sv" > "$out/lint_adapter.txt"
    grep -E "^%Warning" "$out/lint.log" | grep -v "rtl/bus/membus_sdram_adapter.sv" | sed -E "s/:[0-9]+:[0-9]+:/:/" | LC_ALL=C sort > "$out/lint_context_baseline.txt"
    echo "lint rc=$lint_rc adapter-file diagnostics=$(wc -l < "$out/lint_adapter.txt") context warnings=$(wc -l < "$out/lint_context_baseline.txt") errors=$(grep -c "^%Error" "$out/lint.log")"
    if [[ $lint_rc -ne 0 ]] || [[ -s "$out/lint_adapter.txt" ]] || grep -q "^%Error" "$out/lint.log"; then
      cat "$out/lint_adapter.txt"; status=1
    fi
    # adapter-only fault harness (bridge error, unsolicited response, same-cycle request)
    verilator --binary --timing --assert -Wno-fatal --top-module tb_membus_sdram_adapter_faults \
      --Mdir "$out/obj_faults" -o sim $rtl tb/unit/sdram/tb_membus_sdram_adapter_faults.sv > "$out/build_faults.log" 2>&1 \
      || { echo "FAIL build faults"; status=1; }
    if timeout 300 "$out/obj_faults/sim" +MEMBUS_SDRAM_FAULT_NONFATAL > "$out/run_faults.log" 2>&1 \
        && grep -q "^MEMBUS_SDRAM_ADAPTER_FAULTS_PASS" "$out/run_faults.log"; then
      echo "PASS faults: $(grep "^MEMBUS_SDRAM_ADAPTER_FAULTS_PASS" "$out/run_faults.log")"
    else
      echo "FAIL faults (see $out/run_faults.log)"; status=1
    fi
    for hz in 20000000 50000000; do
      verilator --binary --timing --assert -Wno-fatal --top-module tb_membus_sdram_adapter -GCLK_HZ=$hz \
        --Mdir "$out/obj_$hz" -o sim $rtl $sdram $tb > "$out/build_$hz.log" 2>&1 \
        || { echo "FAIL build $hz"; status=1; continue; }
      if timeout 1200 "$out/obj_$hz/sim" +MEMBUS_SDRAM_FAULT_NONFATAL > "$out/run_$hz.log" 2>&1 \
          && grep -q "^MEMBUS_SDRAM_ADAPTER_PASS" "$out/run_$hz.log"; then
        echo "PASS $hz: $(grep "^MEMBUS_SDRAM_ADAPTER_PASS" "$out/run_$hz.log")"
      else
        echo "FAIL $hz (see $out/run_$hz.log)"; status=1
      fi
      # without the plusarg the first fault must be fatal
      timeout 1200 "$out/obj_$hz/sim" > "$out/run_${hz}_fatal.log" 2>&1; rc=$?
      if [[ $rc -ne 0 && $rc -ne 124 ]] && grep -q "MEMBUS_SDRAM_FAULT kind=1" "$out/run_${hz}_fatal.log" \
          && ! grep -q "^MEMBUS_SDRAM_ADAPTER_PASS" "$out/run_${hz}_fatal.log"; then
        echo "EXPECTED-FAIL ${hz}_fatal rc=$rc"
      else
        echo "FAIL ${hz}_fatal: expected a fatal range fault (rc=$rc)"; status=1
      fi
    done
    [[ $status -eq 0 ]] && echo MEMBUS_SDRAM_ADAPTER_UNIT_PASS || echo MEMBUS_SDRAM_ADAPTER_UNIT_FAIL
    exit $status
  '
