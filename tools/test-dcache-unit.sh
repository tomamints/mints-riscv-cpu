#!/usr/bin/env bash
# dcache unit test (DATA_RAM_STYLE 0/1 and the saved baseline dcache) in the
# existing Verilator 5.046 image. Logs: build/test/dcache/.
#
# Gates (any failure -> exit 1):
#   * lint: every %Error fails (candidate STYLE0/1 and baseline, wrapper top
#     dcache_probe_top; TB top). -Wall warnings do not gate but are normalized
#     (file basename, no line/column) and classified into
#     lint_warn_new_style<N>.txt  (candidate only: introduced by the change)
#     lint_warn_existing_style<N>.txt (also present in the baseline)
#     lint_warn_removed_style<N>.txt  (baseline only)
#   * build: %Error fails; build warnings are listed.
#   * pass profiles: exit 0 and the DCACHE_TB_PASS marker.
#   * unsupported profile (WRITE_BACK=1 + STYLE=1): non-zero exit with the
#     "unsupported" fatal and without DCACHE_TB_UNSUPPORTED_NOT_RAISED.
#   * WB1 full regression (baseline_wb1_l8_sb4, s0_wb1_l8_sb4) is an
#     EXPECTED FAILURE reproducing a known pre-existing WRITE_BACK=1 failure:
#     the first fatal (time + message, not the TB file:line) must match WB1_XFAIL_TIME/MSG in both, with the
#     same trace prefix; any other outcome (pass, timeout, other failure) fails.
#     It is not reported as a passing regression.
#   * wb1_smoke (baseline/s0): limited WB1 comparison avoiding the known
#     failures; marker DCACHE_TB_WB1_SMOKE_PASS; traces must be identical.
#   * same-stimulus comparison: the CPU operation stream uses its own fixed-seed
#     RNG (memory latency/backpressure use a separate RNG), so the per-operation
#     traces (op, address, architectural value) of
#       baseline_wb0_l8_sb4 / s0_wb0_l8_sb4 / s1_wb0_l8_sb4
#     must be identical. Profiles with other LINES use a different address window
#     and are not compared. Cycle timing is expected to differ and is not compared.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi

baseline=build/baseline/dcache-e9f95e7/dcache.sv
expected_sha=04cdb211a3f1d19fd28ca8da164a3c88573c998e3979447e69e853bc4a22c86b
if [[ ! -s $baseline ]]; then
  mkdir -p "$(dirname "$baseline")"
  git show e9f95e7:rtl/cache/dcache.sv > "$baseline"
fi
got_sha=$(shasum -a 256 "$baseline" | awk '{print $1}')
[[ $got_sha == "$expected_sha" ]] || { echo "baseline hash mismatch: $got_sha" >&2; exit 1; }
echo "baseline $baseline sha256 OK"

docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" \
  bash -c 'set -uo pipefail
    out=build/test/dcache
    if [[ -e "$out" ]]; then
      mkdir -p build/test/archive
      mv "$out" "build/test/archive/dcache-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    mkdir -p "$out"
    status=0
    verilator --version | tee "$out/verilator-version.log"
    common="src/eei.sv src/core_data_if.sv fpga/de0-cv/mem_probe/rtl/ram_1r1w_be64.sv"
    wrapper=fpga/de0-cv/cache_probe/rtl/dcache_probe_top.sv
    norm() {   # normalized, sorted, unique -Wall warnings
      sed -nE "s/^(%Warning-[A-Za-z0-9_]+): ([^ :]*\/)?([^/ :]+):[0-9]+:[0-9]+: (.*)$/\1 \3: \4/p" "$1" | sort -u
    }
    lint() {   # name, args...
      local name=$1; shift
      verilator --lint-only -Wall -Wno-fatal --timing "$@" > "$out/lint_$name.log" 2>&1
      local rc=$?
      if [[ $rc -ne 0 ]] || grep -q "%Error" "$out/lint_$name.log"; then
        echo "lint $name: FAIL (exit=$rc)"; grep "%Error" "$out/lint_$name.log" | head -n 20; status=1
      else
        echo "lint $name: OK ($(grep -c "^%Warning" "$out/lint_$name.log" || true) warnings)"
      fi
    }
    lint base   $common build/baseline/dcache-e9f95e7/dcache.sv $wrapper --top-module dcache_probe_top
    for st in 0 1; do
      lint cand_style$st $common rtl/cache/dcache.sv $wrapper --top-module dcache_probe_top \
        +define+DCACHE_HAS_DATA_RAM_STYLE -GDATA_RAM_STYLE=$st
      norm "$out/lint_base.log" > "$out/lint_warn_base.txt"
      norm "$out/lint_cand_style$st.log" > "$out/lint_warn_cand_style$st.txt"
      comm -13 "$out/lint_warn_base.txt" "$out/lint_warn_cand_style$st.txt" > "$out/lint_warn_new_style$st.txt"
      comm -12 "$out/lint_warn_base.txt" "$out/lint_warn_cand_style$st.txt" > "$out/lint_warn_existing_style$st.txt"
      comm -23 "$out/lint_warn_base.txt" "$out/lint_warn_cand_style$st.txt" > "$out/lint_warn_removed_style$st.txt"
      echo "lint -Wall style$st warnings: new=$(wc -l < "$out/lint_warn_new_style$st.txt")" \
           "existing=$(wc -l < "$out/lint_warn_existing_style$st.txt")" \
           "removed=$(wc -l < "$out/lint_warn_removed_style$st.txt")"
      sed "s/^/  new: /" "$out/lint_warn_new_style$st.txt"
    done
    # TB tops (default warnings): errors gate
    for t in cand base; do
      if [[ $t == cand ]]; then f=tb/unit/cache/dcache_tb.f; d=""; else f=tb/unit/cache/dcache_baseline_tb.f; d=+define+TB_BASELINE_DCACHE; fi
      verilator --lint-only -Wno-fatal --timing $d -f $f --top-module tb_dcache > "$out/lint_tb_$t.log" 2>&1
      rc=$?
      if [[ $rc -ne 0 ]] || grep -q "%Error" "$out/lint_tb_$t.log"; then
        echo "lint tb_$t: FAIL (exit=$rc)"; grep "%Error" "$out/lint_tb_$t.log" | head -n 20; status=1
      else
        echo "lint tb_$t: OK ($(grep -c "^%Warning" "$out/lint_tb_$t.log" || true) warnings)"
      fi
    done
    run() {
      local name=$1 gen=$2 defs=$3 flist=$4 expect=$5
      if ! verilator --binary --timing --assert -Wno-fatal $defs -f "$flist" --top-module tb_dcache $gen \
           --Mdir "$out/obj_$name" -o "$name" > "$out/build_$name.log" 2>&1 \
         || grep -q "%Error" "$out/build_$name.log"; then
        echo "build $name: FAIL"; status=1; cat "$out/build_$name.log"; return
      fi
      grep "^%Warning" "$out/build_$name.log" | sed "s/^/  build warning: /" || true
      timeout 1800 "$out/obj_$name/$name" +trace="$out/trace_$name.txt" > "$out/run_$name.log" 2>&1
      local rc=$?
      if [[ $expect == pass ]]; then
        if [[ $rc -eq 0 ]] && grep -q "^DCACHE_TB_PASS" "$out/run_$name.log"; then
          echo "run $name: PASS"
        else
          echo "run $name: FAIL (exit=$rc)"; status=1
        fi
      elif [[ $expect == smoke ]]; then
        if [[ $rc -eq 0 ]] && grep -q "^DCACHE_TB_WB1_SMOKE_PASS" "$out/run_$name.log"; then
          echo "run $name: PASS (WB1 smoke, limited; not the full regression)"
        else
          echo "run $name: FAIL (exit=$rc)"; status=1
        fi
      elif [[ $expect == xfail_wb1 ]]; then
        # Known pre-existing WRITE_BACK=1 failure (baseline RTL too): invalidate
        # while dirty lines exist returns LoadFillWait to Idle and the outstanding
        # load never gets a response. Must be exactly this failure (message,
        # address, time), non-zero exit, no timeout (124), no PASS marker.
        local fl
        fl=$(grep -m1 "%Fatal" "$out/run_$name.log" || true)
        if [[ $rc -ne 0 && $rc -ne 124 ]] && ! grep -q "^DCACHE_TB_PASS" "$out/run_$name.log" \
           && [[ $fl == "$WB1_XFAIL_TIME"* && $fl == *": $WB1_XFAIL_MSG" ]]; then
          echo "run $name: EXPECTED-FAILURE reproduced (known WB1 invalidate/load hang, exit=$rc)"
        else
          echo "run $name: FAIL (not the known WB1 failure: exit=$rc, first fatal: $fl)"; status=1
        fi
      else
        if [[ $rc -ne 0 ]] && grep -q "unsupported" "$out/run_$name.log" \
           && ! grep -q "DCACHE_TB_UNSUPPORTED_NOT_RAISED" "$out/run_$name.log"; then
          echo "run $name: PASS (expected non-zero exit, exit=$rc)"
        else
          echo "run $name: FAIL (unsupported configuration not rejected, exit=$rc)"; status=1
        fi
      fi
      tail -n 15 "$out/run_$name.log"
    }
    cand=tb/unit/cache/dcache_tb.f
    base=tb/unit/cache/dcache_baseline_tb.f
    run baseline_wb0_l8_sb4 "-GSTYLE=0 -GWB=0 -GLINES=8 -GSBD=4"  "+define+TB_BASELINE_DCACHE" $base pass
    # file:line of the TB is not part of the match (it moves with TB edits)
    WB1_XFAIL_TIME="[216770000] %Fatal: tb_dcache.sv:"
    WB1_XFAIL_MSG="Assertion failed in tb_dcache.cpu_req: [CPU] no response for 0000000080000510 (state=0 mem_valid=0 mem_busy=0 mem_reads=51 rvalid_count=51 resp_expected=1)"
    run baseline_wb1_l8_sb4 "-GSTYLE=0 -GWB=1 -GLINES=8 -GSBD=4"  "+define+TB_BASELINE_DCACHE" $base xfail_wb1
    run s0_wb0_l8_sb4       "-GSTYLE=0 -GWB=0 -GLINES=8 -GSBD=4"  "" $cand pass
    run s1_wb0_l8_sb4       "-GSTYLE=1 -GWB=0 -GLINES=8 -GSBD=4"  "" $cand pass
    run s1_wb0_l32_sb8      "-GSTYLE=1 -GWB=0 -GLINES=32 -GSBD=8" "" $cand pass
    run s0_wb1_l8_sb4       "-GSTYLE=0 -GWB=1 -GLINES=8 -GSBD=4"  "" $cand xfail_wb1
    run baseline_wb1_smoke  "-GSTYLE=0 -GWB=1 -GLINES=8 -GSBD=4"  "+define+TB_BASELINE_DCACHE +define+TB_WB1_SMOKE" $base smoke
    run s0_wb1_smoke        "-GSTYLE=0 -GWB=1 -GLINES=8 -GSBD=4"  "+define+TB_WB1_SMOKE" $cand smoke
    run unsupported         "-GSTYLE=1 -GWB=1 -GLINES=8 -GSBD=4"  "+define+TB_UNSUPPORTED_PROFILE" $cand fail
    cmp_trace() {
      local a=$1 b=$2 m=${3:-^DCACHE_TB_PASS}
      if ! grep -q "$m" "$out/run_$a.log" || ! grep -q "$m" "$out/run_$b.log"; then
        echo "trace $a vs $b: FAIL (both runs must pass before their traces are compared)"; status=1; return
      fi
      if [[ -s $out/trace_$a.txt ]] && cmp -s "$out/trace_$a.txt" "$out/trace_$b.txt"; then
        echo "trace $a == $b: PASS ($(wc -l < "$out/trace_$a.txt") ops)"
      else
        echo "trace $a vs $b: FAIL"; status=1
        diff "$out/trace_$a.txt" "$out/trace_$b.txt" | head -n 10 || true
      fi
    }
    cmp_trace baseline_wb0_l8_sb4 s0_wb0_l8_sb4
    cmp_trace baseline_wb0_l8_sb4 s1_wb0_l8_sb4
    cmp_trace baseline_wb1_smoke s0_wb1_smoke "^DCACHE_TB_WB1_SMOKE_PASS"
    # expected-failure reproduction: same first fatal and identical trace prefix
    fa=$(grep -m1 "%Fatal" "$out/run_baseline_wb1_l8_sb4.log" || true)
    fb=$(grep -m1 "%Fatal" "$out/run_s0_wb1_l8_sb4.log" || true)
    if [[ -n $fa && $fa == "$fb" && -s $out/trace_baseline_wb1_l8_sb4.txt ]] \
       && cmp -s "$out/trace_baseline_wb1_l8_sb4.txt" "$out/trace_s0_wb1_l8_sb4.txt"; then
      echo "WB1 expected-failure: baseline and candidate identical (fatal line and $(wc -l < "$out/trace_baseline_wb1_l8_sb4.txt") ops of trace prefix)"
    else
      echo "WB1 expected-failure: baseline/candidate differ: FAIL"; status=1
    fi
    exit $status'
