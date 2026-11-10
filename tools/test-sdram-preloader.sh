#!/usr/bin/env bash
# Unit test for tb/model/sdram_preloader.sv (C3 M3b simulation preloader).
# Logs: build/test/sdram-preloader/.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" \
  bash -c 'set -uo pipefail
    out=build/test/sdram-preloader
    if [[ -e "$out" ]]; then
      mkdir -p build/test/archive
      mv "$out" "build/test/archive/sdram-preloader-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    mkdir -p "$out"
    status=0
    srcs="src/eei.sv src/util.sv src/membus_if.sv tb/model/sdram_preloader.sv tb/unit/sdram/tb_sdram_preloader.sv"
    sha256sum $srcs tb/unit/sdram/dpi_env_stub.cpp > "$out/sources.sha256"
    # images: sparse (zeros interleaved, non-zero first and last word, high bits set) and all-zero
    python3 -I -c "
import random
random.seed(20261110)
lines=[]
for i in range(200):
    v = 0 if (i % 3 == 1 or i % 7 == 4) else random.getrandbits(64) | (1 << 63)
    if i in (0, 199): v = random.getrandbits(64) | 1
    lines.append(format(v, \"016x\"))
open(\"$out/sparse.hex\", \"w\").write(\"\\n\".join(lines) + \"\\n\")
open(\"$out/zero.hex\", \"w\").write(\"\\n\".join([\"0\" * 16] * 50) + \"\\n\")
"
    verilator --binary --timing --assert -Wno-fatal --top-module tb_sdram_preloader --Mdir "$out/obj" -o sim \
      $srcs tb/unit/sdram/dpi_env_stub.cpp > "$out/build.log" 2>&1 || { echo "FAIL build"; exit 1; }
    sim=$out/obj/sim
    pass() { # label image args...
      local label=$1 img=$2; shift 2
      if RAM_FILE_PATH=$img timeout 120 $sim +IMAGE=$img "$@" > "$out/run_$label.log" 2>&1 \
          && grep -q "^SDRAM_PRELOADER_PASS" "$out/run_$label.log"; then
        echo "PASS $label: $(grep "^SDRAM_PRELOADER_PASS" "$out/run_$label.log")"
      else echo "FAIL $label (see $out/run_$label.log)"; status=1; fi
    }
    fail() { # label message env-image args...
      local label=$1 msg=$2 img=$3; shift 3
      if [[ $img == UNSET ]]; then env -u RAM_FILE_PATH timeout 120 $sim "$@" > "$out/run_$label.log" 2>&1
      else RAM_FILE_PATH=$img timeout 120 $sim "$@" > "$out/run_$label.log" 2>&1; fi
      local rc=$?
      if [[ $rc -ne 0 && $rc -ne 124 ]] && grep -q "$msg" "$out/run_$label.log" && ! grep -q "PASS\|NOT_REJECTED" "$out/run_$label.log"; then
        echo "EXPECTED-FAIL $label rc=$rc"
      else echo "FAIL $label: expected \"$msg\" (rc=$rc)"; status=1; fi
    }
    pass sparse        $out/sparse.hex
    pass sparse_verify $out/sparse.hex +SDRAM_PRELOAD_VERIFY
    pass all_zero      $out/zero.hex
    pass start_low     $out/sparse.hex +START_LOW
    fail corrupt_verify "verify mismatch"            $out/sparse.hex +IMAGE=$out/sparse.hex +SDRAM_PRELOAD_VERIFY +CORRUPT_READ
    fail reset_again    "reload) is not supported"   $out/sparse.hex +IMAGE=$out/sparse.hex +RESET_AGAIN
    fail unset_path     "no RAM image"               UNSET
    fail missing_file   "cannot open RAM image"      $out/does-not-exist.hex
    [[ $status -eq 0 ]] && echo SDRAM_PRELOADER_UNIT_PASS || echo SDRAM_PRELOADER_UNIT_FAIL
    exit $status
  '
