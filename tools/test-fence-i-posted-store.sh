#!/usr/bin/env bash
# Directed fence.i / posted-store counterexample (C3 M2) in the Verilator 5.046 image.
# Builds the test (miss and hit variants), isolated simulators (STYLE0/1, shim
# on/off; P32 SB4 WB0), runs the matrix and classifies each run.
# This is a counterexample run: failures are reported, not hidden. The script
# exits non-zero if any run fails, any build fails, or a classification is missing.
# Logs: build/test/fence-i-posted-store/ (RAM_BACKEND=sim, default) or
# build/test/fence-i-posted-store-sdram_model/ (RAM_BACKEND=sdram_model: the RAM
# path is adapter -> bridge64 -> native16 -> cycle model; with the shim enabled
# the shim sits upstream of the adapter and adds its delays on top of the real
# SDRAM latency, and its trace/fence observer provide the causal evidence).
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
# riscv-tests environment/macros (pinned) are fetched and built on demand.
if [[ ! -f build/riscv-tests/env/p/riscv_test.h || ! -f build/riscv-tests/isa/macros/scalar/test_macros.h ]]; then
  bash tools/setup-riscv-tests.sh
fi
RAM_BACKEND=${RAM_BACKEND:-sim}
case $RAM_BACKEND in sim|sdram_model) ;; *) echo "RAM_BACKEND must be sim or sdram_model" >&2; exit 2;; esac
docker run --rm --init -e MAKEFLAGS=-j2 -e RAM_BACKEND="$RAM_BACKEND" -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" \
  bash -c 'set -uo pipefail
    sfx=""; [[ $RAM_BACKEND == sdram_model ]] && sfx="-sdram_model"
    out=build/test/fence-i-posted-store$sfx
    echo "RAM_BACKEND=$RAM_BACKEND"
    if [[ -e "$out" ]]; then
      mkdir -p build/test/archive
      mv "$out" "build/test/archive/fence-i-posted-store$sfx-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    mkdir -p "$out/elf" "$out/boot"
    status=0
    # obj_dir_input/sim is optional; when present it must be unchanged by this run.
    [[ -f obj_dir_input/sim ]] && sha256sum obj_dir_input/sim > "$out/obj_dir_input.before.sha256"
    # bare test bootrom built from the repository sources into this output
    make bootrom-build TEST_BUILD_DIR=$out/boot > "$out/bootrom.log" 2>&1 \
      || { echo "FAIL bootrom build (see $out/bootrom.log)"; exit 1; }
    rom=$out/boot/bootrom.hex
    echo "bootrom $(sha256sum $rom | cut -c1-16)"
    src=tb/sw/directed/fence_i_posted_store.S
    env=build/riscv-tests/env/p
    mac=build/riscv-tests/isa/macros/scalar
    sha256sum $src tb/model/membus_latency_shim.sv src/top.sv src/core.sv rtl/cache/dcache.sv src/amounit.sv \
      tools/run_riscv_tests.py tools/analyze-fence-i-trace.py $rom > "$out/sources.sha256"

    # ---- test programs ----
    for variant in miss hit; do
      def=""; [[ $variant == hit ]] && def="-DFENCE_I_HIT"
      elf="$out/elf/fence_i_posted_store_$variant"
      riscv64-unknown-elf-gcc -march=rv64imac_zicsr_zifencei -mabi=lp64 -mno-relax -static -mcmodel=medany \
        -fvisibility=hidden -nostdlib -nostartfiles $def -I$env -I$mac -T$env/link.ld $src -o "$elf" \
        > "$out/cc_$variant.log" 2>&1 || { echo "FAIL compile $variant"; status=1; continue; }
      riscv64-unknown-elf-objcopy -O binary "$elf" "$elf.bin"
      python3 tools/bin2hex.py 8 "$elf.bin" > "$elf.bin.hex"
      riscv64-unknown-elf-objdump -d "$elf" > "$elf.dump"
      # no zero-filled padding may sit on the executed path (slots_begin up to <fail>)
      if awk "/<slots_begin>:/{s=1} /<fail>:/{s=0} s && (/\.insn\t2, 0x0+\$/ || /^\t\.\.\.\$/)" "$elf.dump" | grep -q .; then
        echo "FAIL layout $variant: zero padding in slot code"; status=1
      fi
      riscv64-unknown-elf-nm "$elf" | grep -E " (patch_[0-9]+|markers)$" | awk "{print \$1, \$3}" > "$elf.syms"
      [[ $(wc -l < "$elf.syms") -eq 17 ]] || { echo "FAIL symbols $variant"; status=1; }
      # layout: patch_k must cover all 8 word offsets of a 32-byte line and both 64-bit lanes
      python3 -I -c "import sys
p=[int(l.split()[0],16) for l in open(sys.argv[1]) if l.split()[1].startswith(\"patch_\")]
offs={a & 31 for a in p}; lanes={a & 4 for a in p}
print(\"layout offsets\", sorted(offs), \"lanes\", sorted(lanes))
sys.exit(0 if offs=={0,4,8,12,16,20,24,28} and lanes=={0,4} else 1)" "$elf.syms" > "$out/layout_$variant.txt" \
        || { echo "FAIL layout $variant: $(cat "$out/layout_$variant.txt")"; status=1; }
      cat "$out/layout_$variant.txt"
    done

    # ---- simulators (isolated OBJ_DIRs; obj_dir_input untouched) ----
    build() { # name style shim
      local obj=build/test/cpu-m2$sfx-$1/obj; mkdir -p $obj
      make build OBJ_DIR=$obj DCACHE_LINE_COUNT=32 DCACHE_STORE_BUFFER_DEPTH=4 DCACHE_WRITE_BACK=0 \
        DCACHE_DATA_RAM_STYLE=$2 RAM_LATENCY_SHIM=$3 RAM_BACKEND=$RAM_BACKEND > "$out/build_$1.log" 2>&1 \
        || { echo "FAIL build $1"; status=1; return; }
      sha256sum $obj/sim >> "$out/sims.sha256"
    }
    build s1-shim 1 1; build s0-shim 0 1; build s1-off 1 0; build s0-off 0 0

    # ---- matrix ----
    run() { # label sim variant args...
      local label=$1 sim=build/test/cpu-m2$sfx-$2/obj/sim variant=$3; shift 3
      local traced=0; [[ $label != *_off_* ]] && traced=1
      local elf="$out/elf/fence_i_posted_store_$variant" dir="$out/run_$label"
      [[ -x $sim ]] || { echo "SKIP $label (no sim)"; status=1; return; }
      local lo hi plo phi
      read -r lo hi plo phi < <(python3 -I -c "import sys
s={l.split()[1]:int(l.split()[0],16) for l in open(sys.argv[1])}
b=0x80000000
print(*(format(v,\"x\") for v in (s[\"markers\"]-b, s[\"markers\"]-b+127, s[\"patch_0\"]-b, s[\"patch_15\"]-b+7)))" "$elf.syms")
      python3 tools/run_riscv_tests.py "$sim" "$out/elf" "fence_i_posted_store_$variant" --rom $rom \
        --ram_base 0x80000000 -o "$dir" -t 30 --sim-arg +TRACE_RETIRE --sim-arg +RAM_SHIM_TRACE_FENCE \
        --sim-arg +RAM_SHIM_TRACE0_LO=$lo --sim-arg +RAM_SHIM_TRACE0_HI=$hi \
        --sim-arg +RAM_SHIM_TRACE1_LO=$plo --sim-arg +RAM_SHIM_TRACE1_HI=$phi \
        $(for a in "$@"; do printf -- "--sim-arg %s " "$a"; done) > "$dir.log" 2>&1
      local result; result=$(head -1 "$dir/result.txt" 2>/dev/null || echo "no result")
      local log; log=$(ls "$dir"/*fence_i_posted_store_$variant*.txt 2>/dev/null | head -1)
      if [[ -z $log ]]; then echo "FAIL $label: no simulator log"; status=1; return; fi
      python3 -I tools/analyze-fence-i-trace.py "$log" "$elf.syms" $traced > "$dir.classify.txt"
      local arc=$?
      [[ $arc -eq 0 ]] || { echo "INVALID-CLASSIFICATION $label (rc=$arc)"; status=1; }
      grep -q "^PASS" "$dir/result.txt" || status=1
      echo "$label: $result | $(head -1 "$dir.classify.txt") | overtake_slots=$(grep -c "OVERTAKE=yes" "$dir.classify.txt")"
    }
    fixed="+RAM_SHIM_READY_MAX=0 +RAM_SHIM_RSP_MIN=40 +RAM_SHIM_RSP_MAX=40 +RAM_SHIM_REFRESH_PERIOD=0"
    zero="+RAM_SHIM_READY_MAX=0 +RAM_SHIM_RSP_MIN=0 +RAM_SHIM_RSP_MAX=0 +RAM_SHIM_REFRESH_PERIOD=0"
    for variant in miss hit; do
      for style in s1 s0; do
        run "${style}_off_$variant"     $style-off  $variant
        run "${style}_zero_$variant"    $style-shim $variant $zero
        run "${style}_fixed40_$variant" $style-shim $variant $fixed
        for seed in 1 7 42; do
          run "${style}_seed${seed}_$variant" $style-shim $variant +RAM_SHIM_SEED=$seed
        done
      done
    done
    if [[ -f "$out/obj_dir_input.before.sha256" ]]; then
      sha256sum -c --quiet "$out/obj_dir_input.before.sha256" \
        || { echo "FAIL obj_dir_input/sim changed during the run"; status=1; }
    fi
    echo "FENCE_I_POSTED_STORE status=$status (non-zero = at least one failing run; see classify files)"
    exit $status
  '
