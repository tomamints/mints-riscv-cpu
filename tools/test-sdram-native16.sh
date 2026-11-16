#!/usr/bin/env bash
# Standalone functional simulation only; no board configuration or physical STA.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" -w /repo \
  -e SDRAM_CLK_HZ="${SDRAM_CLK_HZ:-50000000}" \
  "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
    set -euo pipefail
    hz="$SDRAM_CLK_HZ"
    out=build/test/sdram-native16
    [[ "$hz" == 50000000 ]] || out="$out-$hz"
    echo "SDRAM clock profile $hz Hz"
    if [[ -e "$out" ]]; then
      mkdir -p build/test/archive
      mv "$out" "build/test/archive/sdram-native16-$hz-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    mkdir -p "$out"
    rtl=fpga/de0-cv/sdram/rtl/sdram_native16.sv
    tb=tb/unit/sdram/tb_sdram_native16.sv
    verilator --version > "$out/version.log"
    verilator --lint-only -Wall --top-module sdram_native16 -GCLK_HZ=$hz "$rtl" > "$out/lint.log" 2>&1
    verilator --binary --timing --assert --top-module tb_sdram_native16 -GCLK_HZ=$hz \
      --Mdir "$out/obj" -o sim "$rtl" "$tb" > "$out/build.log" 2>&1
    "$out/obj/sim" > "$out/run.log" 2>&1
    grep -q "^SDRAM_NATIVE16_PASS" "$out/run.log"
    cat "$out/run.log"
    for profile in BAD_INIT BAD_DATA BAD_REFRESH; do
      verilator --binary --timing --assert --top-module tb_sdram_native16 -GCLK_HZ=$hz \
        "-GINJECT_$profile=1" --Mdir "$out/obj_$profile" -o sim \
        "$rtl" "$tb" > "$out/build_$profile.log" 2>&1
      set +e
      "$out/obj_$profile/sim" > "$out/run_$profile.log" 2>&1
      rc=$?
      set -e
      [[ $rc -ne 0 ]]
      if [[ $profile == BAD_INIT ]]; then
        grep -q "power-up delay too short" "$out/run_$profile.log"
      elif [[ $profile == BAD_DATA ]]; then
        grep -q "read .* got .* expected" "$out/run_$profile.log"
      else
        grep -q "refresh deadline missed" "$out/run_$profile.log"
      fi
      echo "Expected failure detected: $profile (exit=$rc)"
    done
  '
