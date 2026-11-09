#!/usr/bin/env bash
# Lint, build and run the uart16550_regs unit test in the existing Verilator
# 5.046 Docker image. Logs: build/test/uart-regs/.
#   1. RTL lint (-Wall), with and without MINTS_SIM
#   2. functional TB (no MINTS_SIM): PASS = UART16550_REGS_TB_PASS and exit 0
#   3. sim-error profile (MINTS_SIM + TB_SIM_ERROR_PROFILE): PASS = non-zero exit,
#      the RTL "THR write dropped" $error in the log, and no
#      UART16550_REGS_SIM_ERROR_NOT_RAISED marker
# Exit status is non-zero if any step fails.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" \
  bash -c 'set -uo pipefail
    out=build/test/uart-regs
    mkdir -p "$out"
    status=0
    verilator --version | tee "$out/verilator-version.log"
    rtl="src/eei.sv src/membus_if.sv rtl/peripheral/uart16550_regs.sv"

    for prof in plain mints_sim; do
      defs=""
      [[ $prof == mints_sim ]] && defs="+define+MINTS_SIM"
      # -Wall over the regs plus the shared packages it needs. Verilator exits
      # non-zero because of warnings in the pre-existing shared files
      # (src/eei.sv, src/membus_if.sv), which are out of scope and NOT disabled;
      # they are counted separately. The new RTL must have zero warnings/errors.
      verilator --lint-only -Wall $defs --top-module uart16550_regs $rtl > "$out/lint_$prof.log" 2>&1
      lrc=$?
      own=$(grep -cE "^%(Warning|Error)[^:]*: rtl/peripheral/uart16550_regs.sv" "$out/lint_$prof.log" || true)
      ext=$(grep -cE "^%Warning[^:]*: src/(eei|membus_if).sv" "$out/lint_$prof.log" || true)
      oth=$(grep -E "^%(Warning|Error)" "$out/lint_$prof.log" | grep -vE ": (rtl/peripheral/uart16550_regs.sv|src/eei.sv|src/membus_if.sv)" | grep -vc "^%Error: Exiting due to" || true)
      grep -E "^%Warning" "$out/lint_$prof.log" | grep -E "src/(eei|membus_if).sv" | sed -E "s/^(%Warning-[A-Z]+): ([^:]+).*/\1 \2/" | sort | uniq -c > "$out/lint_${prof}_external_summary.txt"
      errors=$(grep -E "^%Error" "$out/lint_$prof.log" | grep -vc "^%Error: Exiting due to [0-9]* warning" || true)
      if [[ $own -eq 0 && $oth -eq 0 && $errors -eq 0 && $ext -eq 66 && $lrc -eq 1 ]]; then
        echo "lint $prof: OK (uart16550_regs.sv: 0 warnings; pre-existing shared files: $ext warnings, verilator exit=$lrc)"
      else
        echo "lint $prof: FAIL (uart16550_regs.sv: $own, other: $oth)"; status=1
        grep -E "^%(Warning|Error)" "$out/lint_$prof.log" | grep -v "src/eei.sv\|src/membus_if.sv"
      fi
      cat "$out/lint_${prof}_external_summary.txt"
    done

    echo "== functional TB =="
    if verilator --binary --timing --assert --timescale 1ns/1ps \
         -f tb/unit/uart/uart16550_regs_tb.f --top-module tb_uart16550_regs \
         --Mdir "$out/obj" -o tb_uart16550_regs > "$out/build.log" 2>&1; then
      echo "build: OK"
      grep "%Warning" "$out/build.log" || true
      "$out/obj/tb_uart16550_regs" > "$out/run.log" 2>&1
      rc=$?
      echo "run exit=$rc"
      if [[ $rc -eq 0 ]] && grep -q "^UART16550_REGS_TB_PASS" "$out/run.log"; then
        echo "functional: PASS ($(grep -c "^\[T\] .*PASS" "$out/run.log") test groups)"
      else
        echo "functional: FAIL"; status=1
      fi
      cat "$out/run.log"
    else
      echo "build: FAIL"; status=1; cat "$out/build.log"
    fi

    echo "== sim-error profile (non-zero exit expected) =="
    if verilator --binary --timing --assert --timescale 1ns/1ps +define+MINTS_SIM +define+TB_SIM_ERROR_PROFILE \
         -f tb/unit/uart/uart16550_regs_tb.f --top-module tb_uart16550_regs \
         --Mdir "$out/obj_simerr" -o tb_uart16550_regs_simerr > "$out/build_simerr.log" 2>&1; then
      echo "build simerr: OK"
      grep "%Warning" "$out/build_simerr.log" || true
      "$out/obj_simerr/tb_uart16550_regs_simerr" > "$out/run_simerr.log" 2>&1
      rc=$?
      echo "simerr exit=$rc"
      if [[ $rc -ne 0 ]] && grep -q "uart16550_regs: THR write dropped" "$out/run_simerr.log" \
         && ! grep -q "UART16550_REGS_SIM_ERROR_NOT_RAISED" "$out/run_simerr.log"; then
        echo "simerr profile: PASS (expected non-zero exit with RTL \$error)"
      else
        echo "simerr profile: FAIL"; status=1
      fi
      cat "$out/run_simerr.log"
    else
      echo "build simerr: FAIL"; status=1; cat "$out/build_simerr.log"
    fi
    exit $status'
