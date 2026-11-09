#!/usr/bin/env bash
# ram_1r1w_be64 bank: RTL lint + unit TB (sync P128/P32, async P128/P32) +
# expected-failure collision profile, in the existing Verilator 5.046 image.
# Logs: build/test/mem-probe/. Exit status non-zero if any step fails.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" \
  bash -c 'set -uo pipefail
    out=build/test/mem-probe
    mkdir -p "$out"
    status=0
    verilator --version | tee "$out/verilator-version.log"
    rtl="fpga/de0-cv/mem_probe/rtl/ram_1r1w_be64.sv fpga/de0-cv/mem_probe/rtl/ram_1r1w_be64_async.sv fpga/de0-cv/mem_probe/rtl/mem_probe_top.sv"
    for g in "-GDEPTH=128 -GNBANK=1 -GSTYLE=2 -GASYNC=0" "-GDEPTH=32 -GNBANK=4 -GSTYLE=0 -GASYNC=0" "-GDEPTH=128 -GNBANK=1 -GASYNC=1"; do
      tag=$(echo "$g" | tr -d " =-" )
      if verilator --lint-only -Wall --top-module mem_probe_top $g $rtl > "$out/lint_$tag.log" 2>&1; then
        echo "lint $g: OK"
      else
        echo "lint $g: FAIL"; status=1; cat "$out/lint_$tag.log"
      fi
    done
    run_tb() {
      local name=$1 gen=$2 defs=$3 expect=$4
      if ! verilator --binary --timing --assert --timescale 1ns/1ps $defs -f tb/unit/mem/ram_1r1w_be64_tb.f \
           --top-module tb_ram_1r1w_be64 $gen --Mdir "$out/obj_$name" -o "$name" > "$out/build_$name.log" 2>&1; then
        echo "build $name: FAIL"; status=1; cat "$out/build_$name.log"; return
      fi
      grep "%Warning" "$out/build_$name.log" || true
      "$out/obj_$name/$name" > "$out/run_$name.log" 2>&1
      local rc=$?
      if [[ $expect == pass ]]; then
        if [[ $rc -eq 0 ]] && grep -q "^RAM_1R1W_BE64_TB_PASS" "$out/run_$name.log"; then
          echo "run $name: PASS"
        else
          echo "run $name: FAIL (exit=$rc)"; status=1
        fi
      else
        if [[ $rc -ne 0 ]] && grep -q "forbidden read-during-write collision" "$out/run_$name.log" \
           && ! grep -q "RAM_TB_COLLISION_NOT_RAISED" "$out/run_$name.log"; then
          echo "run $name: PASS (expected non-zero exit, exit=$rc)"
        else
          echo "run $name: FAIL (collision not detected, exit=$rc)"; status=1
        fi
      fi
      tail -n 12 "$out/run_$name.log"
    }
    run_tb sync_p128  "-GDEPTH=128 -GASYNC=0 -GSTYLE=2" "" pass
    run_tb sync_p32   "-GDEPTH=32 -GASYNC=0 -GSTYLE=2"  "" pass
    run_tb async_p128 "-GDEPTH=128 -GASYNC=1"           "" pass
    run_tb async_p32  "-GDEPTH=32 -GASYNC=1"            "" pass
    run_tb collision  "-GDEPTH=32 -GASYNC=0 -GSTYLE=2"  "+define+TB_COLLISION_PROFILE" fail
    exit $status'
