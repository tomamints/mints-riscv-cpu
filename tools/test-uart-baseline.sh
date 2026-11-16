#!/usr/bin/env bash
# Records the baseline of the existing UART C tests against the CURRENT
# src/uart_ns16550.sv, inside the existing Verilator 5.046 Docker image.
# Neither the UART RTL nor the C tests are modified by this script.
#
# Classification per test (from the log markers, not from make's exit code;
# the simulator returns 0 even when the cycle limit is reached):
#   PASS     : "test success!" present, no "test failed!", no %Error, make exit 0
#   FAIL     : "test failed!" or "%Error" present (incl. main() returning: code 3)
#   TIMEOUT  : no success/failure marker before the cycle limit (CYCLES) or the
#              host wall-clock limit. Note: the tests' fail() writes 2 to the
#              debug MMIO, which the top does NOT treat as a finish request, so a
#              fail() inside a test shows up as TIMEOUT.
#   BUILD_FAIL: simulator or test image did not build
#
# Output: build/test/uart-baseline/{summary.txt,*.log}; exit 0 only if all PASS.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" \
  bash -c 'set -uo pipefail
    out=build/test/uart-baseline
    mkdir -p "$out"
    : > "$out/summary.txt"
    git_rev=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
    {
      echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "git HEAD: $git_rev (working tree may contain uncommitted harness changes)"
      verilator --version
      riscv64-linux-gnu-gcc --version | head -n1
    } > "$out/environment.txt"

    mkargs=(
      RISCV_PREFIX=riscv64-linux-gnu-
      "RISCV_CFLAGS=-march=rv64ima_zicsr -mabi=lp64 -mcmodel=medany -nostdlib -nostartfiles -static -fno-pie -no-pie -fno-asynchronous-unwind-tables -Wl,--build-id=none"
      OBJ_DIR=$out/obj_dir
      INPUT_OBJ_DIR=$out/obj_dir_input
      TEST_BUILD_DIR=$out/sw
    )

    echo "== build simulators =="
    if ! make "${mkargs[@]}" build > "$out/build-sim.log" 2>&1; then
      echo "BUILD_FAIL sim (see build-sim.log)" | tee -a "$out/summary.txt"; exit 2
    fi
    if ! make "${mkargs[@]}" build-input > "$out/build-sim-input.log" 2>&1; then
      echo "BUILD_FAIL sim-input (see build-sim-input.log)" | tee -a "$out/summary.txt"; exit 2
    fi

    overall=0
    run_one() {
      local name=$1; shift
      local log="$out/$name.log"
      local rc cls
      timeout 600 make "${mkargs[@]}" "$@" > "$log" 2>&1
      rc=$?
      if ! grep -q "memory: initializing from" "$log"; then
        cls=BUILD_FAIL          # the simulator never started
      elif grep -q "test failed!" "$log" || grep -q "^%Error" "$log"; then
        cls=FAIL
      elif grep -q "test success!" "$log" && [[ $rc -eq 0 ]]; then
        cls=PASS
      elif grep -q "test success!" "$log"; then
        cls=FAIL                # success marker but make/sim failed
      else
        cls=TIMEOUT             # cycle limit (or host 600 s limit, rc=124)
      fi
      [[ $cls == PASS ]] || overall=1
      printf "%-10s %-20s make_exit=%-3s args=%s\n" "$cls" "$name" "$rc" "$*" | tee -a "$out/summary.txt"
    }

    run_one test-uart          test-uart
    run_one test-uart-input    test-uart-input INPUT_TEXT=Z
    run_one test-uart-regs     test-uart-regs
    run_one test-uart-tx-irq   test-uart-tx-irq
    run_one test-uart-tx-seip  test-uart-tx-seip
    run_one test-uart-rx-seip  test-uart-rx-seip INPUT_TEXT=Z
    exit $overall'
