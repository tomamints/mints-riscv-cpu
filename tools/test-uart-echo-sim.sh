#!/usr/bin/env bash
# G3 echo: RTL lint + core unit test + board-top simulation in the existing
# Verilator 5.046 Docker image. Logs: build/test/uart-echo/.
# PASS = each marker present AND each simulation exit status 0.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" \
  bash -c 'set -uo pipefail
    out=build/test/uart-echo
    mkdir -p "$out"
    status=0
    verilator --version | tee "$out/verilator-version.log"
    rtl="fpga/de0-cv/rtl/uart_baud_gen.sv fpga/de0-cv/rtl/uart_tx.sv fpga/de0-cv/rtl/uart_rx.sv fpga/de0-cv/rtl/uart_phy.sv fpga/de0-cv/uart_echo/rtl/uart_echo_core.sv fpga/de0-cv/uart_echo/rtl/de0_cv_uart_echo.sv"
    if verilator --lint-only -Wall --top-module de0_cv_uart_echo $rtl > "$out/lint.log" 2>&1; then
      echo "lint: OK"
    else
      echo "lint: FAIL"; status=1
    fi
    cat "$out/lint.log"
    run_tb() {
      local name=$1 top=$2 flist=$3 marker=$4 extra=$5
      if verilator --binary --timing $extra --assert --timescale 1ns/1ps -f "$flist" \
           --top-module "$top" --Mdir "$out/obj_$name" -o "$name" > "$out/build_$name.log" 2>&1; then
        echo "build $name: OK"; grep "%Warning" "$out/build_$name.log" || true
      else
        echo "build $name: FAIL"; status=1; cat "$out/build_$name.log"; return
      fi
      "$out/obj_$name/$name" > "$out/run_$name.log" 2>&1
      local rc=$?
      if [[ $rc -eq 0 ]] && grep -q "^$marker" "$out/run_$name.log"; then
        echo "run $name: PASS (exit=$rc)"
      else
        echo "run $name: FAIL (exit=$rc)"; status=1
      fi
      cat "$out/run_$name.log"
    }
    run_tb echo_core tb_uart_echo_core tb/unit/uart/uart_echo_core_tb.f UART_ECHO_CORE_TB_PASS ""
    run_tb echo_top tb_de0_cv_uart_echo tb/unit/uart/de0_cv_uart_echo_tb.f DE0_CV_UART_ECHO_TB_PASS "--sched-zero-delay"
    exit $status'
