#!/usr/bin/env bash
# Build and run the uart16550_regs + uart_phy bit-level integration test at
# 50 MHz and 20 MHz in the existing Verilator 5.046 Docker image.
# Logs: build/test/uart-integ/. PASS per clock = "UART16550_PHY_TB_PASS clk_hz=<N>"
# in the log AND exit status 0. Exit status is non-zero if any step fails.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" \
  bash -c 'set -uo pipefail
    out=build/test/uart-integ
    mkdir -p "$out"
    status=0
    verilator --version | tee "$out/verilator-version.log"
    for hz in 50000000 20000000; do
      tag=$((hz / 1000000))m
      echo "== build CLK_HZ=$hz =="
      if verilator --binary --timing --sched-zero-delay --assert --timescale 1ns/1ps \
           -f tb/unit/uart/uart16550_phy_tb.f --top-module tb_uart16550_phy -GCLK_HZ=$hz \
           --Mdir "$out/obj_$tag" -o "tb_uart16550_phy_$tag" > "$out/build_$tag.log" 2>&1; then
        echo "build $tag: OK"
        grep "%Warning" "$out/build_$tag.log" || true
      else
        echo "build $tag: FAIL"; status=1; cat "$out/build_$tag.log"; continue
      fi
      "$out/obj_$tag/tb_uart16550_phy_$tag" > "$out/run_$tag.log" 2>&1
      rc=$?
      if [[ $rc -eq 0 ]] && grep -q "^UART16550_PHY_TB_PASS clk_hz=$hz" "$out/run_$tag.log"; then
        echo "run $tag: PASS (exit=$rc, $(grep -c "^\[T\] .*PASS" "$out/run_$tag.log") test groups)"
      else
        echo "run $tag: FAIL (exit=$rc)"; status=1
      fi
      cat "$out/run_$tag.log"
    done
    exit $status'
