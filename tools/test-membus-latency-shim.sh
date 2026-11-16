#!/usr/bin/env bash
# Unit test for the simulation-only RAM latency shim (tb/model/membus_latency_shim.sv)
# in the Verilator 5.046 image. Logs: build/test/membus-latency-shim/.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" \
  bash -c 'set -uo pipefail
    out=build/test/membus-latency-shim
    if [[ -e "$out" ]]; then
      mkdir -p build/test/archive
      mv "$out" "build/test/archive/membus-latency-shim-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    mkdir -p "$out"
    status=0
    srcs="src/eei.sv src/membus_if.sv tb/model/membus_latency_shim.sv"
    sha256sum $srcs tb/unit/mem/tb_membus_latency_shim.sv > "$out/sources.sha256"

    # lint of the shim alone (Membus/eei for context); any %Error fails
    verilator --lint-only -Wall -Wno-fatal --top-module membus_latency_shim $srcs > "$out/lint.log" 2>&1
    lint_rc=$?
    if [[ $lint_rc -ne 0 ]] || grep -q "^%Error" "$out/lint.log"; then echo "FAIL lint rc=$lint_rc"; status=1; fi
    echo "lint warnings=$(grep -c "^%Warning" "$out/lint.log" || true)"

    build() { # name defines...
      local name=$1; shift
      verilator --binary --timing --assert -Wno-fatal --top-module tb_membus_latency_shim "$@" \
        --Mdir "$out/obj_$name" -o sim $srcs tb/unit/mem/tb_membus_latency_shim.sv > "$out/build_$name.log" 2>&1 \
        || { echo "FAIL build $name"; status=1; return 1; }
    }
    build pos
    build neg_spurious -DTB_NEG_SPURIOUS

    run_pass() { # label args...
      local label=$1; shift
      if timeout 600 "$out/obj_pos/sim" "$@" > "$out/run_$label.log" 2>&1 && grep -q "^SHIM_TB_PASS" "$out/run_$label.log"; then
        echo "PASS $label: $(grep "^SHIM_TB_PASS" "$out/run_$label.log")"
      else
        echo "FAIL $label (see $out/run_$label.log)"; status=1
      fi
    }
    run_fail() { # label expected-message args...
      local label=$1 msg=$2 bin=$3; shift 3
      timeout 600 "$bin" "$@" > "$out/run_$label.log" 2>&1; local rc=$?
      if [[ $rc -ne 0 && $rc -ne 124 ]] && grep -q "$msg" "$out/run_$label.log" && ! grep -q "^SHIM_TB_PASS" "$out/run_$label.log"; then
        echo "EXPECTED-FAIL $label rc=$rc"
      else
        echo "FAIL $label: expected failure with \"$msg\" (rc=$rc)"; status=1
      fi
    }

    for seed in 1 7 42; do
      run_pass "default_s$seed" +TB_SEED=$seed +RAM_SHIM_SEED=$seed
      run_pass "fast_s$seed"    +TB_SEED=$seed +RAM_SHIM_SEED=$seed +RAM_SHIM_READY_MAX=0 +RAM_SHIM_RSP_MIN=0 +RAM_SHIM_RSP_MAX=0 +RAM_SHIM_REFRESH_PERIOD=0
      run_pass "heavy_s$seed"   +TB_SEED=$seed +RAM_SHIM_SEED=$seed +RAM_SHIM_READY_MAX=7 +RAM_SHIM_RSP_MIN=5 +RAM_SHIM_RSP_MAX=200 +RAM_SHIM_REFRESH_PERIOD=50 +RAM_SHIM_REFRESH_LEN=20
    done
    # the fast profile must exercise R3 (response and new acceptance in one cycle)
    for seed in 1 7 42; do
      grep -q "r3=[1-9]" "$out/run_fast_s$seed.log" || { echo "FAIL fast_s$seed: no R3 coincidence"; status=1; }
    done

    run_fail neg_seed0     "RAM_SHIM_SEED must be non-zero"   "$out/obj_pos/sim" +RAM_SHIM_SEED=0
    run_fail neg_range     "delay plusarg out of range"       "$out/obj_pos/sim" +RAM_SHIM_RSP_MAX=-1
    run_fail neg_minmax    "RAM_SHIM_RSP_MIN > RAM_SHIM_RSP_MAX" "$out/obj_pos/sim" +RAM_SHIM_RSP_MIN=5 +RAM_SHIM_RSP_MAX=2
    run_fail neg_refresh   "RAM_SHIM_REFRESH_LEN must be"     "$out/obj_pos/sim" +RAM_SHIM_REFRESH_PERIOD=10 +RAM_SHIM_REFRESH_LEN=10
    run_fail neg_spurious  "downstream rvalid without outstanding" "$out/obj_neg_spurious/sim" +TB_SEED=1 +RAM_SHIM_SEED=1

    [[ $status -eq 0 ]] && echo "MEMBUS_LATENCY_SHIM_UNIT_PASS" || echo "MEMBUS_LATENCY_SHIM_UNIT_FAIL"
    exit $status
  '
