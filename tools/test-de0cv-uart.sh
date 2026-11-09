#!/usr/bin/env bash
# Lint, build and run the DE0-CV UART PHY unit test (50 MHz and 20 MHz) inside
# the existing Verilator 5.046 Docker image. Logs: build/test/uart/.
# Exit status is non-zero if any step fails.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" \
  bash -c 'set -uo pipefail
    out=build/test/uart
    mkdir -p "$out"
    rtl="fpga/de0-cv/rtl/uart_baud_gen.sv fpga/de0-cv/rtl/uart_tx.sv fpga/de0-cv/rtl/uart_rx.sv fpga/de0-cv/rtl/uart_phy.sv"
    status=0
    verilator --version | tee "$out/verilator-version.log"

    echo "== lint (RTL, -Wall) =="
    if verilator --lint-only -Wall --top-module uart_phy $rtl > "$out/lint.log" 2>&1; then
      echo "lint: OK"
    else
      echo "lint: FAIL"; status=1
    fi
    cat "$out/lint.log"

    for hz in 50000000 20000000; do
      tag=$((hz / 1000000))m
      echo "== build CLK_HZ=$hz =="
      if verilator --binary --timing --sched-zero-delay --assert --timescale 1ns/1ps \
           -f tb/unit/uart/uart_phy_tb.f --top-module tb_uart_phy -GCLK_HZ=$hz \
           --Mdir "$out/obj_$tag" -o "tb_uart_phy_$tag" > "$out/build_$tag.log" 2>&1; then
        echo "build $tag: OK"
      else
        echo "build $tag: FAIL"; status=1
        cat "$out/build_$tag.log"
        continue
      fi
      grep -i "%Warning" "$out/build_$tag.log" || true
      echo "== run CLK_HZ=$hz =="
      if "$out/obj_$tag/tb_uart_phy_$tag" > "$out/run_$tag.log" 2>&1 \
         && grep -q "UART_PHY_TB_PASS clk_hz=$hz" "$out/run_$tag.log"; then
        echo "run $tag: PASS"
      else
        echo "run $tag: FAIL"; status=1
      fi
      tail -n 40 "$out/run_$tag.log"
    done
    exit $status'
